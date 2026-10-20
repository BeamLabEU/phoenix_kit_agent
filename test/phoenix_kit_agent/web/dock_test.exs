defmodule PhoenixKitAgent.Web.DockTest do
  @moduledoc """
  The chat panel (spec §10, §8, §8.2, §12 Б1.7): the header widget, the list
  of chats and the panel, a sticky LiveView that finds its session itself in
  its connected mount and does everything through `Conversations`, `Turns`,
  `Attachments` and `UserConfig` with the session's fresh scope.

  The model is a `Req.Test` stub behind `phoenix_kit_ai`; the panel is mounted
  with `live_isolated/3` over a conn whose cookie session holds the user's
  token, which LiveView merges into the panel's session as it does in a host.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.HeaderWidget
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitAgent.{Config, Conversations, UserConfig}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Test.{Files, LogProbe, Tools}
  alias PhoenixKitAgent.Web.Dock

  @stub __MODULE__
  @model "deepseek/deepseek-v4.1-flash"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    :ok = ModuleRegistry.register(Tools)
    # Uploaded files go to a bucket in a temporary directory.
    _bucket = Files.local_bucket!()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      stop_all_turns()
      ModuleRegistry.unregister(Tools)
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Application.delete_env(:phoenix_kit_agent, :turn_handshake_ms)
    end)

    endpoint = endpoint_fixture(%{model: @model})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentDock#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("dock")
    {:ok, _} = Roles.assign_role(user, role.name)
    {ref, token} = session_fixture(user)

    %{conn: conn, user: user, ref: ref, token: token}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp dock(ctx, opts \\ []) do
    cookie = Keyword.get(opts, :cookie, %{"user_token" => ctx.token})
    user_uuid = Keyword.get(opts, :user_uuid, ctx.user.uuid)

    {:ok, view, _html} =
      ctx.conn
      |> Plug.Test.init_test_session(cookie)
      |> live_isolated(Dock, session: %{"user_uuid" => user_uuid, "locale" => "en"})

    view
  end

  defp open_chat(view, chat) do
    view |> element("#pk-agent-chat-#{chat.uuid} [data-role=open]") |> render_click()
  end

  defp send_text(view, text) do
    # The page is set by the `.Composer` hook in a browser, as the form goes.
    view
    |> form("#pk-agent-composer", message: %{text: text})
    |> render_submit(%{message: %{page: "/en/admin/orders/7"}})
  end

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

  defp answer_next(answer) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(raw)})
      Req.Test.json(conn, answer)
    end)
  end

  defp hang_next do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, {:model_waiting, self()})

      receive do
        :never -> conn
      end
    end)
  end

  # Polls the view until `fun.(html)` holds (at most `timeout` ms).
  defp eventually(view, fun, timeout \\ 3_000) do
    html = render(view)

    cond do
      fun.(html) ->
        html

      timeout <= 0 ->
        flunk("the panel never got there:\n" <> html)

      true ->
        receive do
        after
          20 -> eventually(view, fun, timeout - 20)
        end
    end
  end

  defp messages(chat) do
    Repo.all(
      from(m in Message,
        where: m.conversation_uuid == ^chat.uuid,
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  defp chats_of(user) do
    Repo.all(from(c in Conversation, where: c.user_uuid == ^user.uuid))
  end

  defp lock_of(chat) do
    c = Repo.get!(Conversation, chat.uuid)
    {c.busy_since, c.busy_turn_ref}
  end

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

  defp chat_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pk-agent-chats li[id^=pk-agent-chat-]")
    |> Enum.map(fn node -> node |> LazyHTML.attribute("id") |> hd() end)
  end

  defp at(seconds_ago), do: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

  # ── the header widget ───────────────────────────────────────────────

  describe "the header widget" do
    test "the module declares the panel as a docked header widget" do
      assert [{Dock, "pk-agent-dock-widget", fun, [dock: true]} = entry] =
               PhoenixKitAgent.header_widgets()

      assert is_function(fun, 1)
      assert {:ok, %HeaderWidget{dock: true}} = HeaderWidget.new(entry)
    end

    test "its session is the user's uuid and locale, nothing else", ctx do
      assigns = %{
        phoenix_kit_current_scope: scope_of(ctx.user),
        phoenix_kit_current_user: ctx.user,
        current_locale_base: "et",
        impersonating?: false
      }

      assert PhoenixKitAgent.header_widget_session(assigns) ==
               %{"user_uuid" => ctx.user.uuid, "locale" => "et"}
    end

    test "there is no widget without the agent right, with the module off or when impersonating",
         ctx do
      outsider = user_with(["dashboard"], "outsider")

      base = %{
        phoenix_kit_current_scope: scope_of(ctx.user),
        phoenix_kit_current_user: ctx.user,
        current_locale_base: "en",
        impersonating?: false
      }

      assert PhoenixKitAgent.header_widget_session(%{
               base
               | phoenix_kit_current_scope: scope_of(outsider),
                 phoenix_kit_current_user: outsider
             }) == nil

      assert PhoenixKitAgent.header_widget_session(%{base | impersonating?: true}) == nil

      assert PhoenixKitAgent.header_widget_session(%{base | phoenix_kit_current_scope: nil}) ==
               nil

      {:ok, _} = PhoenixKitAgent.disable_system()
      assert PhoenixKitAgent.header_widget_session(base) == nil
    end
  end

  # ── what is rendered before the panel knows the session ─────────────

  describe "the static render" do
    test "carries no data of the user and no chats; the connected panel does", ctx do
      conversation_fixture(ctx.user, %{title: "Static secret chat"})

      conn =
        ctx.conn
        |> Plug.Test.init_test_session(%{
          "user_token" => ctx.token,
          "test_user_uuid" => ctx.user.uuid
        })

      static = conn |> get("/en/admin/dock-host") |> html_response(200)

      assert static =~ "dock-host-page"
      refute static =~ "Static secret chat"
      refute static =~ "pk-agent-dock-button"
      refute static =~ ctx.user.uuid

      {:ok, host, _html} = live(conn, "/en/admin/dock-host")
      panel = find_live_child(host, "pk-agent-dock-widget")
      assert has_element?(panel, "#pk-agent-dock-button")
      assert has_element?(panel, "#pk-agent-chats", "Static secret chat")
    end
  end

  # ── who gets no panel ───────────────────────────────────────────────

  describe "an impersonated session" do
    setup ctx do
      operator = user_with(["agent"], "operator")
      root = Auth.generate_user_session_token(operator)
      cookie = %{"user_token" => ctx.token, "pk_session_accounts" => [root, ctx.token]}
      chat = conversation_fixture(ctx.user, %{title: "Borrowed chat"})
      %{cookie: cookie, chat: chat}
    end

    test "renders nothing and refuses every event", ctx do
      view = dock(ctx, cookie: ctx.cookie)

      html = render(view)
      refute html =~ "pk-agent-dock-button"
      refute html =~ "Borrowed chat"

      render_click(view, "new_chat", %{})
      render_click(view, "open_chat", %{"uuid" => ctx.chat.uuid})
      render_click(view, "rename_chat", %{"uuid" => ctx.chat.uuid, "title" => "Hijacked"})
      render_click(view, "archive_chat", %{"uuid" => ctx.chat.uuid})
      render_click(view, "restore", %{"open" => true, "conversation_uuid" => ctx.chat.uuid})
      render_submit(view, "send", %{"message" => %{"text" => "Read it all"}})

      refute render(view) =~ "Borrowed chat"
      assert [%Conversation{title: "Borrowed chat", status: "active"}] = chats_of(ctx.user)
      assert messages(ctx.chat) == []
    end
  end

  describe "a session without the right" do
    test "renders nothing and refuses events, even with a forged widget session", ctx do
      outsider = user_with(["dashboard"], "no-agent")
      {_ref, token} = session_fixture(outsider)

      view = dock(ctx, cookie: %{"user_token" => token}, user_uuid: outsider.uuid)

      refute render(view) =~ "pk-agent-dock-button"
      render_click(view, "new_chat", %{})
      assert chats_of(outsider) == []
    end

    test "a widget session made for another user than the cookie's is refused", ctx do
      other = user_with(["agent"], "other")
      conversation_fixture(ctx.user, %{title: "Mine"})

      view = dock(ctx, user_uuid: other.uuid)

      refute render(view) =~ "pk-agent-dock-button"
      refute render(view) =~ "Mine"
    end

    test "nothing without a session at all", ctx do
      view = dock(ctx, cookie: %{})
      refute render(view) =~ "pk-agent-dock-button"
    end
  end

  # ── the list of chats ───────────────────────────────────────────────

  describe "the list of chats" do
    test "newest first, 20 at a time, then more", ctx do
      chats =
        for n <- 1..23 do
          conversation_fixture(ctx.user, %{title: "Chat #{n}"})
          |> Ecto.Changeset.change(last_message_at: at(1_000 - n))
          |> Repo.update!()
        end

      newest_first = chats |> Enum.reverse() |> Enum.map(&"pk-agent-chat-#{&1.uuid}")

      view = dock(ctx)
      assert chat_ids(render(view)) == Enum.take(newest_first, 20)
      assert has_element?(view, "#pk-agent-new-chat")

      html = view |> element("#pk-agent-more-chats") |> render_click()
      assert chat_ids(html) == newest_first
      refute has_element?(view, "#pk-agent-more-chats")
    end

    test "a new chat goes to the top and is opened", ctx do
      conversation_fixture(ctx.user, %{title: "Old one"})
      view = dock(ctx)

      view |> element("#pk-agent-new-chat") |> render_click()

      assert [new] = Enum.filter(chats_of(ctx.user), &is_nil(&1.title))
      assert hd(chat_ids(render(view))) == "pk-agent-chat-#{new.uuid}"
      assert has_element?(view, "#pk-agent-panel[data-conversation='#{new.uuid}']")
    end

    test "renames and archives the user's own chat", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Before"})
      view = dock(ctx)

      view |> element("#pk-agent-rename-#{chat.uuid}") |> render_click()

      view
      |> form("#pk-agent-rename-form-#{chat.uuid}", %{"title" => "After"})
      |> render_submit()

      assert Repo.get!(Conversation, chat.uuid).title == "After"
      assert has_element?(view, "#pk-agent-chat-#{chat.uuid}", "After")

      view |> element("#pk-agent-archive-#{chat.uuid}") |> render_click()
      assert Repo.get!(Conversation, chat.uuid).status == "archived"
      refute has_element?(view, "#pk-agent-chat-#{chat.uuid}")
    end

    test "someone else's chat cannot be opened, renamed or archived", ctx do
      other = user_with(["agent"], "stranger")
      theirs = conversation_fixture(other, %{title: "Their chat"})
      {other_ref, _} = session_fixture(other)

      view = dock(ctx)

      render_click(view, "open_chat", %{"uuid" => theirs.uuid})
      assert has_element?(view, "#pk-agent-dock-error")
      refute has_element?(view, "#pk-agent-panel[data-conversation='#{theirs.uuid}']")

      render_click(view, "rename_chat", %{"uuid" => theirs.uuid, "title" => "Mine now"})
      render_click(view, "archive_chat", %{"uuid" => theirs.uuid})

      assert %Conversation{title: "Their chat", status: "active"} =
               Repo.get!(Conversation, theirs.uuid)

      # Not subscribed: their new message does not reach this panel.
      {:ok, _} =
        Conversations.add_message(other_ref, theirs.uuid, %{content: "Private words"},
          impersonated: false
        )

      refute render(view) =~ "Private words"
    end
  end

  # ── a turn in the panel ─────────────────────────────────────────────

  describe "sending" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Work"})}
    end

    test "starts a turn and the feed follows it over PubSub", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      answer_next(
        text_answer(
          "Here **it is**. ![chart](http://evil.example/leak?d=1) See [docs](https://docs.example.org/x)."
        )
      )

      send_text(view, "What is new?")

      html = eventually(view, &(&1 =~ "it is"))

      assert_received {:model_request, body}
      system = body["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ "/en/admin/orders/7"

      assert has_element?(view, "#pk-agent-feed [data-role=user]", "What is new?")
      assert has_element?(view, "#pk-agent-feed [data-role=assistant] strong", "it is")

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("#pk-agent-feed img") |> Enum.count() == 0
      refute html =~ "evil.example"

      [link] = doc |> LazyHTML.query("#pk-agent-feed a[href^='https://docs']") |> Enum.to_list()
      assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer nofollow"]
      assert has_element?(view, "#pk-agent-feed [data-link-domain]", "docs.example.org")

      eventually(view, &(not (&1 =~ "pk-agent-waiting")))
      assert [%Message{role: "user"}, %Message{role: "assistant"}] = messages(ctx.chat)
    end

    test "a message without an open chat makes one", ctx do
      view = dock(ctx)
      answer_next(text_answer("Hi"))

      send_text(view, "Start somewhere")
      eventually(view, &(&1 =~ "Start somewhere"))

      assert Enum.any?(chats_of(ctx.user), &(&1.title == "Start somewhere"))
    end

    test "a blank message is refused before anything is made", ctx do
      view = dock(ctx)
      before = length(chats_of(ctx.user))

      send_text(view, "   ")

      assert has_element?(view, "#pk-agent-dock-error")
      assert length(chats_of(ctx.user)) == before
    end

    test "a tool call shows as a folded card with its summary, never the result", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      answer_next(
        tool_answer([
          %{
            "id" => "c1",
            "type" => "function",
            "function" => %{"name" => "agenttest_list_items", "arguments" => "{}"}
          }
        ])
      )

      answer_next(text_answer("Three things."))

      send_text(view, "List them")
      html = eventually(view, &(&1 =~ "Three things."))

      assert has_element?(view, "#pk-agent-feed [data-role=tool]", "agenttest.list_items")
      assert has_element?(view, "#pk-agent-feed [data-role=tool]", "3")

      feed =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#pk-agent-feed") |> LazyHTML.to_html()

      for item <- ["chair", "table", "lamp"], do: refute(feed =~ item)
    end

    test "a refused start says why in words", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "someone-else"]
      )

      send_text(view, "Now?")
      assert has_element?(view, "#pk-agent-dock-error")
      refute render(view) =~ "conversation_busy"
    end

    test "an exception at the start does not take the panel down", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      # The monitor's handshake time is read as the turn starts.
      Application.put_env(:phoenix_kit_agent, :turn_handshake_ms, :not_a_number)

      send_text(view, "Break it")

      assert Process.alive?(view.pid)
      assert has_element?(view, "#pk-agent-dock-error")
      assert lock_of(ctx.chat) == {nil, nil}
      refute render(view) =~ "ArithmeticError"
    end

    test "Stop ends the turn and the indicator goes away", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)
      hang_next()

      send_text(view, "Take your time")
      assert_receive {:model_waiting, _}, 3_000
      assert has_element?(view, "#pk-agent-waiting")

      view |> element("#pk-agent-stop") |> render_click()

      eventually(view, &(not (&1 =~ "pk-agent-waiting")), 5_000)
      assert lock_of(ctx.chat) == {nil, nil}
      refute Enum.any?(messages(ctx.chat), &(&1.role == "assistant"))
    end

    test "nothing of the conversation reaches the log", ctx do
      secret = "Secret-#{System.unique_integer([:positive])}"
      answer_next(text_answer("Answer-" <> secret))

      {_, logs} =
        LogProbe.capture(fn ->
          view = dock(ctx)
          open_chat(view, ctx.chat)

          name = "File-#{secret}.txt"

          view
          |> file_input("#pk-agent-composer", :files, [
            %{name: name, content: "Body-" <> secret, type: "text/plain"}
          ])
          |> render_upload(name)

          eventually(view, &(&1 =~ ~s(data-status="ready")))
          send_text(view, "Ask-" <> secret)
          eventually(view, &(&1 =~ "Answer-" <> secret))
        end)

      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end
  end

  # ── a turn lost with its node ──────────────────────────────────────

  describe "opening a chat locked by a lost turn" do
    test "writes the notice that the answer was interrupted and frees the chat", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Lost"})
      lost = UUIDv7.generate()
      since = at(Config.turn_deadline_s() + 120)

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: since, busy_turn_ref: lost]
      )

      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        busy_since: since,
        busy_turn_ref: lost
      })

      view = dock(ctx)
      open_chat(view, chat)

      assert has_element?(view, "#pk-agent-feed [data-role=notice]", "interrupted")
      assert lock_of(chat) == {nil, nil}
      assert [%Message{role: "notice", error: "interrupted"}] = messages(chat)
    end

    test "a turn still within its time is shown as running, nothing written", ctx do
      chat = conversation_fixture(ctx.user, %{title: "Busy"})

      Repo.update_all(from(c in Conversation, where: c.uuid == ^chat.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: UUIDv7.generate()]
      )

      view = dock(ctx)
      open_chat(view, chat)

      assert has_element?(view, "#pk-agent-waiting")
      assert messages(chat) == []
    end
  end

  # ── attachments ────────────────────────────────────────────────────

  describe "attachments" do
    setup ctx do
      %{chat: conversation_fixture(ctx.user, %{title: "Files"})}
    end

    defp upload(view, name, content, type) do
      input =
        file_input(view, "#pk-agent-composer", :files, [
          %{name: name, content: content, type: type}
        ])

      render_upload(input, name)
    end

    defp attachments_of(chat) do
      Repo.all(from(a in Attachment, where: a.conversation_uuid == ^chat.uuid))
    end

    test "a file is added to the open chat, read, and goes with the message", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      upload(view, "notes.txt", "Shelf height 2.1 m", "text/plain")

      eventually(view, &(&1 =~ ~s(data-status="ready")))

      assert [%Attachment{filename: "notes.txt", status: "ready"} = att] =
               attachments_of(ctx.chat)

      assert has_element?(view, "#pk-agent-att-#{att.uuid}", "notes.txt")

      answer_next(text_answer("Noted."))
      send_text(view, "Read the file")
      eventually(view, &(&1 =~ "Noted."))

      assert_received {:model_request, body}
      assert Jason.encode!(body) =~ "Shelf height 2.1 m"
      assert Repo.get!(Attachment, att.uuid).message_uuid
    end

    test "a refused file is explained in words and keeps no row", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      upload(view, "table.csv", <<0xFF, 0xFE, ?a, 0, ?b, 0>>, "text/csv")

      html = eventually(view, &(&1 =~ "pk-agent-dock-error"))
      assert html =~ "UTF-8"
      refute html =~ "unsupported_encoding"
      assert attachments_of(ctx.chat) == []
    end

    test "a failed file is shown with its reason and can be discarded", ctx do
      view = dock(ctx)
      open_chat(view, ctx.chat)

      failed =
        Repo.insert!(%Attachment{
          conversation_uuid: ctx.chat.uuid,
          user_uuid: ctx.user.uuid,
          filename: "broken.pdf",
          content_type: "application/pdf",
          size_bytes: 10,
          kind: "pdf",
          status: "failed",
          error: "pdf_tools_missing",
          truncated: false
        })

      # Reopen: the waiting files are read when a chat is opened.
      open_chat(view, ctx.chat)

      assert has_element?(view, "#pk-agent-att-#{failed.uuid}[data-status=failed]")
      refute render(view) =~ "pdf_tools_missing"

      view |> element("#pk-agent-discard-#{failed.uuid}") |> render_click()
      refute has_element?(view, "#pk-agent-att-#{failed.uuid}")
      assert attachments_of(ctx.chat) == []
    end
  end

  # ── the user's own instructions ────────────────────────────────────

  describe "personal instructions" do
    test "are read and written for the session's user", ctx do
      view = dock(ctx)
      view |> element("#pk-agent-instructions-toggle") |> render_click()

      view
      |> form("#pk-agent-instructions-form",
        instructions: %{personal_instructions: "Answer in Estonian."}
      )
      |> render_submit()

      assert {:ok, "Answer in Estonian."} =
               UserConfig.get_personal_instructions(ctx.ref, impersonated: false)

      too_long = String.duplicate("x", 5_000)

      view
      |> form("#pk-agent-instructions-form", instructions: %{personal_instructions: too_long})
      |> render_submit()

      assert has_element?(view, "#pk-agent-instructions-form .text-error")

      assert {:ok, "Answer in Estonian."} =
               UserConfig.get_personal_instructions(ctx.ref, impersonated: false)
    end
  end
end
