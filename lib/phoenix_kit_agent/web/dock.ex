defmodule PhoenixKitAgent.Web.Dock do
  @moduledoc """
  The assistant in the admin header (spec §10): a button before the
  notifications bell, the list of the user's chats under it, and the chat
  panel on the right. A sticky LiveView, rendered by core's admin layout as
  the module's header widget (`PhoenixKitAgent.header_widgets/0`), so it keeps
  its state across admin navigation.

  ## Whose panel it is

  The widget's session (`PhoenixKitAgent.header_widget_session/1`) holds only
  the user's uuid and locale. Who acts is decided here, in the **connected**
  mount, from the session LiveView hands the panel — the cookie session merged
  in (spec §6.5): the session reference (`SessionRef.from_session/1`) and
  whether the account is borrowed (`MultiSession.impersonated?/1`). The panel
  then works only when the session is not impersonated, belongs to the uuid
  of the widget's session, and may use the assistant
  (`PhoenixKitAgent.Conversations.authorize_session/2`). Otherwise — and in the
  static render, before any of it is known — it renders nothing and every
  event is ignored: no list, no chat, no call (spec §8, В13).

  Every event goes through `PhoenixKitAgent.Conversations`,
  `PhoenixKitAgent.Turns`, `PhoenixKitAgent.Attachments` and
  `PhoenixKitAgent.UserConfig` with the reference and the flag, so each one is
  checked against the session's scope as it is at that moment; a uuid from the
  browser is only ever a chat or a file to look up for that user. A chat's
  topic is subscribed to only through `Conversations.subscribe/3`, after its
  ownership is checked.

  ## The feed

  Opening a chat reads its messages (`Conversations.list_messages/3`, page by
  page) into a stream. A new message is announced on the chat's topic and read
  with `list_messages/3` (`after:` the last one shown) or `get_message/4` — the
  chat is never read again whole. A tool call is shown folded, by its summary
  (`tool_summary`), never with what the tool returned; a model answer through
  `PhoenixKitAgent.Web.Markdown` (no outside pictures, no raw HTML, every link
  with its domain and `rel="noopener noreferrer nofollow"`, spec §8.2).

  A chat that is locked by a turn lost with its node gets the notice "the
  answer was interrupted" when it is opened (`Turns.settle_interrupted/3`).

  ## Sending, stopping, files

  "Send" starts a turn (`Turns.start/6`) with the files that are ready, the
  page the browser is on (a path, for the model's context, spec §7.1 p.5) and
  the user's locale; an exception there is caught, logged as its class only,
  and shown as a notice in the panel. "Stop" asks the turn to stop. The
  indicator says whether the model thinks or a tool is called; in the
  browser it gives up after the deadline of a turn and its grace period.

  Files come through `allow_upload` (the kinds and the size of §9, the number
  of the user's settings) and are handed to `Attachments.add/4` with the path
  of LiveView's own temporary file (`consume_uploaded_entry/3`, kept until
  `add/4` is done, which runs off this process); the row is read again after
  `add/4` (it may be settled already), and a failed one can be removed.

  ## In the browser

  The panel opens with the class `pk-dock-open` on `<body>`
  (`PhoenixKitWeb.Components.AdminDock`), which survives a live redirect. Open
  or closed, the chosen chat and the width are kept in `localStorage` by the
  `.DockState` hook and restored when the panel mounts again (another
  `live_session`, a reload). The hooks are runtime colocated hooks, so the
  host bundles nothing for them.

  ## Nothing in the log

  `log: false`: LiveView would log every event with its parameters — the
  user's text. No text of a message, an answer or a file name is logged here.
  """

  use Phoenix.LiveView, layout: false, log: false
  use Gettext, backend: PhoenixKitAgent.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]
  import PhoenixKitWeb.Components.Core.TimeDisplay, only: [time_ago: 1]
  import PhoenixKitAgent.Web.Dock.Components

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitAgent.{Attachments, Config, Conversations, Turns, UserConfig}
  alias PhoenixKitAgent.Schemas.{Message, UserSettings}
  alias PhoenixKitAgent.Web.Dock.Texts
  alias PhoenixKitWeb.Components.AdminDock
  alias PhoenixKitWeb.Users.MultiSession

  @accept ~w(.png .jpg .jpeg .webp .heic .heif .pdf .xlsx .csv .txt .md)
  @mb 1_048_576
  @messages_page 200
  @page_chars 200
  # What the browser waits beyond a turn's deadline before it says that no
  # answer is coming: the stop grace period and a margin.
  @stop_grace_ms 30_000
  @wait_margin_ms 15_000

  # ── mount ───────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    socket = assign(socket, active?: false)

    if connected?(socket),
      do: {:ok, activate(socket, session)},
      else: {:ok, socket}
  end

  # The panel works only for a session that is its user's own, not borrowed,
  # and may use the assistant now (see the moduledoc).
  defp activate(socket, session) do
    impersonated? = MultiSession.impersonated?(session)

    with false <- impersonated?,
         {:ok, {_token_uuid, user_uuid} = ref} <- SessionRef.from_session(session),
         ^user_uuid <- session["user_uuid"],
         {:ok, ^user_uuid} <- Conversations.authorize_session(ref, impersonated: impersonated?) do
      locale = locale(session["locale"])
      if locale, do: Gettext.put_locale(PhoenixKitAgent.Gettext, locale)
      settings = UserConfig.effective(user_uuid)

      socket
      |> assign(
        active?: true,
        ref: ref,
        impersonated?: impersonated?,
        user_uuid: user_uuid,
        locale: locale,
        request_context: request_context(socket, locale),
        open?: false,
        conversation: nil,
        last_uuid: nil,
        turn_ref: nil,
        activity: nil,
        unsent: [],
        error: nil,
        renaming: nil,
        instructions_form: nil,
        timeout_ms: Config.turn_deadline_s() * 1_000 + stop_grace_ms() + @wait_margin_ms
      )
      |> allow_upload(:files,
        accept: @accept,
        max_entries: max(settings.max_attachments_per_message, 1),
        max_file_size: max(settings.max_attachment_mb * @mb, 1),
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> stream_configure(:messages, dom_id: &"pk-agent-msg-#{&1.uuid}")
      |> stream(:messages, [])
      |> load_chats()
    else
      _not_this_session -> socket
    end
  end

  defp locale(locale) when is_binary(locale) do
    if Regex.match?(~r/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$/, locale), do: locale
  end

  defp locale(_none), do: nil

  # What the tools' handlers get as their context (spec §6.5, ревью В-10).
  defp request_context(socket, locale) do
    [
      language: locale,
      base_url: base_url(socket),
      ip: IpAddress.client_address_from_socket(socket)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp base_url(%{host_uri: %URI{scheme: scheme, host: host, port: port}})
       when is_binary(scheme) and is_binary(host) do
    if is_nil(port) or port == URI.default_port(scheme),
      do: scheme <> "://" <> host,
      else: scheme <> "://" <> host <> ":" <> Integer.to_string(port)
  end

  defp base_url(_socket), do: nil

  defp stop_grace_ms,
    do: Application.get_env(:phoenix_kit_agent, :turn_stop_grace_ms, @stop_grace_ms)

  defp me(socket), do: [impersonated: socket.assigns.impersonated?]

  # ── events ──────────────────────────────────────────────────────────

  @impl true
  def handle_event(_event, _params, %{assigns: %{active?: false}} = socket),
    do: {:noreply, socket}

  # The browser's memory of the panel, when it mounts (`.DockState`).
  def handle_event("restore", params, socket) do
    socket = assign(socket, open?: params["open"] == true)

    case params["conversation_uuid"] do
      uuid when is_binary(uuid) ->
        case open_conversation(socket, uuid) do
          {:ok, socket} -> {:noreply, socket}
          {:error, _reason, socket} -> {:noreply, store(socket)}
        end

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("panel_opened", _params, socket),
    do: {:noreply, socket |> assign(open?: true) |> store()}

  def handle_event("panel_closed", _params, socket),
    do: {:noreply, socket |> assign(open?: false) |> store()}

  def handle_event("refresh_chats", _params, socket), do: {:noreply, load_chats(socket)}

  def handle_event("more_chats", _params, socket) do
    case socket.assigns.next_cursor do
      nil ->
        {:noreply, socket}

      cursor ->
        case Conversations.list_conversations(socket.assigns.ref, me(socket) ++ [cursor: cursor]) do
          {:ok, page} ->
            {:noreply,
             assign(socket,
               chats: socket.assigns.chats ++ page.conversations,
               next_cursor: page.next_cursor
             )}

          {:error, reason} ->
            {:noreply, refused(socket, reason)}
        end
    end
  end

  def handle_event("new_chat", _params, socket) do
    case Conversations.create_conversation(socket.assigns.ref, %{}, me(socket)) do
      {:ok, conversation} ->
        socket = assign(socket, chats: [conversation | socket.assigns.chats], open?: true)

        case open_conversation(socket, conversation.uuid) do
          {:ok, socket} -> {:noreply, socket}
          {:error, reason, socket} -> {:noreply, refused(socket, reason)}
        end

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("open_chat", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case open_conversation(assign(socket, open?: true), uuid) do
      {:ok, socket} -> {:noreply, socket}
      {:error, reason, socket} -> {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("start_rename", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    if Enum.any?(socket.assigns.chats, &(&1.uuid == uuid)),
      do: {:noreply, assign(socket, renaming: uuid)},
      else: {:noreply, socket}
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  def handle_event("rename_chat", %{"uuid" => uuid, "title" => title}, socket)
      when is_binary(uuid) do
    case Conversations.rename_conversation(socket.assigns.ref, uuid, title, me(socket)) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(renaming: nil, error: nil)
         |> replace_chat(conversation)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, error: gettext("A title cannot be empty or longer than 200 characters."))}

      {:error, reason} ->
        {:noreply, socket |> assign(renaming: nil) |> refused(reason)}
    end
  end

  def handle_event("archive_chat", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case Conversations.archive_conversation(socket.assigns.ref, uuid, me(socket)) do
      {:ok, conversation} ->
        socket =
          assign(socket,
            chats: Enum.reject(socket.assigns.chats, &(&1.uuid == conversation.uuid))
          )

        if current_uuid(socket) == conversation.uuid,
          do: {:noreply, socket |> close_conversation() |> store()},
          else: {:noreply, socket}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("composer_change", _params, socket), do: {:noreply, socket}

  def handle_event("send", %{"message" => params}, socket) when is_map(params) do
    cond do
      not is_binary(params["text"]) or String.trim(params["text"]) == "" ->
        {:noreply, refused(socket, :empty_message)}

      Enum.any?(socket.assigns.unsent, &(&1.status == "pending")) or uploading?(socket) ->
        {:noreply, refused(socket, :files_pending)}

      true ->
        case ensure_conversation(socket) do
          {:ok, socket} -> {:noreply, start_turn(socket, params["text"], page(params["page"]))}
          {:error, reason, socket} -> {:noreply, refused(socket, reason)}
        end
    end
  end

  def handle_event("stop", _params, socket) do
    with %{uuid: uuid} <- socket.assigns.conversation,
         turn_ref when is_binary(turn_ref) <- socket.assigns.turn_ref do
      case Turns.stop(socket.assigns.ref, socket.assigns.impersonated?, uuid, turn_ref) do
        :ok -> {:noreply, assign(socket, activity: :stopping, error: nil)}
        {:error, :not_running} -> {:noreply, assign(socket, turn_ref: nil, activity: nil)}
        {:error, reason} -> {:noreply, refused(socket, reason)}
      end
    else
      _nothing_running -> {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("discard_attachment", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case Attachments.discard(socket.assigns.ref, uuid, me(socket)) do
      :ok ->
        {:noreply, assign(socket, unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid == uuid)))}

      {:error, reason} ->
        {:noreply, socket |> refused(reason) |> reload_unsent()}
    end
  end

  def handle_event("dismiss_error", _params, socket), do: {:noreply, assign(socket, error: nil)}

  def handle_event("toggle_instructions", _params, socket) do
    if socket.assigns.instructions_form do
      {:noreply, assign(socket, instructions_form: nil)}
    else
      case UserConfig.get_personal_instructions(socket.assigns.ref, me(socket)) do
        {:ok, text} -> {:noreply, assign(socket, instructions_form: instructions_form(text))}
        {:error, reason} -> {:noreply, refused(socket, reason)}
      end
    end
  end

  def handle_event(
        "save_instructions",
        %{"instructions" => %{"personal_instructions" => text}},
        socket
      ) do
    case UserConfig.put_personal_instructions(socket.assigns.ref, text, me(socket)) do
      {:ok, stored} ->
        {:noreply, assign(socket, instructions_form: instructions_form(stored), error: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, instructions_form: to_form(changeset, as: :instructions))}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  # A malformed event (forged, or of an older page) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── chats ───────────────────────────────────────────────────────────

  defp load_chats(socket) do
    case Conversations.list_conversations(socket.assigns.ref, me(socket)) do
      {:ok, page} -> assign(socket, chats: page.conversations, next_cursor: page.next_cursor)
      {:error, _reason} -> assign(socket, chats: [], next_cursor: nil)
    end
  end

  defp replace_chat(socket, conversation) do
    chats =
      Enum.map(socket.assigns.chats, fn chat ->
        if chat.uuid == conversation.uuid, do: conversation, else: chat
      end)

    current =
      if current_uuid(socket) == conversation.uuid,
        do: conversation,
        else: socket.assigns.conversation

    assign(socket, chats: chats, conversation: current)
  end

  defp current_uuid(%{assigns: %{conversation: %{uuid: uuid}}}), do: uuid
  defp current_uuid(_socket), do: nil

  # Subscribes to the chat (after the ownership check), settles a turn lost
  # with its node, and reads its messages and its waiting files. The topic of
  # the chat shown before is left only once the new one is read.
  defp open_conversation(socket, uuid) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    previous = current_uuid(socket)

    with {:ok, conversation} <- Conversations.owned_conversation(ref, uuid, me(socket)),
         :ok <- subscribe(socket, conversation.uuid, previous),
         {:ok, state} <- Turns.settle_interrupted(ref, impersonated?, conversation.uuid),
         {:ok, messages} <- all_messages(socket, conversation.uuid, nil, []),
         {:ok, unsent} <- Attachments.list_unsent(ref, conversation.uuid, me(socket)) do
      if previous && previous != conversation.uuid, do: Conversations.unsubscribe(previous)

      {turn_ref, activity} =
        case state do
          {:running, turn_ref} -> {turn_ref, activity_after(messages, :thinking)}
          _idle_or_settled -> {nil, nil}
        end

      {:ok,
       socket
       |> assign(
         conversation: conversation,
         last_uuid: last_uuid(messages, nil),
         turn_ref: turn_ref,
         activity: activity,
         unsent: unsent,
         error: nil
       )
       |> stream(:messages, messages, reset: true)
       |> store()}
    else
      {:error, reason} ->
        if is_binary(uuid) and uuid != previous, do: Conversations.unsubscribe(uuid)
        {:error, reason, socket}
    end
  end

  # The chat shown now is subscribed to already.
  defp subscribe(_socket, uuid, uuid), do: :ok

  defp subscribe(socket, uuid, _other),
    do: Conversations.subscribe(socket.assigns.ref, uuid, me(socket))

  defp close_conversation(socket) do
    if uuid = current_uuid(socket), do: Conversations.unsubscribe(uuid)

    socket
    |> assign(conversation: nil, last_uuid: nil, turn_ref: nil, activity: nil, unsent: [])
    |> stream(:messages, [], reset: true)
  end

  # A message needs a chat: the open one, else a new one.
  defp ensure_conversation(%{assigns: %{conversation: %{}}} = socket), do: {:ok, socket}

  defp ensure_conversation(socket) do
    case Conversations.create_conversation(socket.assigns.ref, %{}, me(socket)) do
      {:ok, conversation} ->
        socket
        |> assign(chats: [conversation | socket.assigns.chats], open?: true)
        |> open_conversation(conversation.uuid)

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp all_messages(socket, uuid, after_uuid, pages) do
    opts = me(socket) ++ [after: after_uuid, limit: @messages_page]

    case Conversations.list_messages(socket.assigns.ref, uuid, opts) do
      {:ok, page} when length(page) == @messages_page ->
        all_messages(socket, uuid, List.last(page).uuid, [page | pages])

      {:ok, page} ->
        {:ok, [page | pages] |> Enum.reverse() |> Enum.concat()}

      {:error, _reason} = error ->
        error
    end
  end

  defp last_uuid([], previous), do: previous
  defp last_uuid(messages, _previous), do: List.last(messages).uuid

  # Keeps the panel and the chosen chat in the browser (`.DockState`).
  defp store(socket) do
    push_event(socket, "pk-agent:store", %{
      open: socket.assigns.open?,
      conversation_uuid: current_uuid(socket)
    })
  end

  # ── turns ───────────────────────────────────────────────────────────

  defp start_turn(socket, text, page) do
    %{ref: ref, impersonated?: impersonated?} = socket.assigns
    ready = for %{status: "ready", uuid: uuid} <- socket.assigns.unsent, do: uuid

    opts = [
      page: page,
      locale: socket.assigns.locale,
      request_context: socket.assigns.request_context
    ]

    case safe_start(ref, impersonated?, current_uuid(socket), text, ready, opts) do
      {:ok, turn_ref} ->
        socket
        |> assign(
          turn_ref: turn_ref,
          activity: :thinking,
          error: nil,
          unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid in ready))
        )
        |> push_event("pk-agent:sent", %{})

      {:error, reason} ->
        socket |> refused(reason) |> reload_unsent()
    end
  end

  # An exception as the turn starts (the history, the prompt, the monitor)
  # must not take the panel down; its terms can hold the user's text, so only
  # its class is logged.
  defp safe_start(ref, impersonated?, uuid, text, attachments, opts) do
    Turns.start(ref, impersonated?, uuid, text, attachments, opts)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] the chat panel could not start a turn: #{inspect(exception.__struct__)}"
      )

      {:error, :start_failed}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] the chat panel could not start a turn: #{kind}")
      {:error, :start_failed}
  end

  # A path of this site, as the browser says it is; `PhoenixKitAgent.Prompt`
  # checks it again.
  defp page(path) when is_binary(path) do
    if String.starts_with?(path, "/") and String.length(path) <= @page_chars and
         not String.contains?(path, ["\n", "\r", "\t"]),
       do: path
  end

  defp page(_none), do: nil

  # What the turn does now, from the last of its messages.
  defp activity_after(messages, default) do
    Enum.reduce(messages, default, fn message, activity -> activity_of(message, activity) end)
  end

  defp activity_of(%Message{role: "assistant", tool_calls: [_ | _] = calls}, _activity),
    do: {:tool, calls |> Enum.map(& &1["name"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()}

  defp activity_of(%Message{role: role}, :stopping) when role in ["user", "tool"], do: :stopping
  defp activity_of(%Message{role: role}, _activity) when role in ["user", "tool"], do: :thinking
  defp activity_of(_message, activity), do: activity

  # ── files ───────────────────────────────────────────────────────────

  # A valid upload is still on its way, or with `Attachments.add/4` (its
  # entry goes when `add/4` is done); one refused by LiveView waits only to be
  # cancelled.
  defp uploading?(socket), do: Enum.any?(socket.assigns.uploads.files.entries, & &1.valid?)

  # A finished upload goes to `Attachments.add/4` off this process; its
  # temporary file is kept (`:postpone`) until `add/4` is done with it.
  defp handle_progress(:files, %{done?: true} = entry, %{assigns: %{active?: true}} = socket) do
    case ensure_conversation(socket) do
      {:ok, socket} ->
        path = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:postpone, path} end)
        %{ref: ref} = socket.assigns
        uuid = current_uuid(socket)
        upload = %{path: path, filename: entry.client_name}
        opts = me(socket)

        {:noreply,
         start_async(socket, {:attach, entry.ref}, fn ->
           Attachments.add(ref, uuid, upload, opts)
         end)}

      {:error, reason, socket} ->
        {:noreply, socket |> cancel_upload(:files, entry.ref) |> refused(reason)}
    end
  end

  defp handle_progress(:files, _entry, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:attach, entry_ref}, result, socket) do
    socket = drop_entry(socket, entry_ref)

    case result do
      {:ok, {:ok, attachment}} ->
        {:noreply, socket |> assign(error: nil) |> refresh_attachment(attachment.uuid)}

      {:ok, {:error, reason}} ->
        {:noreply, refused(socket, reason)}

      {:exit, _reason} ->
        {:noreply, refused(socket, :storage_unavailable)}
    end
  end

  # The upload is done with: its temporary file goes.
  defp drop_entry(socket, entry_ref) do
    case Enum.find(socket.assigns.uploads.files.entries, &(&1.ref == entry_ref)) do
      nil ->
        socket

      entry ->
        consume_uploaded_entry(socket, entry, fn _meta -> {:ok, :done} end)
        socket
    end
  end

  # The row as it is now; a settled row is never replaced by an older pending
  # one (the processing may have ended before `add/4` returned).
  defp refresh_attachment(socket, uuid) do
    case Attachments.get(socket.assigns.ref, uuid, me(socket)) do
      {:ok, %{message_uuid: nil} = attachment} ->
        if attachment.conversation_uuid == current_uuid(socket),
          do: assign(socket, unsent: merge(socket.assigns.unsent, attachment)),
          else: socket

      _sent_or_gone ->
        assign(socket, unsent: Enum.reject(socket.assigns.unsent, &(&1.uuid == uuid)))
    end
  end

  defp merge(unsent, attachment) do
    case Enum.split_with(unsent, &(&1.uuid == attachment.uuid)) do
      {[], rest} ->
        rest ++ [attachment]

      {[known], _rest} ->
        newer =
          if attachment.status == "pending" and known.status != "pending",
            do: known,
            else: attachment

        Enum.map(unsent, &if(&1.uuid == attachment.uuid, do: newer, else: &1))
    end
  end

  defp reload_unsent(socket) do
    with uuid when is_binary(uuid) <- current_uuid(socket),
         {:ok, unsent} <- Attachments.list_unsent(socket.assigns.ref, uuid, me(socket)) do
      assign(socket, unsent: unsent)
    else
      _ -> socket
    end
  end

  # ── events of the chat ──────────────────────────────────────────────

  @impl true
  def handle_info(_message, %{assigns: %{active?: false}} = socket), do: {:noreply, socket}

  def handle_info({:agent_message_added, uuid, message_uuid}, socket) do
    if uuid == current_uuid(socket),
      do: {:noreply, add_messages(socket, uuid, message_uuid)},
      else: {:noreply, socket}
  end

  def handle_info({:agent_turn_finished, uuid, turn_ref}, socket) do
    if uuid == current_uuid(socket) and turn_ref == socket.assigns.turn_ref,
      do: {:noreply, socket |> assign(turn_ref: nil, activity: nil) |> reload_unsent()},
      else: {:noreply, socket}
  end

  def handle_info({:agent_attachment_processed, uuid, attachment_uuid}, socket) do
    if uuid == current_uuid(socket),
      do: {:noreply, refresh_attachment(socket, attachment_uuid)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The messages after the last one shown, and the announced one if it was
  # not among them (committed out of order).
  defp add_messages(socket, uuid, message_uuid) do
    opts = me(socket) ++ [after: socket.assigns.last_uuid, limit: @messages_page]

    case Conversations.list_messages(socket.assigns.ref, uuid, opts) do
      {:ok, messages} ->
        extra =
          if Enum.any?(messages, &(&1.uuid == message_uuid)),
            do: [],
            else: announced(socket, uuid, message_uuid)

        socket
        |> assign(last_uuid: last_uuid(messages, socket.assigns.last_uuid))
        |> insert_messages(messages ++ extra)

      {:error, :invalid_cursor} ->
        insert_messages(socket, announced(socket, uuid, message_uuid))

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp announced(socket, uuid, message_uuid) do
    case Conversations.get_message(socket.assigns.ref, uuid, message_uuid, me(socket)) do
      {:ok, message} -> [message]
      {:error, _reason} -> []
    end
  end

  defp insert_messages(socket, messages) do
    activity =
      if socket.assigns.turn_ref,
        do: activity_after(messages, socket.assigns.activity),
        else: socket.assigns.activity

    messages
    |> Enum.reduce(socket, &stream_insert(&2, :messages, &1))
    |> assign(activity: activity)
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp refused(socket, reason), do: assign(socket, error: Texts.refusal(reason))

  defp instructions_form(text) do
    %UserSettings{}
    |> UserSettings.personal_changeset(%{personal_instructions: text})
    |> to_form(as: :instructions)
  end

  defp chat_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp chat_title(_conversation), do: gettext("New chat")

  defp activity_text(:stopping), do: gettext("Stopping…")

  defp activity_text({:tool, [_ | _] = names}),
    do: gettext("Calling a tool: %{names}…", names: Enum.join(names, ", "))

  defp activity_text({:tool, _none}), do: gettext("Calling a tool…")
  defp activity_text(_thinking), do: gettext("Thinking…")

  defp activity_key({:tool, _names}), do: "tool"
  defp activity_key(activity), do: to_string(activity)

  # ── render ──────────────────────────────────────────────────────────

  @impl true
  def render(%{active?: false} = assigns) do
    ~H"""
    <div class="hidden"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      id="pk-agent-dock"
      phx-hook=".DockState"
      data-storage-key={"pk-agent-dock:" <> @user_uuid}
      class="flex items-center"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DockState" runtime>
        {
          mounted() {
            this.key = this.el.dataset.storageKey
            const state = this.read()
            if (typeof state.width === "number") {
              document.body.style.setProperty("--pk-dock-width", this.clamp(state.width) + "px")
            }
            if (state.open === true) document.body.classList.add("pk-dock-open")
            this.pushEvent("restore", {
              open: state.open === true,
              conversation_uuid: typeof state.conversation_uuid === "string" ? state.conversation_uuid : null
            })
            this.handleEvent("pk-agent:store", (patch) => this.write(patch))
            this.el.addEventListener("pointerdown", (event) => {
              const handle = event.target.closest("[data-pk-agent-resize]")
              if (handle) this.resize(event, handle)
            })
          },
          read() {
            try {
              const value = JSON.parse(window.localStorage.getItem(this.key) || "{}")
              return value && typeof value === "object" ? value : {}
            } catch (_error) {
              return {}
            }
          },
          write(patch) {
            try {
              window.localStorage.setItem(this.key, JSON.stringify(Object.assign(this.read(), patch)))
            } catch (_error) {}
          },
          clamp(width) {
            const most = Math.max(320, Math.min(900, window.innerWidth - 360))
            return Math.round(Math.min(most, Math.max(320, width)))
          },
          resize(event, handle) {
            event.preventDefault()
            handle.setPointerCapture(event.pointerId)
            let width = null
            const move = (e) => {
              width = this.clamp(window.innerWidth - e.clientX)
              document.body.style.setProperty("--pk-dock-width", width + "px")
            }
            const up = () => {
              handle.removeEventListener("pointermove", move)
              handle.removeEventListener("pointerup", up)
              if (width) this.write({width: width})
            }
            handle.addEventListener("pointermove", move)
            handle.addEventListener("pointerup", up)
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Feed" runtime>
        {
          mounted() {
            this.stick = true
            this.el.scrollTop = this.el.scrollHeight
            this.el.addEventListener("scroll", () => {
              this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
            })
            this.observer = new MutationObserver(() => {
              if (this.stick) this.el.scrollTop = this.el.scrollHeight
            })
            this.observer.observe(this.el, {childList: true, subtree: true})
          },
          destroyed() {
            if (this.observer) this.observer.disconnect()
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer" runtime>
        {
          mounted() {
            this.el.addEventListener("keydown", (event) => {
              if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
                event.preventDefault()
                if (this.el.form) this.el.form.requestSubmit()
              }
            })
            if (this.el.form) {
              this.el.form.addEventListener("submit", () => {
                const page = this.el.form.querySelector("[data-pk-agent-page]")
                if (page) page.value = window.location.pathname
              }, true)
            }
            this.handleEvent("pk-agent:sent", () => { this.el.value = "" })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Waiting" runtime>
        {
          mounted() { this.arm() },
          updated() { this.arm() },
          destroyed() { clearTimeout(this.timer) },
          arm() {
            clearTimeout(this.timer)
            this.el.removeAttribute("data-timed-out")
            const ms = parseInt(this.el.dataset.timeoutMs, 10)
            if (ms > 0) this.timer = setTimeout(() => this.el.setAttribute("data-timed-out", "true"), ms)
          }
        }
      </script>

      <%!-- The button and the list of chats --%>
      <div class="dropdown dropdown-end">
        <button
          id="pk-agent-dock-button"
          type="button"
          tabindex="0"
          phx-click="refresh_chats"
          class="btn btn-ghost btn-circle"
          aria-label={gettext("AI assistant")}
          title={gettext("AI assistant")}
        >
          <.icon name="hero-sparkles" class="w-5 h-5" />
        </button>
        <div
          id="pk-agent-chat-list"
          tabindex="0"
          class="dropdown-content z-[100] mt-3 w-80 max-w-[95vw] card bg-base-100 shadow-xl border border-base-200"
        >
          <div class="p-2">
            <button
              id="pk-agent-new-chat"
              type="button"
              phx-click={AdminDock.open() |> JS.push("new_chat")}
              class="btn btn-primary btn-sm w-full"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New chat")}
            </button>
          </div>
          <ul id="pk-agent-chats" class="menu menu-sm w-full max-h-96 overflow-y-auto flex-nowrap p-2 pt-0">
            <li :if={@chats == []} class="px-3 py-2 text-xs opacity-60">{gettext("No chats yet.")}</li>
            <li :for={chat <- @chats} id={"pk-agent-chat-#{chat.uuid}"} class="group">
              <%= if @renaming == chat.uuid do %>
                <form
                  id={"pk-agent-rename-form-#{chat.uuid}"}
                  phx-submit="rename_chat"
                  class="flex items-center gap-1 px-1"
                >
                  <input type="hidden" name="uuid" value={chat.uuid} />
                  <input
                    type="text"
                    name="title"
                    value={chat.title}
                    maxlength="200"
                    class="input input-xs flex-1"
                    aria-label={gettext("Title")}
                    autofocus
                  />
                  <button type="submit" class="btn btn-xs btn-primary">{gettext("Save")}</button>
                  <button type="button" phx-click="cancel_rename" class="btn btn-xs btn-ghost">
                    {gettext("Cancel")}
                  </button>
                </form>
              <% else %>
                <div class={[
                  "flex items-center gap-1 pr-1",
                  @conversation && @conversation.uuid == chat.uuid && "menu-active"
                ]}>
                  <button
                    type="button"
                    data-role="open"
                    phx-click={AdminDock.open() |> JS.push("open_chat", value: %{uuid: chat.uuid})}
                    class="flex-1 min-w-0 text-left"
                  >
                    <span class="block truncate">{chat_title(chat)}</span>
                    <.time_ago id={"pk-agent-chat-time-#{chat.uuid}"} datetime={chat.last_message_at} />
                  </button>
                  <button
                    type="button"
                    id={"pk-agent-rename-#{chat.uuid}"}
                    phx-click="start_rename"
                    phx-value-uuid={chat.uuid}
                    class="btn btn-ghost btn-xs btn-circle opacity-60 hover:opacity-100"
                    aria-label={gettext("Rename")}
                    title={gettext("Rename")}
                  >
                    <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    type="button"
                    id={"pk-agent-archive-#{chat.uuid}"}
                    phx-click="archive_chat"
                    phx-value-uuid={chat.uuid}
                    class="btn btn-ghost btn-xs btn-circle opacity-60 hover:opacity-100"
                    aria-label={gettext("Archive")}
                    title={gettext("Archive")}
                  >
                    <.icon name="hero-archive-box" class="w-3.5 h-3.5" />
                  </button>
                </div>
              <% end %>
            </li>
          </ul>
          <div :if={@next_cursor} class="p-2 pt-0">
            <button id="pk-agent-more-chats" type="button" phx-click="more_chats" class="btn btn-ghost btn-xs w-full">
              {gettext("More")}
            </button>
          </div>
        </div>
      </div>

      <%!-- The panel: over the dock column from lg up, the whole screen below --%>
      <section
        id="pk-agent-panel"
        data-conversation={@conversation && @conversation.uuid}
        aria-label={gettext("AI assistant")}
        class={[
          "hidden [.pk-dock-open_&]:flex flex-col",
          "fixed top-16 bottom-0 right-0 z-40 w-[var(--pk-dock-width,25rem)]",
          "max-lg:left-0 max-lg:w-auto",
          "bg-base-100 border-l border-base-300 max-lg:border-l-0"
        ]}
      >
        <div
          data-pk-agent-resize
          class="hidden lg:block absolute left-0 top-0 bottom-0 w-1.5 -ml-0.5 cursor-col-resize hover:bg-primary/20 transition-colors"
          aria-hidden="true"
        >
        </div>

        <header class="flex items-center gap-2 border-b border-base-300 px-3 py-2">
          <.icon name="hero-sparkles" class="w-4 h-4 shrink-0 text-primary" />
          <h2 class="flex-1 truncate text-sm font-semibold">
            {if @conversation, do: chat_title(@conversation), else: gettext("AI assistant")}
          </h2>
          <button
            id="pk-agent-instructions-toggle"
            type="button"
            phx-click="toggle_instructions"
            class={["btn btn-ghost btn-xs btn-circle", @instructions_form && "btn-active"]}
            aria-label={gettext("Personal instructions")}
            title={gettext("Personal instructions")}
          >
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
          </button>
          <button
            id="pk-agent-close"
            type="button"
            phx-click={AdminDock.close() |> JS.push("panel_closed")}
            class="btn btn-ghost btn-xs btn-circle"
            aria-label={gettext("Close")}
            title={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </header>

        <.form
          :if={@instructions_form}
          for={@instructions_form}
          id="pk-agent-instructions-form"
          phx-submit="save_instructions"
          class="border-b border-base-300 p-3 space-y-2"
        >
          <p class="text-xs opacity-70">
            {gettext(
              "How the assistant should answer you. It follows the site's own rules first."
            )}
          </p>
          <.textarea
            field={@instructions_form[:personal_instructions]}
            rows="4"
            maxlength="4000"
            class="textarea-sm text-sm"
          />
          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary btn-xs">{gettext("Save")}</button>
          </div>
        </.form>

        <div
          :if={@error}
          id="pk-agent-dock-error"
          role="alert"
          class="alert alert-soft alert-error m-3 mb-0 py-2 text-xs"
        >
          <.icon name="hero-exclamation-circle" class="w-4 h-4" />
          <span class="flex-1">{@error}</span>
          <button type="button" phx-click="dismiss_error" class="btn btn-ghost btn-xs btn-circle" aria-label={gettext("Close")}>
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          </button>
        </div>

        <div
          id="pk-agent-feed"
          phx-update="stream"
          phx-hook=".Feed"
          class="flex-1 overflow-y-auto px-3 py-3 space-y-3"
        >
          <div id="pk-agent-feed-empty" class="hidden only:block py-8 text-center text-xs opacity-60">
            {gettext("Ask about anything you can see in the system.")}
          </div>
          <.feed_message :for={{dom_id, message} <- @streams.messages} id={dom_id} message={message} />
        </div>

        <div
          :if={@activity}
          id="pk-agent-waiting"
          phx-hook=".Waiting"
          phx-mounted={JS.ignore_attributes(["data-timed-out"])}
          data-timeout-ms={@timeout_ms}
          data-activity={activity_key(@activity)}
          class="group flex items-center gap-2 px-4 pb-2 text-xs opacity-70"
        >
          <span class="loading loading-dots loading-xs group-data-[timed-out=true]:hidden"></span>
          <span class="group-data-[timed-out=true]:hidden">{activity_text(@activity)}</span>
          <span class="hidden group-data-[timed-out=true]:inline text-warning">
            {gettext("No answer has come. Open the chat again to see where it stands.")}
          </span>
        </div>

        <form
          id="pk-agent-composer"
          phx-submit="send"
          phx-change="composer_change"
          class="border-t border-base-300 p-3 space-y-2"
        >
          <ul :if={@unsent != [] or @uploads.files.entries != []} id="pk-agent-attachments" class="flex flex-wrap gap-1.5">
            <.attachment_chip :for={attachment <- @unsent} attachment={attachment} />
            <li
              :for={entry <- @uploads.files.entries}
              id={"pk-agent-upload-#{entry.ref}"}
              class="flex items-center gap-2 rounded-box border border-base-300 px-2 py-1 text-xs"
            >
              <span class="truncate max-w-[10rem]">{entry.client_name}</span>
              <progress :if={entry.valid?} class="progress progress-primary w-12" value={entry.progress} max="100"></progress>
              <span :for={err <- upload_errors(@uploads.files, entry)} class="text-error">
                {Texts.upload_error(err)}
              </span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs btn-circle"
                aria-label={gettext("Cancel")}
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </button>
            </li>
          </ul>
          <p :for={err <- upload_errors(@uploads.files)} class="text-xs text-error">
            {Texts.upload_error(err)}
          </p>

          <input type="hidden" name="message[page]" value="" data-pk-agent-page />
          <textarea
            id="pk-agent-input"
            name="message[text]"
            phx-hook=".Composer"
            rows="2"
            placeholder={gettext("Write a message…")}
            aria-label={gettext("Message")}
            class="textarea textarea-sm w-full resize-none text-sm"
          ></textarea>
          <div class="flex items-center gap-2">
            <label
              for={@uploads.files.ref}
              class="btn btn-ghost btn-sm btn-circle"
              aria-label={gettext("Attach a file")}
              title={gettext("Attach a file")}
            >
              <.icon name="hero-paper-clip" class="w-4 h-4" />
            </label>
            <.live_file_input upload={@uploads.files} class="hidden" />
            <span class="flex-1"></span>
            <button
              :if={@turn_ref}
              id="pk-agent-stop"
              type="button"
              phx-click="stop"
              class="btn btn-sm btn-outline btn-error"
              disabled={@activity == :stopping}
            >
              <.icon name="hero-stop" class="w-4 h-4" /> {gettext("Stop")}
            </button>
            <button id="pk-agent-send" type="submit" class="btn btn-sm btn-primary" disabled={!!@turn_ref}>
              <.icon name="hero-paper-airplane" class="w-4 h-4" /> {gettext("Send")}
            </button>
          </div>
        </form>
      </section>
    </div>
    """
  end
end
