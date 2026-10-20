defmodule PhoenixKitAgent.TurnsTest do
  @moduledoc """
  The turn loop (spec §6.1, §6.4, §6.6, §8): a user message, then model ↔ tool
  rounds over the session's read tools, with the chat and the user locked while
  it runs.

  The model is a `Req.Test` stub of the provider behind `phoenix_kit_ai`
  (every request body reaches the test process); the tools are
  `PhoenixKitAgent.Test.Tools`, registered in core's module registry and run
  through the real `PhoenixKit.API.Executor` with real sessions, roles and
  permissions.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Test.Tools
  alias PhoenixKitAgent.Turns

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      stop_all_turns()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentTurns#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("turns")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, role: role, ref: ref, token: token, chat: chat, endpoint: endpoint}
  end

  # ── the model stub ──────────────────────────────────────────────────

  defp text_answer(text) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}],
      "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
    }
  end

  defp tool_answer(calls) do
    %{
      "model" => @model,
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => calls},
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 9, "total_tokens" => 29}
    }
  end

  defp call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  # The next model request is answered with `answer`; its body goes to the
  # test process as `{:model_request, body}`. `before` runs in the turn's
  # process before the answer (to change the world between two rounds).
  defp answer_next(answer, before \\ fn -> :ok end) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      before.()
      Req.Test.json(conn, answer)
    end)
  end

  # The next model request waits until the test kills the turn.
  defp hang_next do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :never -> conn
      end
    end)
  end

  defp error_next(status) do
    Req.Test.expect(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => %{"message" => "boom"}}))
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp start!(ctx, text, opts \\ []) do
    assert {:ok, turn_ref} =
             Turns.start(
               ctx.ref,
               false,
               ctx.chat.uuid,
               text,
               Keyword.get(opts, :attachments, []),
               Keyword.drop(opts, [:attachments])
             )

    turn_ref
  end

  defp await_end(chat, turn_ref) do
    chat_uuid = chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 5_000
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp lock_of(chat) do
    c = Repo.get!(Conversation, chat.uuid)
    {c.busy_since, c.busy_turn_ref}
  end

  defp user_lock_of(user) do
    case Repo.get(UserSettings, user.uuid) do
      nil -> {nil, nil}
      s -> {s.busy_since, s.busy_turn_ref}
    end
  end

  defp unlocked?(ctx),
    do: lock_of(ctx.chat) == {nil, nil} and user_lock_of(ctx.user) == {nil, nil}

  defp tool_names(body), do: Enum.map(body["tools"] || [], & &1["function"]["name"])

  defp stop_all_turns do
    for pid <- Task.Supervisor.children(PhoenixKitAgent.Turns.TaskSupervisor) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    _ = :sys.get_state(PhoenixKitAgent.Turns.Monitor)
  end

  # ── a turn ──────────────────────────────────────────────────────────

  describe "a turn with a tool call" do
    test "tool call → result → answer, in two rounds", ctx do
      answer_next(tool_answer([call("call_1", "agenttest_list_items", %{"query" => "chairs"})]))
      answer_next(text_answer("There are 3 items."))

      turn_ref = start!(ctx, "How many items?")
      await_end(ctx.chat, turn_ref)

      user_uuid = ctx.user.uuid
      assert_received {:agent_test_tool, "agenttest.list_items", %{"query" => "chairs"}, tool_ctx}
      assert tool_ctx.scope.user.uuid == user_uuid

      assert_received {:model_request, first}
      assert tool_names(first) == ["agenttest_list_items"]
      assert [%{"role" => "user", "content" => "How many items?"}] = first["messages"]

      assert_received {:model_request, second}
      assert [_user, assistant, tool] = second["messages"]
      assert assistant["role"] == "assistant"

      assert [%{"id" => "call_1", "function" => %{"name" => "agenttest_list_items"}}] =
               assistant["tool_calls"]

      assert tool["role"] == "tool"
      assert tool["tool_call_id"] == "call_1"
      assert %{"items" => ["chair", "table", "lamp"]} = Jason.decode!(tool["content"])

      assert [user_msg, call_msg, tool_msg, answer_msg] = messages(ctx.chat)
      assert {user_msg.role, user_msg.content} == {"user", "How many items?"}
      assert call_msg.role == "assistant"

      assert [%{"id" => "call_1", "name" => "agenttest_list_items", "arguments" => _}] =
               call_msg.tool_calls

      assert tool_msg.role == "tool"
      assert tool_msg.tool_name == "agenttest.list_items"
      assert tool_msg.tool_call_id == "call_1"
      assert tool_msg.tool_outcome == "ok"
      assert %{"items" => ["chair", "table", "lamp"]} = tool_msg.tool_result
      assert {answer_msg.role, answer_msg.content} == {"assistant", "There are 3 items."}
      assert answer_msg.model == @model
      assert answer_msg.input_tokens == 11
      assert answer_msg.output_tokens == 4

      assert Enum.all?([user_msg, call_msg, tool_msg, answer_msg], &(&1.turn_ref == turn_ref))
      assert unlocked?(ctx)
    end

    test "every message is broadcast on the chat's topic", ctx do
      answer_next(text_answer("Hi."))
      turn_ref = start!(ctx, "Hello")
      await_end(ctx.chat, turn_ref)

      chat_uuid = ctx.chat.uuid

      for message <- messages(ctx.chat) do
        message_uuid = message.uuid
        assert_received {:agent_message_added, ^chat_uuid, ^message_uuid}
      end
    end

    test "each model message is linked to its AI request row", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]))
      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assistants = Enum.filter(messages(ctx.chat), &(&1.role == "assistant"))
      assert length(assistants) == 2

      for message <- assistants do
        assert is_binary(message.ai_request_uuid)
        request = Repo.get!(PhoenixKitAI.Request, message.ai_request_uuid)
        assert request.user_uuid == ctx.user.uuid
        assert request.metadata["source"] == "agent"
        # agent_capture_ai_content is off: the call keeps the bodies out.
        assert request.metadata["content_redacted"] == true
        assert request.metadata["attribution"] == %{"agent_message_uuid" => message.uuid}
      end
    end

    test "the module's prompt and the admin's prompt for the user are the system message",
         ctx do
      {:ok, _} = Settings.update_setting("agent_system_prompt", "You help with furniture.")

      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, system_prompt: "Answer in Estonian."})

      answer_next(text_answer("Tere."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "system", "content" => system}, %{"role" => "user"}] = body["messages"]
      assert system =~ "You help with furniture."
      assert system =~ "Answer in Estonian."

      assert :binary.match(system, "You help with furniture.") <
               :binary.match(system, "Answer in Estonian.")
    end

    test "a model error ends the turn with a notice and frees the locks", ctx do
      error_next(500)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice"} = notice] = messages(ctx.chat)
      assert notice.error =~ "api_error"
      assert is_binary(notice.ai_request_uuid)
      assert unlocked?(ctx)
    end

    test "the rounds stop at agent_max_tool_rounds with a notice", ctx do
      {:ok, _} = Settings.update_setting("agent_max_tool_rounds", "2")

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]))
      answer_next(tool_answer([call("c2", "agenttest_list_items", %{})]))

      turn_ref = start!(ctx, "Loop")
      await_end(ctx.chat, turn_ref)

      assert %Message{role: "notice", error: "max_tool_rounds"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end
  end

  # ── what the model may call (spec §6.2, §8) ────────────────────────

  describe "the tools of a round" do
    test "the model sees the session's read tools only, without control fields", ctx do
      answer_next(text_answer("ok"))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, body}
      # write_item writes; secret_items needs `users`, which the user lacks.
      assert tool_names(body) == ["agenttest_list_items"]

      for %{"function" => %{"parameters" => schema}} <- body["tools"] do
        for field <- ["dry_run", "confirm_token", "idempotency_key"] do
          refute Map.has_key?(schema["properties"] || %{}, field)
          refute field in (schema["required"] || [])
        end
      end
    end

    test "a write tool named by the model is denied: no handler, nothing written", ctx do
      answer_next(
        tool_answer([
          call("w1", "agenttest_write_item", %{"name" => "x"}),
          call("w2", "agenttest.write_item", %{"name" => "y"})
        ])
      )

      answer_next(text_answer("I cannot write."))

      turn_ref = start!(ctx, "Write something")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert Settings.get_setting("agenttest_written") == nil

      tools = Enum.filter(messages(ctx.chat), &(&1.role == "tool"))
      assert Enum.map(tools, & &1.tool_call_id) == ["w1", "w2"]
      assert Enum.all?(tools, &(&1.tool_outcome == "denied"))

      assert_received {:model_request, _first}
      assert_received {:model_request, second}
      denied = Enum.filter(second["messages"], &(&1["role"] == "tool"))
      assert length(denied) == 2
    end

    test "a tool the session cannot see is denied", ctx do
      answer_next(tool_answer([call("s1", "agenttest_secret_items", %{})]))
      answer_next(text_answer("No."))

      turn_ref = start!(ctx, "Secrets?")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, "agenttest.secret_items", _, _}

      assert %Message{tool_outcome: "denied"} =
               Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "a tool shown in an earlier round but not in this one is denied", ctx do
      # Round 1 shows list_items; before the answer the role loses `dashboard`,
      # so round 2 shows nothing and the call the model makes there is denied.
      answer_next(text_answer_with_tool("r1", %{}), fn ->
        :ok = revoke(ctx.role, "dashboard")
      end)

      answer_next(tool_answer([call("r2", "agenttest_list_items", %{})]))
      answer_next(text_answer("Done."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, first}
      assert tool_names(first) == ["agenttest_list_items"]
      assert_received {:model_request, second}
      assert tool_names(second) == []

      outcomes =
        for %Message{role: "tool"} = m <- messages(ctx.chat), do: {m.tool_call_id, m.tool_outcome}

      # r1 ran under round 1's set but the session no longer held the
      # permission: the executor refused it. r2 never reached the executor.
      assert {"r2", "denied"} in outcomes
      refute_received {:agent_test_tool, _, _, _}
    end

    test "control fields are cut from the arguments before the executor", ctx do
      args = %{
        "query" => "lamps",
        "dry_run" => true,
        "confirm_token" => "abc",
        "idempotency_key" => "key-1234567890abcdef"
      }

      answer_next(tool_answer([call("c1", "agenttest_list_items", args)]))
      answer_next(text_answer("Lamps."))

      turn_ref = start!(ctx, "Lamps?")
      await_end(ctx.chat, turn_ref)

      assert_received {:agent_test_tool, "agenttest.list_items", input, _ctx}
      assert input == %{"query" => "lamps"}
      assert %Message{tool_outcome: "ok"} = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "arguments that are not a JSON object are an error, the executor is not called",
         ctx do
      bad = %{
        "id" => "b1",
        "type" => "function",
        "function" => %{"name" => "agenttest_list_items", "arguments" => "not json"}
      }

      answer_next(tool_answer([bad]))
      answer_next(text_answer("Sorry."))

      turn_ref = start!(ctx, "List")
      await_end(ctx.chat, turn_ref)

      refute_received {:agent_test_tool, _, _, _}
      assert %Message{tool_outcome: "error"} = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
    end

    test "a long result is cut to agent_tool_result_chars, marked truncated", ctx do
      {:ok, _} = Settings.update_setting("agent_tool_result_chars", "500")

      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"size" => 5_000})]))
      answer_next(text_answer("Long."))

      turn_ref = start!(ctx, "Big")
      await_end(ctx.chat, turn_ref)

      tool_msg = Enum.find(messages(ctx.chat), &(&1.role == "tool"))
      assert tool_msg.tool_result["truncated"] == true
      assert is_binary(tool_msg.tool_result["hint"])
      assert String.length(Jason.encode!(tool_msg.tool_result)) <= 500

      assert_received {:model_request, _}
      assert_received {:model_request, second}
      sent = Enum.find(second["messages"], &(&1["role"] == "tool"))
      assert String.length(sent["content"]) <= 500
      assert Jason.decode!(sent["content"])["truncated"] == true
    end
  end

  defp text_answer_with_tool(id, args), do: tool_answer([call(id, "agenttest_list_items", args)])

  defp revoke(role, key), do: Permissions.revoke_permission(role.uuid, key)

  # ── the history (spec §6.6) ─────────────────────────────────────────

  describe "the history" do
    test "earlier turns give their user texts and final answers, not their tool results",
         ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{"query" => "old"})]))
      answer_next(text_answer("Three old items."))
      first = start!(ctx, "Old question")
      await_end(ctx.chat, first)

      answer_next(text_answer("New answer."))
      second = start!(ctx, "New question")
      await_end(ctx.chat, second)

      assert_received {:model_request, _}
      assert_received {:model_request, _}
      assert_received {:model_request, body}

      assert body["messages"] == [
               %{"role" => "user", "content" => "Old question"},
               %{"role" => "assistant", "content" => "Three old items."},
               %{"role" => "user", "content" => "New question"}
             ]
    end

    test "the oldest messages are left out beyond agent_history_chars", ctx do
      {:ok, _} = Settings.update_setting("agent_history_chars", "1000")
      old = String.duplicate("o", 900)

      answer_next(text_answer("a"))
      first = start!(ctx, old)
      await_end(ctx.chat, first)

      answer_next(text_answer("b"))
      second = start!(ctx, String.duplicate("n", 200))
      await_end(ctx.chat, second)

      assert_received {:model_request, _}
      assert_received {:model_request, body}
      contents = Enum.map(body["messages"], & &1["content"])
      refute old in contents
      assert List.last(contents) == String.duplicate("n", 200)
    end
  end

  # ── who may start a turn ────────────────────────────────────────────

  describe "starting a turn" do
    test "an impersonated session is refused: nothing saved, no model call", ctx do
      assert {:error, :impersonated} = Turns.start(ctx.ref, true, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
      refute_received {:model_request, _}
      assert unlocked?(ctx)
    end

    test "the impersonation flag must be a boolean", ctx do
      assert_raise ArgumentError, fn -> Turns.start(ctx.ref, nil, ctx.chat.uuid, "Hi") end
    end

    test "someone else's chat is not found", ctx do
      other = user_with(["agent", "dashboard"], "other")
      {other_ref, _} = session_fixture(other)

      assert {:error, :not_found} = Turns.start(other_ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end

    test "a revoked session is refused", ctx do
      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
    end

    test "a blank message is refused", ctx do
      assert {:error, :empty_message} = Turns.start(ctx.ref, false, ctx.chat.uuid, "   ")
    end

    test "with the AI module off there is no turn", ctx do
      {:ok, _} = PhoenixKitAI.disable_system()
      assert {:error, :ai_disabled} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end

    test "without an endpoint there is no turn", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", "none")
      assert {:error, :no_endpoint} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert unlocked?(ctx)
    end
  end

  # ── the locks (spec §6.1 step 3) ───────────────────────────────────

  describe "the locks" do
    test "a second turn in the same chat is refused while one runs", ctx do
      hang_next()
      turn_ref = start!(ctx, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Second")
      assert {_, ^turn_ref} = lock_of(ctx.chat)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)
    end

    test "two chats of one user: the second turn is refused while the first runs", ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      hang_next()
      turn_ref = start!(ctx, "First")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :turn_in_flight} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      assert messages(other_chat) == []
      assert lock_of(other_chat) == {nil, nil}

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      answer_next(text_answer("Now."))
      assert {:ok, second} = Turns.start(ctx.ref, false, other_chat.uuid, "Second")
      await_end(other_chat, second)
    end

    test "a killed turn frees both locks", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000
      refute unlocked?(ctx)

      [{pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)
      Process.exit(pid, :kill)
      await_end(ctx.chat, turn_ref)

      assert unlocked?(ctx)
      assert %Message{role: "notice", error: "interrupted"} = List.last(messages(ctx.chat))
    end

    test "a lock older than the deadline plus 60 s is taken over", ctx do
      stale = DateTime.add(DateTime.utc_now(), -(300 + 61), :second)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: stale, busy_turn_ref: "dead"]
      )

      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        busy_since: stale,
        busy_turn_ref: "dead"
      })

      answer_next(text_answer("Back."))
      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)
      assert unlocked?(ctx)
    end

    test "a fresh lock of a turn that is gone still blocks until its TTL", ctx do
      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "other"]
      )

      assert {:error, :conversation_busy} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi")
      assert messages(ctx.chat) == []
    end
  end

  # ── ending a turn early ─────────────────────────────────────────────

  describe "stop, deadline, revoked session" do
    test "stop ends the turn: no answer saved, locks freed", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      assert :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}] = messages(ctx.chat)
      assert unlocked?(ctx)
    end

    test "only the owner's session stops a turn", ctx do
      other = user_with(["agent", "dashboard"], "other")
      {other_ref, _} = session_fixture(other)

      hang_next()
      turn_ref = start!(ctx, "Hi")
      assert_receive {:model_waiting, _pid}, 5_000

      assert {:error, :not_found} = Turns.stop(other_ref, false, ctx.chat.uuid)
      assert {:error, :impersonated} = Turns.stop(ctx.ref, true, ctx.chat.uuid)
      assert [{_pid, _}] = Registry.lookup(PhoenixKitAgent.Turns.Registry, turn_ref)

      :ok = Turns.stop(ctx.ref, false, ctx.chat.uuid)
      await_end(ctx.chat, turn_ref)
    end

    test "stop with no turn running", ctx do
      assert {:error, :not_running} = Turns.stop(ctx.ref, false, ctx.chat.uuid)
    end

    test "the deadline ends the turn with a notice and frees the locks", ctx do
      hang_next()
      turn_ref = start!(ctx, "Hi", deadline_ms: 200)
      assert_receive {:model_waiting, _pid}, 5_000
      await_end(ctx.chat, turn_ref)

      assert [%Message{role: "user"}, %Message{role: "notice", error: "deadline"}] =
               messages(ctx.chat)

      assert unlocked?(ctx)
    end

    test "a session revoked during the turn stops it with a notice", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        Auth.delete_user_session_token(ctx.token)
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      # One model call only: round 2 found the session gone.
      assert_received {:model_request, _}
      refute_received {:model_request, _}
      refute_received {:agent_test_tool, _, _, _}

      assert %Message{role: "notice", error: "session_gone"} = List.last(messages(ctx.chat))
      assert unlocked?(ctx)
    end

    test "a user who loses `agent` during the turn is stopped", ctx do
      answer_next(tool_answer([call("c1", "agenttest_list_items", %{})]), fn ->
        :ok = revoke(ctx.role, "agent")
      end)

      turn_ref = start!(ctx, "Hi")
      await_end(ctx.chat, turn_ref)

      assert_received {:model_request, _}
      refute_received {:model_request, _}
      assert %Message{role: "notice", error: "forbidden"} = List.last(messages(ctx.chat))
    end
  end

  # ── the AI request link of a stored message ────────────────────────

  describe "handle_ai_usage/1 for a message already stored" do
    defp attributed(request, message_uuid) do
      %{
        request
        | metadata:
            Map.put(request.metadata, "attribution", %{"agent_message_uuid" => message_uuid})
      }
    end

    defp answer!(ctx) do
      {:ok, message} =
        Conversations.add_message(ctx.ref, ctx.chat.uuid, %{role: "assistant", content: "x"}, @me)

      message
    end

    test "links the user's own message that has no request yet", ctx do
      message = answer!(ctx)
      request = ai_request_fixture(ctx.user, ctx.endpoint)

      assert :ok = PhoenixKitAgent.handle_ai_usage(attributed(request, message.uuid))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == request.uuid
    end

    test "does not link a request of another user, nor relink a linked message", ctx do
      message = answer!(ctx)
      first = ai_request_fixture(ctx.user, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(first, message.uuid))

      second = ai_request_fixture(ctx.user, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(second, message.uuid))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == first.uuid

      other = user_fixture("other")
      other_message = answer!(ctx)
      foreign = ai_request_fixture(other, ctx.endpoint)
      :ok = PhoenixKitAgent.handle_ai_usage(attributed(foreign, other_message.uuid))
      assert Repo.get!(Message, other_message.uuid).ai_request_uuid == nil
    end

    test "ignores a request without an agent attribution", ctx do
      message = answer!(ctx)
      request = ai_request_fixture(ctx.user, ctx.endpoint)

      assert :ok = PhoenixKitAgent.handle_ai_usage(request)
      assert :ok = PhoenixKitAgent.handle_ai_usage(attributed(request, "junk"))
      assert Repo.get!(Message, message.uuid).ai_request_uuid == nil
    end
  end

  # ── attachments ─────────────────────────────────────────────────────

  describe "attachments" do
    defp attachment!(user, chat, attrs) do
      %Attachment{user_uuid: user.uuid, conversation_uuid: chat.uuid}
      |> Attachment.changeset(
        Map.merge(
          %{filename: "notes.txt", content_type: "text/plain", size_bytes: 10, kind: "text"},
          attrs
        )
      )
      |> Repo.insert!()
    end

    test "a ready attachment of the chat is linked to the message and its text sent", ctx do
      att = attachment!(ctx.user, ctx.chat, %{status: "ready", extracted_text: "Sofa 3 pcs"})

      answer_next(text_answer("Read it."))
      turn_ref = start!(ctx, "See file", attachments: [att.uuid])
      await_end(ctx.chat, turn_ref)

      [user_msg | _] = messages(ctx.chat)
      assert Repo.get!(Attachment, att.uuid).message_uuid == user_msg.uuid

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = body["messages"]
      assert content =~ "See file"
      assert content =~ "Sofa 3 pcs"
      assert content =~ "notes.txt"
    end

    test "an attachment of someone else, or not ready, is refused", ctx do
      other = user_fixture("other")
      other_chat = conversation_fixture(other)
      foreign = attachment!(other, other_chat, %{status: "ready", extracted_text: "x"})
      pending = attachment!(ctx.user, ctx.chat, %{status: "pending"})

      for uuid <- [foreign.uuid, pending.uuid, UUIDv7.generate(), "junk"] do
        assert {:error, :invalid_attachments} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [uuid])
      end

      assert messages(ctx.chat) == []
      assert unlocked?(ctx)
    end
  end
end
