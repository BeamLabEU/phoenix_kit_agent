defmodule PhoenixKitAgent.AttachmentTypesTest do
  @moduledoc """
  The types of file a chat accepts (`agent_attachment_types`): every type
  until a site narrows the list; then the server refuses a file whose content
  is of another type — whatever its name or the type the browser claimed — and
  a file already attached, but not sent, of a type taken off the list.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAgent.{Attachments, Config, Conversations, Turns}
  alias PhoenixKitAgent.Attachments.Detect
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation}
  alias PhoenixKitAgent.Test.Files
  alias PhoenixKitAgent.Web.Dock.Texts

  @key "agent_attachment_types"
  @me [impersonated: false]

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    Files.local_bucket!()

    # A model that sees pictures: a picture is then taken without a vision model.
    endpoint =
      endpoint_fixture(%{
        name: "Chat",
        model: "a/chat",
        provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/chat"}}
      })

    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentTypes#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("types")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, _token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, ref: ref, chat: chat}
  end

  defp add(ctx, binary, name, content_type \\ nil),
    do: Attachments.add(ctx.ref, ctx.chat.uuid, Files.upload!(binary, name, content_type), @me)

  # Added and processed: a task is still working on a file the test leaves.
  defp added(ctx, binary, name, content_type \\ nil) do
    assert {:ok, attachment} = add(ctx, binary, name, content_type)
    uuid = attachment.uuid
    assert_receive {:agent_attachment_processed, _chat_uuid, ^uuid}, 10_000
    attachment
  end

  defp rows(ctx),
    do:
      Repo.aggregate(from(a in Attachment, where: a.conversation_uuid == ^ctx.chat.uuid), :count)

  defp set!(types), do: {:ok, _} = Config.put_attachment_types(types, source: "test")

  describe "the list" do
    test "is every type the module reads until it is set" do
      assert Config.attachment_types() == Detect.types()
      assert Detect.types() == ~w(png jpg webp heic pdf xlsx csv txt md)
    end

    test "is stored in the module's order, whatever the order given" do
      set!(["txt", "png", "txt", "csv"])
      assert Config.attachment_types() == ["png", "csv", "txt"]
    end

    test "the full list, with none stored yet, writes nothing" do
      assert {:ok, :unchanged} = Config.put_attachment_types(Detect.types(), [])
      assert Config.attachment_types() == Detect.types()
    end

    test "the full list is stored as unset, so it follows a type the module learns later" do
      set!(["png"])
      set!(Enum.reverse(Detect.types()))

      assert Config.attachment_types() == Detect.types()
      assert Settings.get_setting(@key) in [nil, ""]
    end

    test "a name that is not a type, or no type, is refused and nothing is written" do
      set!(["png", "txt"])

      for bad <- [[], ["exe"], ["png", "exe"], ["PNG"], [nil], "png", nil] do
        assert {:error, :invalid_types} = Config.put_attachment_types(bad, [])
        assert Config.attachment_types() == ["png", "txt"]
      end
    end

    test "a stored value with no known type reads as every type; unknown names are ignored" do
      set!(["png"])

      for value <- ["", "exe,dll", "  ", ","] do
        {:ok, _} = Settings.update_setting_with_module(@key, value, "agent")
        assert Config.attachment_types() == Detect.types()
      end

      {:ok, _} = Settings.update_setting_with_module(@key, " PNG , exe,txt ", "agent")
      assert Config.attachment_types() == ["png", "txt"]
    end

    test "a change is in the settings history with who made it" do
      actor = owner_fixture()
      {:ok, _} = Config.put_attachment_types(["png"], actor_uuid: actor.uuid, source: "settings")

      entries =
        Repo.all(
          from(a in PhoenixKit.Activity.Entry,
            where: fragment("?->>'key' = ?", a.metadata, ^@key)
          )
        )

      assert [%{actor_uuid: actor_uuid}] = entries
      assert actor_uuid == actor.uuid
    end
  end

  describe "the server, on a file added" do
    test "with no list set every type the module reads is taken", ctx do
      assert %{kind: "text"} = added(ctx, "plain words", "notes.txt")
      assert %{kind: "sheet"} = added(ctx, "a,b\n1,2\n", "table.csv")
      assert %{kind: "image"} = added(ctx, Files.png(8, 8), "p.png")
    end

    test "a type off the list is refused before anything is stored", ctx do
      set!(["png", "txt"])

      assert {:error, :type_not_allowed} = add(ctx, "a,b\n1,2\n", "table.csv")
      assert {:error, :type_not_allowed} = add(ctx, Files.text_pdf(["x"]), "doc.pdf")
      assert {:error, :type_not_allowed} = add(ctx, Files.jpeg(8, 8), "photo.jpg")
      assert {:error, :type_not_allowed} = add(ctx, "# title\n", "notes.md")
      assert rows(ctx) == 0

      assert %{kind: "text"} = added(ctx, "plain words", "notes.txt")
      assert %{kind: "image"} = added(ctx, Files.png(8, 8), "p.png")
      assert rows(ctx) == 2
    end

    test "the content decides, not the name or the type the browser claimed", ctx do
      set!(["txt"])

      # A picture named .txt, sent as text/plain: still a picture.
      assert {:error, :type_not_allowed} = add(ctx, Files.png(8, 8), "notes.txt", "text/plain")
      # A text sent as image/png under a .png name is no picture at all.
      assert {:error, :unsupported_type} = add(ctx, "just words", "photo.png", "image/png")
      # A CSV the browser called text/plain: its name tells csv, which is off the list.
      assert {:error, :type_not_allowed} = add(ctx, "a,b\n1,2\n", "table.csv", "text/plain")
      assert rows(ctx) == 0

      # And the other way: named .txt, the browser's text/csv is not believed either.
      assert %{kind: "text", content_type: "text/plain"} =
               added(ctx, "a,b\n1,2\n", "notes.txt", "text/csv")
    end

    test "a bridge's picture follows the list too" do
      set!(["txt"])
      member = user_with(["agent", "agent.telegram", "dashboard"], "bridge")
      chat = conversation_fixture(member)
      ref = telegram_link_fixture(member, UUIDv7.generate(), 4242)

      assert {:error, :type_not_allowed} =
               Attachments.add_picture_for_telegram(ref, chat.uuid, Files.png(8, 8))

      assert Repo.aggregate(
               from(a in Attachment, where: a.conversation_uuid == ^chat.uuid),
               :count
             ) ==
               0
    end
  end

  describe "a file already attached" do
    test "is refused when the message is sent once its type is off the list", ctx do
      attachment = added(ctx, "plain words", "notes.txt")

      set!(["png"])

      assert {:error, :type_not_allowed} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [attachment.uuid])

      # The user discards it, and the message goes without it.
      assert Repo.get!(Attachment, attachment.uuid).message_uuid == nil
    end
  end

  describe "every type the module reads, one by one" do
    # One real sample per type, named the way a user names it.
    defp samples do
      %{
        "png" => {Files.png(8, 8), "p.png"},
        "jpg" => {Files.jpeg(8, 8), "p.jpg"},
        "webp" => {"RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 " <> <<0::64>>, "p.webp"},
        "heic" => {<<0, 0, 0, 24>> <> "ftypheic" <> <<0::96>>, "p.heic"},
        "pdf" => {Files.text_pdf(["x"]), "d.pdf"},
        "xlsx" => {Files.xlsx([{"S", [["a", 1]]}]), "t.xlsx"},
        "csv" => {"a,b\n1,2\n", "t.csv"},
        "txt" => {"plain words", "n.txt"},
        "md" => {"# title\n", "n.md"}
      }
    end

    # A ready attachment row of the content `binary` is, not yet in a message,
    # in a chat whose lock is held: `Turns.start/6` then ends in
    # `:conversation_busy` exactly when its check of the files let it through.
    defp ready_row!(ctx, binary, name) do
      path = Files.tmp!(binary, "sample")
      assert {:ok, detected} = Detect.detect(path, name)

      %Attachment{conversation_uuid: ctx.chat.uuid, user_uuid: ctx.user.uuid}
      |> Attachment.changeset(%{
        filename: name,
        content_type: detected.content_type,
        size_bytes: byte_size(binary),
        kind: detected.kind,
        status: "ready"
      })
      |> Repo.insert!()
    end

    defp hold_lock!(ctx) do
      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now()]
      )
    end

    test "the samples are every type there is, and the content says which", _ctx do
      assert samples() |> Map.keys() |> Enum.sort() == Enum.sort(Detect.types())

      for {type, {binary, name}} <- samples() do
        assert {:ok, %{ext: ^type, content_type: content_type}} =
                 Detect.detect(Files.tmp!(binary, "sample"), name)

        # What a stored row says is mapped back to the name the list uses.
        assert Detect.type_of_content_type(content_type) == type
      end
    end

    test "with no list set, Attachments.add takes each of them", ctx do
      for {type, {binary, name}} <- samples() do
        # A chat each: a message takes only so many files.
        chat = conversation_fixture(ctx.user)
        :ok = Conversations.subscribe(ctx.ref, chat.uuid, @me)

        result = Attachments.add(ctx.ref, chat.uuid, Files.upload!(binary, name), @me)

        assert {:ok, attachment} = result, "#{type} was refused: #{inspect(result)}"
        uuid = attachment.uuid

        # Processed or not (a stub of a picture may fail): a task is working on it.
        assert_receive {:agent_attachment_processed, _chat_uuid, ^uuid}, 10_000
      end
    end

    test "with no list set, Turns.start lets each of them through", ctx do
      hold_lock!(ctx)

      for {type, {binary, name}} <- samples() do
        row = ready_row!(ctx, binary, name)

        assert {:error, :conversation_busy} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [row.uuid]),
               "#{type} did not get through"
      end
    end

    test "with a list, Turns.start lets through a type on it and only that", ctx do
      hold_lock!(ctx)

      for {type, {binary, name}} <- samples() do
        row = ready_row!(ctx, binary, name)
        others = Detect.types() -- [type]

        set!([type])

        assert {:error, :conversation_busy} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [row.uuid]),
               "#{type} was refused with only #{type} on the list"

        set!(others)

        assert {:error, :type_not_allowed} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [row.uuid]),
               "#{type} got through with #{type} off the list"
      end
    end

    test "with the list as it ships, a row of a content type the module has no name for is not refused",
         ctx do
      hold_lock!(ctx)

      row =
        %Attachment{conversation_uuid: ctx.chat.uuid, user_uuid: ctx.user.uuid}
        |> Attachment.changeset(%{
          filename: "x",
          content_type: "application/x-future",
          size_bytes: 1,
          kind: "text",
          status: "ready"
        })
        |> Repo.insert!()

      assert {:error, :conversation_busy} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [row.uuid])

      # A narrowed list refuses what it has no name for.
      set!(["png"])

      assert {:error, :type_not_allowed} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [row.uuid])
    end
  end

  describe "what the person is told" do
    test "with every type: what the module reads; with a list: that list" do
      assert Texts.refusal(:unsupported_type) =~ "a PDF"
      assert Texts.upload_error(:not_accepted) =~ "a PDF"

      set!(["png", "jpg", "webp", "heic"])

      for text <- [
            Texts.refusal(:type_not_allowed),
            Texts.refusal(:unsupported_type),
            Texts.upload_error(:not_accepted)
          ] do
        assert text =~ "png, jpg, webp, heic"
        refute text =~ "PDF"
      end
    end
  end
end
