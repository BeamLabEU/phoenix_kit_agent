defmodule PhoenixKitAgent.Web.DockConfirmTest do
  @moduledoc """
  The confirmation card in the chat panel (spec §12 Ф2, Б2.2): a write the
  model asked for waits in the feed with core's preview and the model's
  arguments as plain text; "Run", "Cancel" and "Ask again" go through
  `PhoenixKitAgent.Confirmations` in a task of the module's supervisor; a card
  still waiting is found again when the panel mounts again; a borrowed session
  gets no panel and no click.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Conversations, Turns}
  alias PhoenixKitAgent.Schemas.Message
  alias PhoenixKitAgent.Test.Tools
  alias PhoenixKitAgent.Turns.Locks
  alias PhoenixKitAgent.Web.Dock

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    {:ok, _} = Settings.update_setting("api_session_write_modules", "agent_test_tools")

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentDockCard#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("dock-card")
    {:ok, _} = Roles.assign_role(user, role.name)
    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user, %{title: "Card chat"})

    %{conn: conn, user: user, ref: ref, token: token, chat: chat}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp dock(ctx, opts \\ []) do
    cookie = Keyword.get(opts, :cookie, %{"user_token" => ctx.token})

    {:ok, view, _html} =
      ctx.conn
      |> Plug.Test.init_test_session(cookie)
      |> live_isolated(Dock, session: %{"user_uuid" => ctx.user.uuid, "locale" => "en"})

    view
  end

  defp open_chat(view, chat),
    do: view |> element("#pk-agent-chat-#{chat.uuid} [data-role=open]") |> render_click()

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

  defp write_call(args) do
    %{
      "id" => "w1",
      "type" => "function",
      "function" => %{"name" => "agenttest_write_item", "arguments" => Jason.encode!(args)}
    }
  end

  defp answer_next(answer) do
    Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, answer) end)
  end

  # A turn of the user's own session whose model asks for one write; the card
  # it leaves.
  defp card!(ctx, args \\ %{"name" => "new"}) do
    answer_next(tool_answer([write_call(args)]))
    :ok = Conversations.subscribe(ctx.ref, ctx.chat.uuid, impersonated: false)
    assert {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Rename it", [], [])
    uuid = ctx.chat.uuid
    assert_receive {:agent_turn_finished, ^uuid, ^turn_ref}, 5_000
    [card] = cards(ctx.chat)
    card
  end

  defp cards(chat) do
    Repo.all(
      from(m in Message,
        where:
          m.conversation_uuid == ^chat.uuid and m.role == "tool" and
            m.tool_outcome == "needs_confirmation",
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp card_id(card), do: "#pk-agent-msg-#{card.uuid}"
  defp written, do: Settings.get_setting("agenttest_written")
  defp row(card), do: Repo.get!(Confirmation, card.confirmation_uuid)

  # The panel once the click's task is done and its notice has reached it.
  defp settle(view) do
    render_async(view)
    render(view)
  end

  # ── the card ────────────────────────────────────────────────────────

  describe "a waiting card" do
    test "shows core's preview, the arguments as text, Run and Cancel", ctx do
      card = card!(ctx, %{"name" => "<b>**bold**</b> [x](https://evil.example)"})
      view = dock(ctx)
      open_chat(view, ctx.chat)

      id = card_id(card)
      assert has_element?(view, "#{id}[data-state=waiting]")
      assert has_element?(view, "#{id}-preview-rows")
      assert has_element?(view, "#{id}-confirm")
      assert has_element?(view, "#{id}-reject")
      refute has_element?(view, "#{id}-repeat")

      # The arguments are text: no element, no link made of them.
      assert has_element?(view, "#{id}-arguments pre", "<b>**bold**</b>")
      refute has_element?(view, "#{id}-arguments b")
      refute has_element?(view, "#{id} a[href*='evil.example']")
    end

    test "a card that arrives while the panel is open is shown with its buttons", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      card = card!(ctx)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#{card_id(card)}[data-state=waiting]")
      assert has_element?(view, "#{card_id(card)}-confirm")
    end

    test "is found waiting again when the panel mounts again", ctx do
      card = card!(ctx)

      view = dock(ctx)
      render_hook(view, "restore", %{"open" => true, "conversation_uuid" => ctx.chat.uuid})

      assert has_element?(view, "#{card_id(card)}[data-state=waiting]")
      assert has_element?(view, "#{card_id(card)}-confirm")
    end
  end

  describe "the clicks" do
    test "Run writes, and the card says it was done, without buttons", ctx do
      card = card!(ctx)
      view = dock(ctx)
      open_chat(view, ctx.chat)

      view |> element("#{card_id(card)}-confirm") |> render_click()
      settle(view)

      assert written() == "new"
      assert has_element?(view, "#{card_id(card)}[data-state=confirmed]")
      refute has_element?(view, "#{card_id(card)}-confirm")
      assert has_element?(view, "[data-role=notice][data-outcome=confirmed]")
    end

    test "Cancel turns it down: rejected, nothing written", ctx do
      card = card!(ctx)
      view = dock(ctx)
      open_chat(view, ctx.chat)

      view |> element("#{card_id(card)}-reject") |> render_click()
      settle(view)

      assert written() == nil
      assert row(card).status == "rejected"
      assert has_element?(view, "#{card_id(card)}[data-state=rejected]")
      refute has_element?(view, "#{card_id(card)}-confirm")
    end

    test "while a turn runs, Run is refused on the card, which keeps waiting", ctx do
      card = card!(ctx)
      other = conversation_fixture(ctx.user)
      :ok = Locks.acquire(ctx.user.uuid, other.uuid, "a-turn", 600)

      view = dock(ctx)
      open_chat(view, ctx.chat)
      view |> element("#{card_id(card)}-confirm") |> render_click()
      settle(view)

      assert written() == nil
      assert has_element?(view, "#{card_id(card)}[data-state=waiting]")
      assert has_element?(view, "#{card_id(card)}-note", "answering")
      assert has_element?(view, "#{card_id(card)}-confirm")
    end

    test "a card past its time offers Ask again, which makes a new card", ctx do
      card = card!(ctx)
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^card.confirmation_uuid),
        set: [expires_at: past]
      )

      view = dock(ctx)
      open_chat(view, ctx.chat)
      assert has_element?(view, "#{card_id(card)}[data-state=expired]")
      refute has_element?(view, "#{card_id(card)}-confirm")

      view |> element("#{card_id(card)}-repeat") |> render_click()
      settle(view)

      assert [_old, fresh] = cards(ctx.chat)
      assert has_element?(view, "#{card_id(fresh)}[data-state=waiting]")
      refute has_element?(view, "#{card_id(card)}-repeat")
    end

    test "an event for a message that is not a card shown here does nothing", ctx do
      card = card!(ctx)
      view = dock(ctx)

      # The chat is not open: the panel shows no card.
      render_click(view, "confirm_card", %{"uuid" => card.uuid})
      render_async(view)

      assert written() == nil
      assert row(card).status == "unused"
    end
  end

  describe "a borrowed session" do
    test "gets no card and no click", ctx do
      card = card!(ctx)
      operator = user_with(["agent"], "operator")
      root = Auth.generate_user_session_token(operator)
      cookie = %{"user_token" => ctx.token, "pk_session_accounts" => [root, ctx.token]}

      view = dock(ctx, cookie: cookie)
      render_click(view, "restore", %{"open" => true, "conversation_uuid" => ctx.chat.uuid})

      refute has_element?(view, card_id(card))
      refute has_element?(view, "#{card_id(card)}-confirm")

      for event <- ["confirm_card", "reject_card", "repeat_card"] do
        render_click(view, event, %{"uuid" => card.uuid})
      end

      render_async(view)
      assert written() == nil
      assert row(card).status == "unused"
    end
  end
end
