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

  `start/6`, in order (the first failure is the answer, and nothing is
  written before the locks are taken):

    0-1. the checks of `Conversations` — impersonation, the session's scope,
         the `agent` permission, the module and the user's switch, the chat is
         the user's;
       - a non-blank message, the AI module on, an endpoint chosen
         (`agent_default_endpoint_uuid`), the attachments ready and the
         user's own, of this chat and not sent yet;
    2. the limits (spec §7.3, a later block — every turn may start for now);
    3. the locks (`PhoenixKitAgent.Turns.Locks`): one turn per chat
       (`:conversation_busy`) and per user (`:turn_in_flight`);
    4. the user message is stored (and the attachments linked to it);
    5. the task starts (`PhoenixKitAgent.Turns.Monitor`), and `{:ok,
       turn_ref}` is returned; the rounds run there
       (`PhoenixKitAgent.Turns.Runner`).

  The chat's topic (`Conversations.topic/1`) hears every stored message
  (`{:agent_message_added, conversation_uuid, message_uuid}`) and the end of
  the turn (`{:agent_turn_finished, conversation_uuid, turn_ref}`), after its
  locks are released.

  The assistant acts with the session's rights only: tools are listed and run
  by `PhoenixKit.API.Executor.visible_for/3` / `execute_as/5` with `allow:
  :read`, for this session; there is no service user and no API key.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Config, Conversations}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message, UserSettings}
  alias PhoenixKitAgent.Turns.{History, Locks, Monitor}

  @registry PhoenixKitAgent.Turns.Registry

  # A lock outlives the deadline of its turn by this much before another turn
  # may take it over (spec §6.1 step 3).
  @lock_grace_s 60

  @typedoc "Why a turn was not started, or not stopped."
  @type refusal ::
          Conversations.refusal()
          | :empty_message
          | :ai_disabled
          | :no_endpoint
          | :invalid_attachments
          | :conversation_busy
          | :turn_in_flight
          | :not_running
          | term()

  @doc """
  Starts a turn in the user's chat with `text` and the attachments
  `attachment_uuids` (see the moduledoc). Returns `{:ok, turn_ref}` as soon as
  the user message is stored and the turn runs.

  Options:

    * `:request_context` — what the tools' handlers get as context
      (`PhoenixKit.API.Executor.execute_as/5`): `:language`, `:base_url`,
      `:hosts`, `:currency`, `:ip`; `:request_id` defaults to the turn ref;
    * `:deadline_ms` — a shorter deadline than `agent_turn_deadline_s`; it can
      only shorten it.
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
           Conversations.get_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ),
         {:ok, text} <- message_text(text),
         :ok <- ai_enabled(),
         {:ok, endpoint_uuid} <- endpoint(),
         :ok <- within_limits(conversation.user_uuid),
         {:ok, attachments} <- new_attachments(conversation, attachment_uuids) do
      launch(session_ref, conversation, text, attachments, endpoint_uuid, opts)
    end
  end

  @doc """
  Stops the turn running in the user's chat: its task ends at once, the
  answer it was waiting for is not kept, and its locks are released (the
  chat's topic hears `:agent_turn_finished`). `{:error, :not_running}` when no
  turn runs there; someone else's chat is `{:error, :not_found}`.
  """
  @spec stop(Conversations.session_ref(), boolean(), term()) :: :ok | {:error, refusal()}
  def stop(session_ref, impersonated?, conversation_uuid) do
    with {:ok, user_uuid} <-
           Conversations.authorize_session(session_ref, impersonated: impersonated?),
         {:ok, conversation_uuid, turn_ref} <- running_turn(user_uuid, conversation_uuid) do
      case Registry.lookup(@registry, turn_ref) do
        [{pid, ^conversation_uuid}] ->
          Process.exit(pid, {:shutdown, :stopped})
          :ok

        _not_here ->
          {:error, :not_running}
      end
    end
  end

  # ── start ───────────────────────────────────────────────────────

  defp message_text(text) when is_binary(text) do
    if String.trim(text) == "", do: {:error, :empty_message}, else: {:ok, text}
  end

  defp message_text(_not_text), do: {:error, :empty_message}

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  # The module default; the user's own model is a later block (spec §7.2).
  defp endpoint do
    case Config.default_endpoint_uuid() do
      nil -> {:error, :no_endpoint}
      uuid -> {:ok, uuid}
    end
  end

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

  defp launch(session_ref, conversation, text, attachments, endpoint_uuid, opts) do
    user_uuid = conversation.user_uuid
    turn_ref = UUIDv7.generate()

    with :ok <- Locks.acquire(user_uuid, conversation.uuid, turn_ref, lock_ttl_s()) do
      case begin(session_ref, conversation, text, attachments, endpoint_uuid, turn_ref, opts) do
        {:ok, _pid} ->
          {:ok, turn_ref}

        {:error, _reason} = error ->
          Locks.release(user_uuid, conversation.uuid, turn_ref)
          error
      end
    end
  end

  defp begin(session_ref, conversation, text, attachments, endpoint_uuid, turn_ref, opts) do
    user_uuid = conversation.user_uuid

    with {:ok, message} <-
           Conversations.add_turn_message(user_uuid, conversation.uuid, %{
             turn_ref: turn_ref,
             role: "user",
             content: text
           }) do
      link_attachments(attachments, message)

      turn = %{
        turn_ref: turn_ref,
        session_ref: session_ref,
        user_uuid: user_uuid,
        conversation_uuid: conversation.uuid,
        endpoint_uuid: endpoint_uuid,
        system_prompt: system_prompt(user_uuid),
        history: history(conversation, text, attachments),
        request_context:
          opts |> Keyword.get(:request_context, []) |> Keyword.put_new(:request_id, turn_ref),
        max_rounds: Config.max_tool_rounds(),
        result_chars: Config.tool_result_chars(),
        capture?: Config.capture_ai_content?()
      }

      Monitor.start_turn(turn, deadline_ms(opts), [self() | Process.get(:"$callers", [])])
    end
  end

  defp link_attachments([], _message), do: :ok

  defp link_attachments(attachments, %Message{} = message) do
    uuids = Enum.map(attachments, & &1.uuid)

    repo().update_all(
      from(a in Attachment, where: a.uuid in ^uuids and is_nil(a.message_uuid)),
      set: [message_uuid: message.uuid]
    )

    :ok
  end

  # §7.1, for now: the module's prompt, then the admin's prompt for this user.
  defp system_prompt(user_uuid) do
    user_prompt =
      case repo().get(UserSettings, user_uuid) do
        %UserSettings{system_prompt: prompt} -> prompt
        nil -> nil
      end

    [Config.system_prompt(), user_prompt]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp history(conversation, text, attachments) do
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
    History.build(conversation.messages, earlier, current, Config.history_chars())
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
