defmodule PhoenixKitAgent.RetentionTest do
  @moduledoc """
  The optional time limit on chats (`PhoenixKitAgent.Retention`): with no
  period set nothing is ever deleted; with one, a chat whose last message is
  older, and a chat the user deleted, go for good with their messages, their
  attachment rows and the Storage files nothing else uses.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.{Config, Library, Retention, RetentionWorker}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message}
  alias PhoenixKitAgent.Test.Files

  @key "agent_retention_days"

  setup do
    Files.local_bucket!()
    {:ok, library} = Library.ensure_library()
    %{user: user_fixture("keeper"), library: library}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days * 86_400 - 60, :second)

  defp set_days!(value), do: {:ok, _} = Settings.update_setting_with_module(@key, value, "agent")

  # A chat whose columns are set as given (the fixture only makes the row).
  defp chat!(user, columns) do
    chat = conversation_fixture(user)

    if columns != [],
      do: Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid), set: columns)

    chat
  end

  defp message!(chat, content \\ "hello") do
    %Message{conversation_uuid: chat.uuid}
    |> Message.changeset(%{role: "user", content: content})
    |> Repo.insert!()
  end

  defp store(user, library_uuid, content) do
    source = Path.join(System.tmp_dir!(), "pk_agent_ret_#{System.unique_integer([:positive])}")
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

  defp attach!(user, chat, file) do
    %Attachment{
      conversation_uuid: chat.uuid,
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

  defp chat?(chat), do: Repo.get(Conversation, chat.uuid) != nil
  defp file?(file), do: Repo.get(Storage.File, file.uuid) != nil
  defp count(schema), do: Repo.aggregate(schema, :count)

  # ── no period ───────────────────────────────────────────────────────

  describe "with no period set" do
    test "nothing is deleted, an old or a deleted chat included", %{user: user} do
      old = chat!(user, last_message_at: ago(900))
      deleted = chat!(user, status: "deleted", last_message_at: ago(900))
      message!(old)

      assert Config.retention_days() == nil
      assert {:skipped, :off} = Retention.run()
      assert :ok = RetentionWorker.perform(%Oban.Job{})

      assert chat?(old) and chat?(deleted)
      assert count(Message) == 1
      assert Repo.all(from(e in Entry, where: e.action == "agent.retention_purged")) == []
    end

    test "none, saved when none was ever set, is no error and writes nothing" do
      assert {:ok, :unchanged} = Config.put_retention_days(nil, [])
      assert {:ok, :unchanged} = Config.put_retention_days("", [])
      assert Config.retention_days() == nil
    end

    test "a period that is blank is none", %{user: user} do
      old = chat!(user, last_message_at: ago(900))
      set_days!("30")
      assert Config.retention_days() == 30

      set_days!("")
      assert Config.retention_days() == nil
      assert {:skipped, :off} = Retention.run()
      assert chat?(old)
    end

    test "a stored value that is not a period reads as none, never as a short one", %{user: user} do
      old = chat!(user, last_message_at: ago(900))

      for damaged <- ["abc", "0", "-1", "3651", "1.5", "30 days", "  ", "1e1"] do
        set_days!(damaged)
        assert Config.retention_days() == nil, "read #{inspect(damaged)} as a period"
        assert Config.retention_days_direct() == nil
        assert {:skipped, :off} = Retention.run()
      end

      assert chat?(old)
    end
  end

  # ── a period ────────────────────────────────────────────────────────

  describe "with a period" do
    setup do
      set_days!("30")
      :ok
    end

    test "reads it back, and from the database", _ctx do
      assert Config.retention_days() == 30
      assert Config.retention_days_direct() == 30
    end

    test "a chat older than the period goes with its messages, rows and file; a newer one stays",
         %{user: user, library: library} do
      old = chat!(user, last_message_at: ago(31))
      recent = chat!(user, last_message_at: ago(29))
      old_file = store(user, library.uuid, "old bytes")
      recent_file = store(user, library.uuid, "recent bytes")
      message!(old)
      message!(old)
      message!(recent)
      attach!(user, old, old_file)
      attach!(user, recent, recent_file)

      assert {:ok, summary} = Retention.run()
      assert summary == %{days: 30, conversations: 1, messages: 2, attachments: 1, files: 1}

      refute chat?(old)
      assert chat?(recent)
      refute file?(old_file)
      assert file?(recent_file)
      assert count(Message) == 1
      assert count(Attachment) == 1
    end

    test "the age is the last message; a chat with none counts from the day it was made",
         %{user: user} do
      # Made long ago, written to yesterday.
      lively = chat!(user, inserted_at: ago(400), last_message_at: ago(1))
      empty_old = chat!(user, inserted_at: ago(40))
      empty_new = chat!(user, inserted_at: ago(2))

      assert {:ok, %{conversations: 1}} = Retention.run()

      assert chat?(lively)
      refute chat?(empty_old)
      assert chat?(empty_new)
    end

    test "a chat the user deleted goes at the next run, however new; an archived one by its age",
         %{user: user} do
      deleted_new = chat!(user, status: "deleted", last_message_at: ago(0))
      archived_old = chat!(user, status: "archived", last_message_at: ago(60))
      archived_new = chat!(user, status: "archived", last_message_at: ago(5))
      message!(deleted_new)

      assert {:ok, %{conversations: 2, messages: 1}} = Retention.run()

      refute chat?(deleted_new)
      refute chat?(archived_old)
      assert chat?(archived_new)
    end

    test "a chat whose turn holds its lock is left for the next run; a lock gone stale is not",
         %{user: user} do
      busy = chat!(user, last_message_at: ago(90), busy_since: DateTime.utc_now())
      deleted_busy = chat!(user, status: "deleted", busy_since: DateTime.utc_now())

      stale_since = DateTime.add(DateTime.utc_now(), -PhoenixKitAgent.Turns.lock_ttl_s() - 60)
      stale = chat!(user, last_message_at: ago(90), busy_since: stale_since)

      assert {:ok, %{conversations: 1}} = Retention.run()
      assert chat?(busy) and chat?(deleted_busy)
      refute chat?(stale)

      Repo.update_all(from(c in Conversation, where: c.uuid in ^[busy.uuid, deleted_busy.uuid]),
        set: [busy_since: nil]
      )

      assert {:ok, %{conversations: 2}} = Retention.run()
    end

    test "the day count follows the period and `now`", %{user: user} do
      chat = chat!(user, last_message_at: DateTime.add(DateTime.utc_now(), -10 * 86_400))

      assert {:ok, %{conversations: 0}} = Retention.run()

      set_days!("5")
      assert Retention.due_count(5) == 1
      assert {:ok, %{days: 5, conversations: 1}} = Retention.run()
      refute chat?(chat)
    end

    test "a file something else uses is left alone: another chat's row, a Media file",
         %{user: user, library: library} do
      other = user_fixture("other")
      old = chat!(user, last_message_at: ago(40))
      kept = chat!(other, last_message_at: ago(1))

      shared = store(user, library.uuid, "the same bytes")
      attach!(user, old, shared)
      attach!(other, kept, shared)

      media = store(user, nil, "a media file")
      attach!(user, old, media)

      assert {:ok, %{conversations: 1, attachments: 2, files: 0}} = Retention.run()

      refute chat?(old)
      assert file?(shared)
      assert file?(media)
      assert count(Attachment) == 1
    end

    test "works through the chats in batches", %{user: user} do
      chats = for _ <- 1..5, do: chat!(user, last_message_at: ago(100))
      keep = chat!(user, last_message_at: ago(1))

      assert {:ok, %{conversations: 5}} = Retention.run(batch: 2)

      assert Enum.all?(chats, &(not chat?(&1)))
      assert chat?(keep)
    end

    test "stops starting batches when the time budget is spent", %{user: user} do
      chats = for _ <- 1..3, do: chat!(user, last_message_at: ago(100))

      assert {:ok, %{conversations: 0}} = Retention.run(budget_ms: 0)
      assert Enum.all?(chats, &chat?/1)

      assert {:ok, %{conversations: 3}} = Retention.run()
    end

    test "runs with the module switched off", %{user: user} do
      old = chat!(user, last_message_at: ago(100))
      {:ok, _} = PhoenixKitAgent.disable_system()

      assert {:ok, %{conversations: 1}} = Retention.run()
      refute chat?(old)
    end

    test "the run is in the Activity log: counts and the period, nothing of a chat", %{user: user} do
      old = chat!(user, last_message_at: ago(100))
      old = Repo.update!(Conversation.changeset(old, %{title: "SECRET-TITLE-77"}))
      message!(old, "SECRET-TEXT-77")

      assert {:ok, _} = Retention.run()

      assert [entry] = Repo.all(from(e in Entry, where: e.action == "agent.retention_purged"))
      assert entry.module == "agent"
      assert entry.mode == "auto"
      assert entry.actor_uuid == nil
      assert entry.permanent

      assert entry.metadata == %{
               "days" => 30,
               "conversations" => 1,
               "messages" => 1,
               "attachments" => 0,
               "files" => 0
             }

      refute inspect(entry) =~ "SECRET"
    end

    test "a run that deleted nothing writes no entry", %{user: user} do
      chat!(user, last_message_at: ago(1))
      assert {:ok, %{conversations: 0}} = Retention.run()
      assert Repo.all(from(e in Entry, where: e.action == "agent.retention_purged")) == []
    end

    test "the worker runs it", %{user: user} do
      old = chat!(user, last_message_at: ago(100))
      assert :ok = RetentionWorker.perform(%Oban.Job{})
      refute chat?(old)
    end
  end

  describe "how it is scheduled" do
    test "the module names a nightly cron for the worker" do
      assert [{cron, RetentionWorker}] = PhoenixKitAgent.oban_crons()
      assert [_, _, _, _, _] = String.split(cron, " ")
    end

    test "one run at a time" do
      unique = RetentionWorker.__opts__()[:unique]
      assert unique[:fields] == [:worker]
      assert unique[:keys] == []
      assert :executing in unique[:states]
    end
  end

  describe "the setting" do
    test "put_retention_days/2 takes a whole number of days from 1, or none" do
      for {input, stored} <- [{30, 30}, {"45", 45}, {" 7 ", 7}, {1, 1}, {3650, 3650}] do
        assert {:ok, _} = Config.put_retention_days(input, source: "test")
        assert Config.retention_days() == stored
      end

      for none <- [nil, "", "  "] do
        {:ok, _} = Config.put_retention_days(30, [])
        assert {:ok, _} = Config.put_retention_days(none, [])
        assert Config.retention_days() == nil
      end
    end

    test "anything else is refused and nothing is written" do
      {:ok, _} = Config.put_retention_days(30, [])

      for bad <- [0, -1, 3651, "0", "abc", "1.5", "1e1", 1.5, :thirty, %{}] do
        assert {:error, :invalid_days} = Config.put_retention_days(bad, [])
        assert Config.retention_days() == 30
      end
    end

    test "a change is in the settings history with who made it" do
      actor = owner_fixture()
      {:ok, _} = Config.put_retention_days(30, actor_uuid: actor.uuid, source: "settings")

      entries =
        Repo.all(from(a in Entry, where: fragment("?->>'key' = ?", a.metadata, ^@key)))

      assert [%{actor_uuid: actor_uuid}] = entries
      assert actor_uuid == actor.uuid
    end
  end
end
