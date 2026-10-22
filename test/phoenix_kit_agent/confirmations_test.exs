defmodule PhoenixKitAgent.ConfirmationsTest do
  @moduledoc """
  A write of the assistant (spec §12 Ф2, Б2.2): the model asks for it in a turn,
  core holds it for the user's confirmation (`PhoenixKit.API.Executor.execute_as/5`
  with `allow: :all`), the turn ends with the card, and the user's click runs it
  (`PhoenixKitAgent.Confirmations`, `Executor.redeem_as/6`), turns it down or asks
  for it again.

  The model is a `Req.Test` stub of the provider behind `phoenix_kit_ai`; the
  tools are `PhoenixKitAgent.Test.Tools` (its write, `agenttest.write_item`,
  previews and writes the setting `agenttest_written`), run through the real
  executor with real sessions, roles, permissions and confirmation rows.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Confirmations, Conversations, Turns}
  alias PhoenixKitAgent.Schemas.{Message, UserSettings}
  alias PhoenixKitAgent.Test.{LogProbe, Tools}
  alias PhoenixKitAgent.Turns.Locks

  @stub __MODULE__
  @me [impersonated: false]
  @model "deepseek/deepseek-v4.1-flash"
  @write "agenttest_write_item"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    open_writes(true)

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    Application.put_env(:phoenix_kit_agent, :test_tool_listener, self())

    on_exit(fn ->
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :test_tool_listener)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentConfirm#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("confirm")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, role: role, ref: ref, token: token, chat: chat}
  end

  # The test tools' module may (or may not) let a live session write
  # (`api_session_write_modules`, the "Agent may act" box of Settings -> API).
  defp open_writes(true),
    do: {:ok, _} = Settings.update_setting("api_session_write_modules", "agent_test_tools")

  defp open_writes(false),
    do: Repo.delete_all(from(s in Setting, where: s.key == "api_session_write_modules"))

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

  defp answer_next(answer) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      Req.Test.json(conn, answer)
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp run_turn(ctx, text) do
    assert {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, text, [], [])
    chat_uuid = ctx.chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 5_000
    turn_ref
  end

  # A turn whose model asks for one write; returns the tool message of its card.
  defp card!(ctx, args \\ %{"name" => "new"}) do
    answer_next(tool_answer([call("w1", @write, args)]))
    run_turn(ctx, "Rename the item")
    assert_received {:model_request, _body}
    [card] = cards(ctx.chat)
    card
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp cards(chat),
    do:
      Enum.filter(
        messages(chat),
        &(&1.role == "tool" and &1.tool_outcome == "needs_confirmation")
      )

  defp outcome_notices(chat),
    do: Enum.filter(messages(chat), &(&1.role == "notice" and &1.confirmation_uuid != nil))

  defp row(uuid), do: Repo.get!(Confirmation, uuid)

  defp expire!(uuid) do
    past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(c in Confirmation, where: c.uuid == ^uuid), set: [expires_at: past])
  end

  defp written, do: Settings.get_setting("agenttest_written")

  defp confirm(ctx, card, opts \\ []),
    do: Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, card.uuid, opts)

  defp card_state(ctx, card) do
    assert {:ok, %{} = by_uuid} = Confirmations.cards(ctx.ref, false, ctx.chat.uuid, [card])
    Map.fetch!(by_uuid, card.uuid)
  end

  # ── the turn ────────────────────────────────────────────────────────

  describe "a write asked for in a turn" do
    test "the model sees the write tool only when its module lets a session write", ctx do
      answer_next(text_answer("ok"))
      run_turn(ctx, "Hi")
      assert_received {:model_request, open}
      assert @write in Enum.map(open["tools"], & &1["function"]["name"])

      open_writes(false)
      answer_next(text_answer("ok"))
      run_turn(ctx, "Hi again")
      assert_received {:model_request, closed}
      refute @write in Enum.map(closed["tools"] || [], & &1["function"]["name"])
    end

    test "a write of a module that is not opened is denied: no preview, no card", ctx do
      open_writes(false)
      answer_next(tool_answer([call("w1", @write, %{"name" => "x"})]))
      answer_next(text_answer("I cannot."))

      run_turn(ctx, "Rename")

      refute_received {:agent_test_preview, _}

      assert [%Message{tool_outcome: "denied"}] =
               Enum.filter(messages(ctx.chat), &(&1.role == "tool"))

      assert cards(ctx.chat) == []
    end

    test "dry_run: false and confirm_token are cut: a preview, a card, nothing written", ctx do
      args = %{"name" => "new", "dry_run" => false, "confirm_token" => "forged-token"}
      card = card!(ctx, args)

      assert_received {:agent_test_preview, %{"name" => "new"} = input}
      refute Map.has_key?(input, "dry_run")
      refute Map.has_key?(input, "confirm_token")
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert written() == nil

      assert card.tool_name == "agenttest.write_item"
      assert card.tool_call_id == "w1"
      assert is_binary(card.confirmation_uuid)
      assert %Message{role: "assistant"} = Repo.get!(Message, card.assistant_message_uuid)

      # Only the uuid of the confirmation: no code, no preview, no arguments.
      assert card.tool_result == %{
               "status" => "confirmation_required",
               "confirmation_id" => card.confirmation_uuid
             }

      assert row(card.confirmation_uuid).status == "unused"
      assert row(card.confirmation_uuid).actor_user_uuid == ctx.user.uuid
    end

    test "the turn ends with the card: the model is not called again", ctx do
      answer_next(
        tool_answer([
          call("r1", "agenttest_list_items", %{"query" => "chairs"}),
          call("w1", @write, %{"name" => "new"})
        ])
      )

      run_turn(ctx, "List and rename")

      assert_received {:model_request, _first}
      refute_received {:model_request, _second}

      # The read of the same round ran; the last message is the card.
      assert_received {:agent_test_tool, "agenttest.list_items", _, _}

      assert %Message{role: "tool", tool_outcome: "needs_confirmation"} =
               List.last(messages(ctx.chat))

      refute Enum.any?(messages(ctx.chat), &(&1.role == "assistant" and is_binary(&1.content)))
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a second write of the round is denied: confirm the first one first", ctx do
      answer_next(
        tool_answer([
          call("w1", @write, %{"name" => "first"}),
          call("w2", @write, %{"name" => "second"})
        ])
      )

      run_turn(ctx, "Rename twice")

      assert_received {:agent_test_preview, %{"name" => "first"}}
      refute_received {:agent_test_preview, %{"name" => "second"}}

      tools = Enum.filter(messages(ctx.chat), &(&1.role == "tool"))

      assert Enum.map(tools, &{&1.tool_call_id, &1.tool_outcome}) == [
               {"w1", "needs_confirmation"},
               {"w2", "denied"}
             ]

      assert [_one] =
               Repo.all(from(c in Confirmation, where: c.actor_user_uuid == ^ctx.user.uuid))

      assert %{"error" => "denied", "message" => message} = List.last(tools).tool_result
      assert message =~ "Confirm"
    end

    test "a write whose call id is not unique in the answer is denied", ctx do
      answer_next(
        tool_answer([
          call("same", "agenttest_list_items", %{}),
          call("same", @write, %{"name" => "new"})
        ])
      )

      answer_next(text_answer("Done."))
      run_turn(ctx, "Twice")

      refute_received {:agent_test_preview, _}
      assert cards(ctx.chat) == []
    end

    test "the next turn's history has no token, no preview and no tool result", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)

      answer_next(text_answer("Anything else?"))
      run_turn(ctx, "Thanks")
      assert_received {:model_request, body}

      json = Jason.encode!(body["messages"])
      refute json =~ card.confirmation_uuid
      refute json =~ "confirmation_required"
      refute json =~ "\"rows\""
      refute Enum.any?(body["messages"], &(&1["role"] == "tool"))

      # The outcome is said in the module's own words, as a user message.
      assert %{"role" => "user", "content" => "[confirmation] done: agenttest_write_item"} in body[
               "messages"
             ]
    end

    test "the outcome is said in the user's language; other notices stay out", ctx do
      card = card!(ctx)
      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      {:ok, _} =
        Conversations.add_turn_message(ctx.user.uuid, ctx.chat.uuid, %{
          role: "notice",
          content: "OTHER-NOTICE",
          error: "empty_answer"
        })

      Gettext.put_locale(PhoenixKitAgent.Gettext, "ru")
      on_exit(fn -> Gettext.put_locale(PhoenixKitAgent.Gettext, "en") end)

      answer_next(text_answer("Хорошо."))
      run_turn(ctx, "Ладно")
      assert_received {:model_request, body}

      assert %{"role" => "user", "content" => "[подтверждение] отменено: agenttest_write_item"} in body[
               "messages"
             ]

      refute Jason.encode!(body["messages"]) =~ "OTHER-NOTICE"
    end
  end

  # ── the click ───────────────────────────────────────────────────────

  describe "confirm/5" do
    test "runs the write, notices confirmed, calls no model and spends no turn", ctx do
      card = card!(ctx)
      turns_before = Repo.aggregate(from(m in Message, where: m.role == "user"), :count)

      assert {:ok, :confirmed} = confirm(ctx, card)

      assert written() == "new"
      assert_received {:agent_test_tool, "agenttest.write_item", %{"name" => "new"}, tool_ctx}
      assert tool_ctx.confirmation_uuid == card.confirmation_uuid
      assert row(card.confirmation_uuid).status == "used"

      assert [notice] = outcome_notices(ctx.chat)
      assert notice.confirmation_uuid == card.confirmation_uuid
      assert notice.tool_outcome == "confirmed"
      assert notice.tool_name == "agenttest.write_item"
      assert notice.tool_result == nil

      refute_received {:model_request, _}
      assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == turns_before
      assert %{state: "confirmed", repeatable?: false} = card_state(ctx, card)
    end

    test "the click frees the user's lock it took", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)
      assert %UserSettings{busy_turn_ref: nil} = Repo.get!(UserSettings, ctx.user.uuid)
    end

    test "a second click runs nothing again", ctx do
      card = card!(ctx)
      assert {:ok, :confirmed} = confirm(ctx, card)
      assert {:error, :not_waiting} = confirm(ctx, card)

      assert_received {:agent_test_tool, "agenttest.write_item", _, _}
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [_one] = outcome_notices(ctx.chat)
    end

    test "while a turn of the user runs, the click is refused and the card waits", ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      :ok = Locks.acquire(ctx.user.uuid, other.uuid, "a-turn", 600)

      assert {:error, :turn_running} = confirm(ctx, card)

      assert written() == nil
      assert row(card.confirmation_uuid).status == "unused"
      assert outcome_notices(ctx.chat) == []
      assert %{state: "waiting"} = card_state(ctx, card)
    end

    test "after its time: expired, nothing written, and it can be asked for again", ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)

      assert {:ok, :expired} = confirm(ctx, card)
      assert written() == nil
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
      assert %{state: "expired", repeatable?: true} = card_state(ctx, card)

      assert {:ok, :repeated} = Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert [old, fresh] = cards(ctx.chat)
      assert old.uuid == card.uuid
      assert fresh.confirmation_uuid != card.confirmation_uuid
      assert fresh.assistant_message_uuid == card.assistant_message_uuid
      assert fresh.tool_call_id == card.tool_call_id
      assert %{state: "expired", repeatable?: false} = card_state(ctx, card)
      assert %{state: "waiting"} = card_state(ctx, fresh)

      assert {:ok, :confirmed} = confirm(ctx, fresh)
      assert written() == "new"
    end

    test "the data changed since the preview: a new card, nothing written", ctx do
      card = card!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_written", "someone else's")

      assert {:ok, :changed} = confirm(ctx, card)

      assert written() == "someone else's"
      refute_received {:agent_test_tool, "agenttest.write_item", _, _}
      assert [%Message{tool_outcome: "changed"}] = outcome_notices(ctx.chat)
      assert [_old, fresh] = cards(ctx.chat)
      assert fresh.assistant_message_uuid == card.assistant_message_uuid
      assert row(card.confirmation_uuid).status == "expired"

      assert %{state: "changed"} = card_state(ctx, card)
      assert %{state: "waiting", preview: preview} = card_state(ctx, fresh)
      assert %{"rows" => [%{"changes" => %{"name" => %{"from" => "someone else's"}}}]} = preview
    end

    test "a refusal before the confirmation is spent leaves the card waiting", ctx do
      card = card!(ctx)

      # The module's box was cleared after the card was made.
      open_writes(false)
      assert {:error, {:refused, :module_write_disabled}} = confirm(ctx, card)
      open_writes(true)

      # The person lost the permission the tool needs.
      :ok = Permissions.revoke_permission(ctx.role.uuid, "dashboard")
      assert {:error, {:refused, :forbidden}} = confirm(ctx, card)
      {:ok, _} = Permissions.grant_permission(ctx.role.uuid, "dashboard")

      assert written() == nil
      assert outcome_notices(ctx.chat) == []
      assert row(card.confirmation_uuid).status == "unused"
      assert %{state: "waiting"} = card_state(ctx, card)

      assert {:ok, :confirmed} = confirm(ctx, card)
    end

    test "a handler that refuses its dry run now leaves the card waiting", ctx do
      card = card!(ctx)
      {:ok, _} = Settings.update_setting("agenttest_locked", "yes")

      assert {:error, {:refused, :conflict}} = confirm(ctx, card)
      assert written() == nil
      assert outcome_notices(ctx.chat) == []
      assert row(card.confirmation_uuid).status == "unused"
      assert %{state: "waiting"} = card_state(ctx, card)
    end

    test "a handler that fails after the confirmation is spent: failed", ctx do
      card = card!(ctx, %{"name" => "fail"})

      assert {:ok, :failed} = confirm(ctx, card)
      assert [%Message{tool_outcome: "failed"}] = outcome_notices(ctx.chat)
      assert row(card.confirmation_uuid).status == "used"
      assert %{state: "failed", repeatable?: false} = card_state(ctx, card)
    end

    test "another user's session cannot confirm, reject or repeat it", ctx do
      card = card!(ctx)
      stranger = user_with(["agent", "dashboard"], "stranger")
      {stranger_ref, _token} = session_fixture(stranger)

      for action <- [:confirm, :reject, :repeat] do
        assert {:error, :not_found} =
                 apply(Confirmations, action, [stranger_ref, false, ctx.chat.uuid, card.uuid])
      end

      assert {:error, :not_found} =
               Confirmations.cards(stranger_ref, false, ctx.chat.uuid, [card])

      assert written() == nil
      assert row(card.confirmation_uuid).status == "unused"
      assert outcome_notices(ctx.chat) == []
    end

    test "an impersonated session is refused before anything is read", ctx do
      card = card!(ctx)

      for action <- [:confirm, :reject, :repeat] do
        assert {:error, :impersonated} =
                 apply(Confirmations, action, [ctx.ref, true, ctx.chat.uuid, card.uuid])
      end

      assert {:error, :impersonated} = Confirmations.cards(ctx.ref, true, ctx.chat.uuid, [card])
      assert row(card.confirmation_uuid).status == "unused"
    end

    test "a revoked session is refused, the card waits", ctx do
      card = card!(ctx)
      :ok = Auth.delete_user_session_token(ctx.token)

      assert {:error, :session_gone} = confirm(ctx, card)
      assert row(card.confirmation_uuid).status == "unused"
    end

    test "a message that is not a card is not confirmed", ctx do
      answer_next(text_answer("Hello."))
      run_turn(ctx, "Hi")
      [user_message | _] = messages(ctx.chat)

      assert {:error, :not_waiting} =
               Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, user_message.uuid)

      assert {:error, :not_waiting} =
               Confirmations.confirm(ctx.ref, false, ctx.chat.uuid, Ecto.UUID.generate())
    end

    test "nothing of the write reaches the log: not the arguments, not the preview", ctx do
      {result, events} =
        LogProbe.capture(fn ->
          card = card!(ctx, %{"name" => "SECRET-NAME-42"})
          {confirm(ctx, card), Confirmations.cards(ctx.ref, false, ctx.chat.uuid, [card])}
        end)

      assert {{:ok, :confirmed}, {:ok, _cards}} = result

      # Not the module's: the test tool's own write of its setting (core's
      # settings log it), and core's debug query log of the row it holds the
      # preview in (`Confirm.issue_for_user/6`, reported to core).
      leaks =
        events
        |> Enum.filter(&(&1 =~ "SECRET-NAME-42"))
        |> Enum.reject(
          &(&1 =~ "agenttest_written" or &1 =~ ~s(INSERT INTO \\"phoenix_kit_api_confirmations\\"))
        )

      assert leaks == []
    end
  end

  describe "reject/5" do
    test "turns it down: rejected, nothing written, and it cannot be confirmed after", ctx do
      card = card!(ctx)

      assert {:ok, :rejected} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert row(card.confirmation_uuid).status == "rejected"
      assert [%Message{tool_outcome: "rejected"}] = outcome_notices(ctx.chat)
      assert {:error, :not_waiting} = confirm(ctx, card)
      assert written() == nil
      assert %{state: "rejected", repeatable?: false} = card_state(ctx, card)
    end

    test "a card past its time is closed as expired", ctx do
      card = card!(ctx)
      expire!(card.confirmation_uuid)
      assert {:ok, :expired} = Confirmations.reject(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
    end
  end

  describe "repeat/5" do
    test "is refused for a card still waiting", ctx do
      card = card!(ctx)

      assert {:error, :not_expired} =
               Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)

      assert [_only] = cards(ctx.chat)
    end

    test "a card whose row core has deleted is asked for again too", ctx do
      card = card!(ctx)
      Repo.delete_all(from(c in Confirmation, where: c.uuid == ^card.confirmation_uuid))

      assert %{state: "expired", repeatable?: true} = card_state(ctx, card)
      assert {:ok, :repeated} = Confirmations.repeat(ctx.ref, false, ctx.chat.uuid, card.uuid)
      assert [_old, _fresh] = cards(ctx.chat)
      assert [%Message{tool_outcome: "expired"}] = outcome_notices(ctx.chat)
    end
  end

  describe "cards/4" do
    test "a waiting card: core's preview, the arguments as text, the time it runs out", ctx do
      card = card!(ctx, %{"name" => "<b>**bold**</b>"})

      assert %{
               state: "waiting",
               tool: "agenttest.write_item",
               preview: %{"rows" => [_]},
               arguments: arguments,
               expires_at: %DateTime{},
               repeatable?: false
             } = card_state(ctx, card)

      assert arguments =~ "<b>**bold**</b>"
      assert Confirm.get_for_user(card.confirmation_uuid, ctx.ref) |> elem(0) == :ok
    end

    test "a message of another chat of the user is no card here", ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      assert {:ok, %{} = none} = Confirmations.cards(ctx.ref, false, other.uuid, [card])
      assert none == %{}
    end
  end
end
