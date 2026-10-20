defmodule PhoenixKitAgent.Turns do
  @moduledoc """
  A turn of the assistant (spec §6.1): the user's message, then rounds of
  model calls and read-only tool calls until the model answers.

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session** — the `{session_token_uuid, user_uuid}` reference of
  `PhoenixKit.Users.Auth.SessionRef.from_session/1` — and takes the answer of
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` for it, a boolean (anything
  else raises `ArgumentError`). An impersonated session is refused before
  anything is read or written.

  `start/6`, in order (the first failure is the answer; a start that fails
  writes nothing to the chat and leaves no lock behind):

    0-1. the checks of `Conversations` — impersonation, the session's scope,
         the `agent` permission, the module and the user's switch, the chat is
         the user's;
       - a non-blank message of at most `agent_history_chars` characters, the
         AI module on, an endpoint chosen (the user's own, else
         `agent_default_endpoint_uuid`; `PhoenixKitAgent.UserConfig`), the
         attachments ready and the user's own, of this chat and not sent yet;
    2. the limits (spec §7.3, a later block — every turn may start for now);
    3. the locks (`PhoenixKitAgent.Turns.Locks`): one turn per chat
       (`:conversation_busy`) and per user (`:turn_in_flight`); the history
       is read only once they are taken, so it holds the previous turn's end;
    4. the task starts (`PhoenixKitAgent.Turns.Monitor`), and `{:ok,
       turn_ref}` is returned; there the user message is stored (and the
       attachments linked to it), then the rounds run
       (`PhoenixKitAgent.Turns.Runner`).

  The chat's topic (`Conversations.topic/1`) hears every stored message
  (`{:agent_message_added, conversation_uuid, message_uuid}`) and the end of
  the turn (`{:agent_turn_finished, conversation_uuid, turn_ref}`), after its
  locks are released. A listener matches the `turn_ref` it got from
  `start/6`: a start that failed half-way is announced as finished too.

  A refusal never carries turn data: an unavailable monitor or a task that
  did not start is `{:monitor_unavailable, class}` / `{:not_started, class}`
  with only the class of the exit (`t:PhoenixKitAgent.Turns.Monitor.exit_class/0`).
  NUL characters are cut from the text before anything else.

  The assistant acts with the session's rights only: tools are listed and run
  by `PhoenixKit.API.Executor.visible_for/3` / `execute_as/5` with `allow:
  :read`, for this session; there is no service user and no API key.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Config, Conversations, Prompt, UserConfig}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message}
  alias PhoenixKitAgent.Turns.{History, Locks, Monitor}

  @registry PhoenixKitAgent.Turns.Registry

  # A lock outlives the deadline of its turn by this much before another turn
  # may take it over (spec §6.1 step 3).
  @lock_grace_s 60

  @typedoc "Why a turn was not started, or not stopped."
  @type refusal ::
          Conversations.refusal()
          | :empty_message
          | :message_too_long
          | :ai_disabled
          | :no_endpoint
          | :invalid_attachments
          | :conversation_busy
          | :turn_in_flight
          | :not_running
          | {:not_started, Monitor.exit_class()}
          | {:monitor_unavailable, Monitor.exit_class()}

  @doc """
  Starts a turn in the user's chat with `text` and the attachments
  `attachment_uuids` (see the moduledoc). Returns `{:ok, turn_ref}` as soon as
  the turn runs; its first act is to store the user message (the chat's topic
  hears it).

  Options:

    * `:request_context` — what the tools' handlers get as context
      (`PhoenixKit.API.Executor.execute_as/5`): `:language`, `:base_url`,
      `:hosts`, `:currency`, `:ip`; `:request_id` defaults to the turn ref;
    * `:deadline_ms` — a shorter deadline than `agent_turn_deadline_s`; it can
      only shorten it;
    * `:page` — where the user is, for the model's context: a path, or
      `%{path:, order_number:}` (the order number only if the host knows it);
    * `:locale` — the user's locale; else the `:language` of the request
      context, else the process's Gettext locale. Both come from a browser and
      are checked by `PhoenixKitAgent.Prompt`.
  """
  @spec start(Conversations.session_ref(), boolean(), term(), term(), [term()], keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def start(
        session_ref,
        impersonated?,
        conversation_uuid,
        text,
        attachment_uuids \\ [],
        opts \\ []
      )
      when is_list(attachment_uuids) and is_list(opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ),
         {:ok, text} <- message_text(text),
         {:ok, scope} <- Conversations.authorized_scope(session_ref, impersonated: impersonated?),
         :ok <- ai_enabled(),
         settings = UserConfig.effective(conversation.user_uuid),
         {:ok, endpoint_uuid} <- endpoint(settings),
         :ok <- within_limits(conversation.user_uuid),
         {:ok, attachments} <- new_attachments(conversation, attachment_uuids) do
      user = %{scope: scope, settings: settings, endpoint_uuid: endpoint_uuid}
      launch(session_ref, conversation, text, attachments, user, opts)
    end
  end

  @doc """
  Stops the turn running in the user's chat: its task ends at once, the
  answer it was waiting for is not kept, and its locks are released (the
  chat's topic hears `:agent_turn_finished`). With `turn_ref`, only that turn
  is stopped — a newer one in the chat keeps running. `{:error, :not_running}`
  when no such turn runs there; someone else's chat is `{:error, :not_found}`.
  """
  @spec stop(Conversations.session_ref(), boolean(), term(), String.t() | nil) ::
          :ok | {:error, refusal()}
  def stop(session_ref, impersonated?, conversation_uuid, turn_ref \\ nil) do
    with {:ok, user_uuid} <-
           Conversations.authorize_session(session_ref, impersonated: impersonated?),
         {:ok, conversation_uuid, running} <- running_turn(user_uuid, conversation_uuid),
         :ok <- same_turn(running, turn_ref) do
      case Registry.lookup(@registry, running) do
        [{pid, ^conversation_uuid}] ->
          Process.exit(pid, {:shutdown, :stopped})
          :ok

        _not_here ->
          {:error, :not_running}
      end
    end
  end

  # ── start ───────────────────────────────────────────────────────

  # The current message always goes to the model whole (spec §6.6), so it may
  # not be longer than the whole history window.
  defp message_text(text) when is_binary(text) do
    text = Message.strip_nul(text)

    cond do
      String.trim(text) == "" -> {:error, :empty_message}
      String.length(text) > Config.history_chars() -> {:error, :message_too_long}
      true -> {:ok, text}
    end
  end

  defp message_text(_not_text), do: {:error, :empty_message}

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  # The user's own model, else the module's (spec §7.2), as of this start: a
  # change takes effect with the next turn of any chat.
  defp endpoint(%{endpoint_uuid: nil}), do: {:error, :no_endpoint}
  defp endpoint(%{endpoint_uuid: uuid}), do: {:ok, uuid}

  # The spending and turn limits (spec §7.3) are a later block; until then
  # every turn may start.
  defp within_limits(_user_uuid), do: :ok

  # Every uuid must name a ready attachment of this user in this chat that is
  # not part of a message yet.
  defp new_attachments(_conversation, []), do: {:ok, []}

  defp new_attachments(conversation, uuids) do
    with {:ok, uuids} <- cast_uuids(uuids) do
      found =
        repo().all(
          from(a in Attachment,
            where:
              a.uuid in ^uuids and a.user_uuid == ^conversation.user_uuid and
                a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid) and
                a.status == "ready",
            order_by: [asc: a.inserted_at, asc: a.uuid]
          )
        )

      if length(found) == length(uuids), do: {:ok, found}, else: {:error, :invalid_attachments}
    end
  end

  defp cast_uuids(uuids) do
    uuids
    |> Enum.reduce_while([], fn uuid, acc ->
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} -> {:cont, [uuid | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_attachments}
      cast -> {:ok, cast |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp launch(session_ref, conversation, text, attachments, user, opts) do
    user_uuid = conversation.user_uuid
    turn_ref = UUIDv7.generate()

    with :ok <- Locks.acquire(user_uuid, conversation.uuid, turn_ref, lock_ttl_s()) do
      case begin(session_ref, conversation, text, attachments, user, turn_ref, opts) do
        {:ok, _pid} ->
          {:ok, turn_ref}

        {:error, _reason} = error ->
          Locks.release(user_uuid, conversation.uuid, turn_ref)
          error
      end
    end
  end

  # Everything here runs with the locks held: an exception frees them before
  # it goes on (the task has not started, or never got its go-ahead).
  defp begin(session_ref, conversation, text, attachments, user, turn_ref, opts) do
    user_uuid = conversation.user_uuid

    request_context =
      opts |> Keyword.get(:request_context, []) |> Keyword.put_new(:request_id, turn_ref)

    turn = %{
      turn_ref: turn_ref,
      session_ref: session_ref,
      user_uuid: user_uuid,
      conversation_uuid: conversation.uuid,
      endpoint_uuid: user.endpoint_uuid,
      text: text,
      attachment_uuids: Enum.map(attachments, & &1.uuid),
      system_prompt: system_prompt(user, request_context, opts),
      history: history(conversation, text, attachments),
      request_context: request_context,
      max_rounds: Config.max_tool_rounds(),
      result_chars: Config.tool_result_chars(),
      capture?: Config.capture_ai_content?()
    }

    Monitor.start_turn(turn, deadline_ms(opts), [self() | Process.get(:"$callers", [])])
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      release_quietly(conversation.user_uuid, conversation.uuid, turn_ref)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp release_quietly(user_uuid, conversation_uuid, turn_ref) do
    Locks.release(user_uuid, conversation_uuid, turn_ref)
  rescue
    _db_error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # §7.1: see `PhoenixKitAgent.Prompt`. The locale is the one the host passed,
  # else the language of the request context, else the process's.
  defp system_prompt(user, request_context, opts) do
    Prompt.build(%{
      user_uuid: user.settings.user_uuid,
      scope: user.scope,
      settings: user.settings,
      locale:
        Keyword.get(opts, :locale) || request_context[:language] ||
          Gettext.get_locale(PhoenixKitWeb.Gettext),
      page: Keyword.get(opts, :page)
    })
  end

  defp history(conversation, text, attachments) do
    messages =
      repo().all(
        from(m in Message,
          where: m.conversation_uuid == ^conversation.uuid and m.role in ["user", "assistant"],
          order_by: [asc: m.inserted_at, asc: m.uuid],
          select: struct(m, [:uuid, :role, :content, :tool_calls])
        )
      )

    earlier =
      repo().all(
        from(a in Attachment,
          where:
            a.conversation_uuid == ^conversation.uuid and a.status == "ready" and
              not is_nil(a.message_uuid),
          order_by: [asc: a.inserted_at, asc: a.uuid]
        )
      )

    current = %{role: "user", content: History.user_content(text, attachments)}
    History.build(messages, earlier, current, Config.history_chars())
  end

  defp deadline_ms(opts) do
    configured = Config.turn_deadline_s() * 1_000

    case Keyword.get(opts, :deadline_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, configured)
      _ -> configured
    end
  end

  defp lock_ttl_s, do: Config.turn_deadline_s() + @lock_grace_s

  # ── stop ────────────────────────────────────────────────────────

  defp same_turn(_running, nil), do: :ok
  defp same_turn(running, running), do: :ok
  defp same_turn(_running, _other), do: {:error, :not_running}

  defp running_turn(user_uuid, conversation_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(conversation_uuid),
         {:ok, turn_ref} <- busy_turn_ref(user_uuid, uuid) do
      {:ok, uuid, turn_ref}
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp busy_turn_ref(user_uuid, uuid) do
    from(c in Conversation,
      where: c.uuid == ^uuid and c.user_uuid == ^user_uuid and c.status != "deleted",
      select: {c.uuid, c.busy_turn_ref}
    )
    |> repo().one()
    |> case do
      nil -> {:error, :not_found}
      {_uuid, nil} -> {:error, :not_running}
      {_uuid, turn_ref} -> {:ok, turn_ref}
    end
  end

  defp repo, do: RepoHelper.repo()
end
