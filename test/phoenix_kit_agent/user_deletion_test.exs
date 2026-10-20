defmodule PhoenixKitAgent.UserDeletionTest do
  @moduledoc """
  Deleting a user (spec §5.7) through core's `Auth.delete_user/2`, which runs the
  module's `before_user_delete/1` first: nothing of the module blocks the delete,
  the user's attachment files in the module's library are gone from Storage —
  but a file nothing else uses only — while a Media file with the same bytes
  stays, the user's folder goes, and their uuid leaves other users' notice lists
  and the limit watchers.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Folder, Libraries}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.{Config, Library}

  alias PhoenixKitAgent.Schemas.{
    Attachment,
    Conversation,
    LimitEvent,
    Message,
    UserSettings
  }

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_agent_user_deletion_#{n}")
    Repo.update_all(Bucket, set: [enabled: false])

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "agent-deletion-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban,
       name: Oban, repo: PhoenixKitAgent.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    owner = owner_fixture()
    user = user_fixture("leaving")
    {:ok, library} = Library.ensure_library()

    %{owner: owner, user: user, library: library, n: n, root: root}
  end

  defp store(user, library_uuid, content) do
    source = Path.join(System.tmp_dir!(), "pk_agent_src_#{System.unique_integer([:positive])}")
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    {result, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(source, "image", user.uuid, checksum, "jpg", "a.jpg", opts)
      end)

    File.rm(source)

    case result do
      {:ok, file} -> file
      {:ok, file, _} -> file
    end
  end

  defp attach(user, conversation, file) do
    message =
      %Message{conversation_uuid: conversation.uuid}
      |> Message.changeset(%{role: "user", content: "see attached"})
      |> Repo.insert!()

    %Attachment{
      conversation_uuid: conversation.uuid,
      message_uuid: message.uuid,
      user_uuid: user.uuid,
      file_uuid: file && file.uuid
    }
    |> Attachment.changeset(%{
      filename: "a.jpg",
      content_type: "image/jpeg",
      size_bytes: 10,
      kind: "image"
    })
    |> Repo.insert!()
  end

  defp delete_user!(user, owner) do
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Auth.delete_user(Repo.get!(Auth.User, user.uuid), %{current_user: owner})
      end)

    assert {:ok, _} = result
    # A failing step is logged and the user is deleted anyway: a failure must show.
    refute log =~ "before_user_delete hook"
    refute log =~ "user deletion cleanup"
  end

  defp count(schema, user_uuid) do
    Repo.aggregate(from(r in schema, where: r.user_uuid == ^user_uuid), :count)
  end

  test "the user's module rows go with the user, nothing blocks the delete", %{
    user: user,
    owner: owner
  } do
    endpoint = endpoint_fixture()
    conversation = conversation_fixture(user)
    request = ai_request_fixture(user, endpoint)

    %Message{conversation_uuid: conversation.uuid, ai_request_uuid: request.uuid}
    |> Message.changeset(%{role: "assistant", content: "answer"})
    |> Repo.insert!()

    attach(user, conversation, nil)

    %UserSettings{user_uuid: user.uuid, updated_by_uuid: owner.uuid}
    |> UserSettings.changeset(%{endpoint_uuid: endpoint.uuid, daily_turn_limit: 10})
    |> Repo.insert!()

    %LimitEvent{user_uuid: user.uuid}
    |> LimitEvent.changeset(%{limit_kind: "daily_turns", period_key: "2026-10-20"})
    |> Repo.insert!()

    delete_user!(user, owner)

    assert Repo.get(Auth.User, user.uuid) == nil
    assert count(Conversation, user.uuid) == 0
    assert count(Attachment, user.uuid) == 0
    assert count(UserSettings, user.uuid) == 0
    assert count(LimitEvent, user.uuid) == 0

    assert Repo.aggregate(
             from(m in Message, where: m.conversation_uuid == ^conversation.uuid),
             :count
           ) == 0
  end

  test "an admin who edited someone's settings can be deleted; the row stays, unlinked", %{
    user: admin,
    owner: owner
  } do
    other = user_fixture("other")

    %UserSettings{user_uuid: other.uuid, updated_by_uuid: admin.uuid}
    |> UserSettings.changeset(%{daily_turn_limit: 10})
    |> Repo.insert!()

    delete_user!(admin, owner)

    assert %UserSettings{updated_by_uuid: nil, daily_turn_limit: 10} =
             Repo.get!(UserSettings, other.uuid)
  end

  test "attachment files in the module's library are deleted; the same bytes in Media stay", %{
    user: user,
    owner: owner,
    library: library,
    root: root
  } do
    content = "the same bytes #{System.unique_integer([:positive])}"

    # Uploaded to Media first, then to the chat: the library's dedup does not
    # reach into Media, so the attachment gets a row of its own.
    media_file = store(user, nil, content)
    agent_file = store(user, library.uuid, content)

    assert media_file.library_uuid == Libraries.media_uuid()
    assert agent_file.library_uuid == library.uuid
    refute agent_file.uuid == media_file.uuid
    assert agent_file.file_checksum == media_file.file_checksum

    attach(user, conversation_fixture(user), agent_file)

    agent_object =
      Path.join(root, Storage.get_file_instance_by_name(agent_file.uuid, "original").file_name)

    assert File.exists?(agent_object)

    delete_user!(user, owner)

    assert Storage.get_file(agent_file.uuid) == nil
    refute File.exists?(agent_object)

    assert %Storage.File{} = kept = Storage.get_file(media_file.uuid)
    assert Storage.file_exists?(kept)
  end

  test "a module file something else uses is only unlinked", %{
    user: user,
    owner: owner,
    library: library,
    n: n
  } do
    shared = store(user, library.uuid, "shared #{n}")
    attach(user, conversation_fixture(user), shared)

    # Anything else pointing at the file keeps it: here a folder's cover.
    {:ok, _folder} =
      Storage.create_folder(%{
        name: "elsewhere-#{n}",
        library_uuid: library.uuid,
        cover_file_uuid: shared.uuid
      })

    delete_user!(user, owner)

    assert %Storage.File{} = Storage.get_file(shared.uuid)
  end

  test "an attachment that is a Media file is not deleted", %{user: user, owner: owner, n: n} do
    media_file = store(user, nil, "media #{n}")
    attach(user, conversation_fixture(user), media_file)

    delete_user!(user, owner)

    assert %Storage.File{} = Storage.get_file(media_file.uuid)
  end

  test "the user's folder goes, with module files left in it that nothing uses", %{
    user: user,
    owner: owner,
    library: library,
    n: n
  } do
    {:ok, folder} = Library.ensure_user_folder(user.uuid)
    stray = store(user, library.uuid, "stray #{n}")

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^stray.uuid),
      set: [folder_uuid: folder.uuid]
    )

    other = user_fixture("stays")
    {:ok, other_folder} = Library.ensure_user_folder(other.uuid)

    delete_user!(user, owner)

    assert Repo.get(Folder, folder.uuid) == nil
    assert Storage.get_file(stray.uuid) == nil
    assert %Folder{} = Repo.get(Folder, other_folder.uuid)
  end

  test "the user leaves other users' notice lists and the limit watchers", %{
    user: user,
    owner: owner
  } do
    other = user_fixture("other")
    keep = user_fixture("keep")

    %UserSettings{user_uuid: other.uuid}
    |> UserSettings.changeset(%{notify_user_uuids: [user.uuid, keep.uuid]})
    |> Repo.insert!()

    Settings.update_setting("agent_limit_watchers", Enum.join([keep.uuid, user.uuid], "\n"))

    delete_user!(user, owner)

    assert Repo.get!(UserSettings, other.uuid).notify_user_uuids == [keep.uuid]
    assert Config.limit_watchers() == [keep.uuid]
  end

  test "deleting the AI endpoint a user's settings point at is not blocked", %{user: user} do
    endpoint = endpoint_fixture()

    %UserSettings{user_uuid: user.uuid}
    |> UserSettings.changeset(%{endpoint_uuid: endpoint.uuid})
    |> Repo.insert!()

    request = ai_request_fixture(user, endpoint)

    message =
      %Message{conversation_uuid: conversation_fixture(user).uuid, ai_request_uuid: request.uuid}
      |> Message.changeset(%{role: "assistant", content: "answer"})
      |> Repo.insert!()

    assert {:ok, _} = PhoenixKitAI.delete_endpoint(endpoint)

    assert Repo.get!(UserSettings, user.uuid).endpoint_uuid == nil
    assert %Message{content: "answer"} = Repo.get!(Message, message.uuid)
  end

  test "the hook runs when the module's library was never created", %{user: user} do
    Repo.delete_all(from(l in Storage.Library, where: l.slug == ^Library.slug()))
    assert Library.library() == nil

    assert :ok = PhoenixKitAgent.before_user_delete(user.uuid)
  end
end
