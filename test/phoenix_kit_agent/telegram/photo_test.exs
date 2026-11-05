defmodule PhoenixKitAgent.Telegram.PhotoTest do
  @moduledoc """
  A picture sent to the bot by a linked chat: added to the person's Telegram
  conversation as the panel's upload is (the same checks, storage and
  processing), waited for, and sent to the model with the caption as one turn.
  The pictures of one album are one turn. The model is a `Req.Test` stub behind
  `phoenix_kit_ai`; the bot is `PhoenixKitAgent.Test.TelegramClient`.
  """

  use PhoenixKitAgent.DataCase, async: false

  @moduletag :imagemagick

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Attachments.{Bounds, Slots}
  alias PhoenixKitAgent.Schemas.{Attachment, Message}
  alias PhoenixKitAgent.Telegram.{Bridge, Limiter, Texts}
  alias PhoenixKitAgent.Test.{Files, LogProbe, TelegramClient, Tools}

  @stub __MODULE__
  @model "a/chat"
  @chat 428_897_538

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    _bucket = Files.local_bucket!()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :telegram_album_settle_ms, 100)
    TelegramClient.start()

    end_queues()

    on_exit(fn ->
      stop_all_turns()
      end_queues()
      TelegramClient.stop()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :telegram_album_settle_ms)
      Application.delete_env(:phoenix_kit_agent, :telegram_attachment_wait_ms)
      Req.Test.set_req_test_to_private()
    end)

    endpoint = chat_endpoint("yes")
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    user = user_with(["agent", "agent.telegram", "dashboard"], "photo")
    connection = UUIDv7.generate()
    ref = telegram_link_fixture(user, connection, @chat)
    Limiter.clear_unlinked(connection)
    TelegramClient.set(:download, fn _file_id, _opts -> {:ok, Files.png(40, 30)} end)

    %{user: user, connection: connection, ref: ref, endpoint: endpoint}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp chat_endpoint(vision) do
    endpoint_fixture(%{
      model: @model,
      provider_settings: %{"capabilities" => %{"vision" => vision, "model" => @model}}
    })
  end

  # The model answers `text` to every call, and tells the test what it was sent.
  defp model_says(text) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "model" => @model,
        "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
      })
    end)
  end

  defp images_in(body) do
    body["messages"]
    |> Enum.flat_map(&if(is_list(&1["content"]), do: &1["content"], else: []))
    |> Enum.count(&(&1["type"] == "image_url"))
  end

  defp photo(ctx, opts \\ []) do
    sizes = Keyword.get(opts, :sizes, [{"small-id", 800}, {"big-id", 90_000}])

    extra =
      Map.merge(
        %{"photo" => for({id, size} <- sizes, do: %{"file_id" => id, "file_size" => size})},
        Map.new(Keyword.take(opts, [:caption, :media_group_id]), fn {k, v} ->
          {to_string(k), v}
        end)
      )

    Bridge.dispatch(
      ctx.connection,
      TelegramClient.update(
        @chat,
        nil,
        Keyword.merge([extra: extra], Keyword.take(opts, [:message_id]))
      )
    )
  end

  defp document(ctx, type, opts \\ []) do
    doc = %{
      "file_id" => "doc-id",
      "mime_type" => type,
      "file_name" => "scan.png",
      "file_size" => 5_000
    }

    extra =
      Map.merge(
        %{"document" => doc},
        Map.new(Keyword.take(opts, [:caption]), fn {_key, v} -> {"caption", v} end)
      )

    Bridge.dispatch(ctx.connection, TelegramClient.update(@chat, nil, extra: extra))
  end

  defp calls_until(done, timeout \\ 8_000) do
    receive do
      {:tg, {:typing, _, _}} -> calls_until(done, timeout)
      {:tg, call} -> if done.(call), do: [call], else: [call | calls_until(done, timeout)]
    after
      timeout -> flunk("the bot was not called as expected")
    end
  end

  defp reaction?(emoji), do: &match?({:react, _, _, _, ^emoji}, &1)
  defp texts(calls), do: for({:send_message, _, _, text} <- calls, do: text)
  defp downloads(calls), do: for({:download_file, _, id, _} <- calls, do: id)

  defp user_messages(user) do
    Repo.all(
      from(m in Message,
        join: c in PhoenixKitAgent.Schemas.Conversation,
        on: c.uuid == m.conversation_uuid,
        where: c.user_uuid == ^user.uuid and m.role == "user",
        select: m.content
      )
    )
  end

  defp attachments(user), do: Repo.all(from(a in Attachment, where: a.user_uuid == ^user.uuid))

  # The queues of earlier tests, and the turns and replies they started, end
  # with the test: a turn left waiting for a model would answer into the next.
  defp end_queues do
    supervisor = PhoenixKitAgent.Telegram.QueueSupervisor

    for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end

    for tasks <- [
          PhoenixKitAgent.Telegram.TaskSupervisor,
          PhoenixKitAgent.Telegram.ReplySupervisor
        ],
        pid <- Task.Supervisor.children(tasks) do
      Task.Supervisor.terminate_child(tasks, pid)
    end

    :ok
  end

  defp stop_all_turns do
    for {pid, _} <-
          Registry.select(PhoenixKitAgent.Turns.Registry, [{{:_, :"$1", :_}, [], [{{:"$1", 0}}]}]) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  # Until the jobs and replies the bridge started have ended (what they log
  # and send is all there by then); no sleeping on a guess.
  defp settle(tries \\ 250) do
    supervisors = [
      PhoenixKitAgent.Telegram.TaskSupervisor,
      PhoenixKitAgent.Telegram.ReplySupervisor
    ]

    if tries > 0 and Enum.any?(supervisors, &(Task.Supervisor.children(&1) != [])) do
      Process.sleep(10)
      settle(tries - 1)
    else
      :ok
    end
  end

  # ── a picture is asked about ────────────────────────────────────────

  describe "a photo" do
    test "is shown to the model with its caption as one turn, and answered", ctx do
      model_says("A grey square.")

      photo(ctx, caption: "What is this?", message_id: 31)
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["A grey square."]
      assert {:react, _, @chat, 31, "👍"} = List.last(calls)
      assert user_messages(ctx.user) == ["What is this?"]

      assert_received {:model_request, body}
      assert images_in(body) == 1

      assert [%Attachment{status: "ready", kind: "image", message_uuid: message_uuid}] =
               attachments(ctx.user)

      assert message_uuid
    end

    test "the largest size that fits is the one downloaded, within the limit", ctx do
      model_says("Ok.")

      photo(ctx, sizes: [{"s", 800}, {"m", 90_000}, {"l", 9_000_000}, {"xl", 11_000_000}])
      calls = calls_until(reaction?("👍"))

      assert downloads(calls) == ["l"]

      assert {:download_file, _, "l", opts} =
               Enum.find(calls, &match?({:download_file, _, _, _}, &1))

      assert opts[:max_bytes] == 10 * 1_048_576
    end

    test "with no caption is asked about in the user's language", ctx do
      model_says("A picture.")

      photo(ctx)
      calls_until(reaction?("👍"))

      assert user_messages(ctx.user) == [
               Gettext.with_locale(PhoenixKitAgent.Gettext, "en", fn ->
                 Gettext.gettext(PhoenixKitAgent.Gettext, "What is in this picture?")
               end)
             ]
    end

    test "a picture sent as a document (png) is taken too", ctx do
      model_says("Seen.")

      document(ctx, "image/png", caption: "From a file")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["Seen."]
      assert downloads(calls) == ["doc-id"]
      assert_received {:model_request, body}
      assert images_in(body) == 1
    end

    test "the uploader is the linked user, and the file is theirs alone", ctx do
      model_says("Ok.")

      photo(ctx)
      calls_until(reaction?("👍"))

      assert [%Attachment{user_uuid: user_uuid, file_uuid: file_uuid}] = attachments(ctx.user)
      assert user_uuid == ctx.user.uuid
      assert file_uuid
      assert Repo.aggregate(Attachment, :count) == 1
    end

    test "a model that does not see is told so, nothing is stored", ctx do
      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)
      model_says("never")

      photo(ctx, caption: "Look")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:no_vision_model)]
      assert attachments(ctx.user) == []
      assert user_messages(ctx.user) == []
      refute_received {:model_request, _}
    end

    test "a model that does not see gets a description from the vision model", ctx do
      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)

      eyes =
        endpoint_fixture(%{
          model: "a/eyes",
          provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/eyes"}}
        })

      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", eyes.uuid)
      model_says("It says SOFA 3 PCS.")

      photo(ctx, caption: "What does it say?")
      calls = calls_until(reaction?("👍"))

      assert texts(calls) == ["It says SOFA 3 PCS."]
      # The description, then the turn: the second call carries no pixels.
      assert_received {:model_request, _description}
      assert_received {:model_request, turn}
      assert images_in(turn) == 0
    end

    test "a picture that cannot be read is told, with no turn and no file left", ctx do
      eyes =
        endpoint_fixture(%{
          model: "a/eyes",
          provider_settings: %{"capabilities" => %{"vision" => "yes", "model" => "a/eyes"}}
        })

      other = chat_endpoint("no")
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", other.uuid)
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", eyes.uuid)

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "x"}})
      end)

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.attachment_error("model_error")]
      assert attachments(ctx.user) == []
      assert user_messages(ctx.user) == []
    end

    test "a document that says it is a picture and is not is refused", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:ok, Files.text_pdf(["Hello"])} end)
      model_says("never")

      document(ctx, "image/png")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:unsupported_type)]
      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
    end

    test "a pdf document stays refused as text only", ctx do
      document(ctx, "application/pdf")
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.static(:text_only)]
      assert downloads(calls) == []
    end

    test "a file Telegram will not give is told, no turn", ctx do
      TelegramClient.set(:download, fn _id, _opts -> {:error, :unreachable} end)

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.picture(:download_failed)]
      assert attachments(ctx.user) == []
    end

    test "one over the limit by its own count is too large", ctx do
      photo(ctx, sizes: [{"huge", 12_000_000}])
      calls = calls_until(reaction?("🤷"))

      assert downloads(calls) == []
      assert texts(calls) == [Texts.picture(:too_large)]
    end

    test "a turn that is refused leaves no file behind", ctx do
      Repo.insert!(%PhoenixKitAgent.Schemas.UserSettings{
        user_uuid: ctx.user.uuid,
        daily_turn_limit: 0
      })

      model_says("never")

      photo(ctx, caption: "Look")
      calls_until(reaction?("🤷"))

      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
    end

    test "from a chat without agent.telegram: refused before the download", ctx do
      other = user_with(["agent"], "no-telegram")
      telegram_link_fixture(other, ctx.connection, 555)

      extra = %{"photo" => [%{"file_id" => "x", "file_size" => 10}]}
      Bridge.dispatch(ctx.connection, TelegramClient.update(555, nil, extra: extra))
      assert_receive {:tg, {:send_message, _, 555, text}}, 5_000
      settle()

      assert text == Texts.picture(:forbidden)
      refute_received {:tg, {:download_file, _, _, _}}
    end

    test "waits for the picture to be read, but not for ever", ctx do
      Application.put_env(:phoenix_kit_agent, :telegram_attachment_wait_ms, 300)
      holder = hold_every_place(ctx.user)
      model_says("never")

      photo(ctx)
      calls = calls_until(reaction?("🤷"))

      assert texts(calls) == [Texts.attachment_error("timeout")]
      assert attachments(ctx.user) == []
      refute_received {:model_request, _}
      send(holder, :release)
      processing_ended()
    end

    test "nothing of the picture or its caption is logged", ctx do
      secret = "SECRET-CAPTION"

      {_result, events} =
        LogProbe.capture(fn ->
          model_says("Fine.")
          photo(ctx, caption: secret)
          calls_until(reaction?("👍"))
          settle()
        end)

      refute Enum.any?(events, &String.contains?(&1, secret))
    end
  end

  # ── an album is one question ─────────────────────────────────────────

  describe "an album" do
    test "is one turn: the pictures together, the first caption there is", ctx do
      model_says("Two squares.")

      photo(ctx, media_group_id: "g1", message_id: 1, sizes: [{"a", 100}])

      photo(ctx,
        media_group_id: "g1",
        message_id: 2,
        caption: "Compare them",
        sizes: [{"b", 100}]
      )

      photo(ctx, media_group_id: "g1", message_id: 3, sizes: [{"c", 100}])

      calls = calls_until(reaction?("👍"))

      assert Enum.sort(downloads(calls)) == ["a", "b", "c"]
      assert texts(calls) == ["Two squares."]
      assert user_messages(ctx.user) == ["Compare them"]
      assert_received {:model_request, body}
      assert images_in(body) == 3
      refute_received {:model_request, _}
      settle()
      assert Enum.all?(attachments(ctx.user), &(&1.message_uuid != nil))
    end

    test "pictures of another album, or none, are turns of their own", ctx do
      model_says("Answer.")

      photo(ctx, media_group_id: "g1", message_id: 1, sizes: [{"a", 100}])
      photo(ctx, media_group_id: "g2", message_id: 2, sizes: [{"b", 100}])

      calls_until(reaction?("👍"))
      calls_until(reaction?("👍"))

      settle()
      assert length(user_messages(ctx.user)) == 2
    end
  end

  defp processing_ended(tries \\ 200) do
    if tries > 0 and Task.Supervisor.children(PhoenixKitAgent.Attachments.TaskSupervisor) != [] do
      Process.sleep(10)
      processing_ended(tries - 1)
    end
  end

  # A process that holds every place for the user's files until `:release`.
  defp hold_every_place(user) do
    test = self()

    holder =
      spawn_link(fn ->
        for _ <- 1..Bounds.get(:jobs_per_user) do
          :ok = Slots.acquire(user.uuid)
        end

        send(test, :holding)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :holding, 5_000
    holder
  end
end
