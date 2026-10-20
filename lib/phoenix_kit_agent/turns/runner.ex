defmodule PhoenixKitAgent.Turns.Runner do
  @moduledoc """
  The rounds of one turn (spec §6.1, "раунд r = 1..max_tool_rounds"), run in
  the turn's task. The task first stores the user's message (spec §6.1 step
  4) and links its attachments, so a turn that never ran leaves nothing in the
  chat. Then each round:

    a. checks the session again (`Conversations.authorize_session/2`), that
       the chat is still there, that the AI module is on and that the turn
       still holds its locks (`Locks.held?/3`) — a revoked session, a blocked
       user, a lost `agent` permission, a switched-off assistant or a lock
       taken over end the turn with a notice; a deleted chat ends it quietly;
    b. lists the session's tools (`Executor.visible_for/3`, `allow: :read`) and
       shows them to the model (`PhoenixKitAgent.Turns.Tools`);
    c. sends the system prompt, the history and this turn's messages — of the
       results of earlier rounds of this turn only as many as fit, together
       with the newest round's, in `10 × agent_tool_result_chars` characters
       (spec §6.4): an older one beyond that is sent as a short stub that says
       it was left out (the database keeps it whole); the pictures of the
       user's message, if it has any, go along with it as image parts (or a
       note, where the model cannot see them or a picture cannot be made) in
       every round of this turn only — the history keeps the text — and such a
       turn is never captured into the AI journal
       (`PhoenixKitAgent.Attachments.model_parts/3`); a first model call with
       pictures that the provider refuses (`api_error`, `model_error`) takes
       the message's files off it, to be sent again;
    d. calls the model (`PhoenixKitAI.complete/3`, `source: "agent"`, the user,
       no cache, the module's content capture, and the uuid the answer will be
       stored under as `attribution`); a refusal of the `phoenix_kit_ai`
       budget is a notice, and the watchers hear of it once a day
       (`PhoenixKitAgent.Limits.ai_budget_reached/3`);
    e. stores the answer; without tool calls the turn is over. A tool call
       without a name is dropped (not run, stored or sent back); an answer
       with neither text nor a named tool call is stored as an
       `empty_answer` notice, not as an empty answer;
    f. runs each tool call — only a name shown in **this** round reaches the
       executor (`execute_as/5`, `allow: :read`), any other is `denied`, and so
       is every call past the 10th of the round — and stores each result,
       truncated. Before each call the turn checks that it still holds its
       locks: a lock taken over ends the turn there, with a notice.

  ## Stopping between steps

  "Stop" and the deadline do not kill the task at once: the monitor asks it to
  stop (`PhoenixKitAgent.Turns.Monitor`), and the task looks for that request
  before it stores the user's message, before each round, as soon as the
  model has answered and before each tool call — and then ends as
  `{:shutdown, :stopped | :deadline}` without storing anything more (a
  partial answer is not kept). A model call under way is let finish, so its
  row in the AI journal — what the call cost — is written. Only a task that
  does not get there within the grace period is killed.

  A message the database refuses ends the task as `{:shutdown,
  :store_failed}` (the log gets the field names and validation codes only),
  and the monitor writes an `interrupted` notice; a chat deleted mid-turn
  ends it as `{:shutdown, :chat_gone}`, with nothing written and no further
  model call.

  Every stored message is broadcast by `PhoenixKitAgent.Conversations`. Ending
  the task (stop, deadline, crash) and the locks are
  `PhoenixKitAgent.Turns.Monitor`'s business.

  ## The AI request of a message

  `complete/3` does not return the uuid of its journal row; the row reaches
  `record_usage/1` (`PhoenixKitAgent.handle_ai_usage/1`, a `phoenix_kit_ai`
  usage sink) with the `attribution` the call carried, synchronously, in the
  calling process and before `complete/3` returns. So the turn says which
  message uuid it waits for, `record_usage/1` keeps the row for it in the
  process, and the message is stored with `ai_request_uuid` (and the row's
  model, tokens, cost and latency). A row for an already stored message —
  from any other process — sets its `ai_request_uuid` in the database, only
  for a message of the row's own user that has none yet.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Attachments, Conversations, Limits}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Turns.{Locks, Monitor, Tools}

  @awaiting {__MODULE__, :awaiting_ai_request}

  # The most tool calls of one round that reach the executor; the rest are
  # denied. One answer of the model must not fan out into hundreds of calls.
  @max_calls_per_round 10

  # What an older result of this turn is sent as once the turn's results are
  # over their budget.
  @omitted Jason.encode!(%{
             "omitted" => true,
             "hint" =>
               "This earlier result was left out to keep the conversation short. " <>
                 "Call the tool again if you still need it."
           })

  # The model errors of `PhoenixKitAI.complete/3` kept as their own code in
  # `messages.error`; any other is "model_error".
  @model_errors ~w(request_timeout invalid_api_key api_key_forbidden rate_limited
                   insufficient_credits invalid_json_response invalid_response_format
                   no_choices_in_response endpoint_not_found endpoint_disabled
                   endpoint_no_model integration_not_configured integration_deleted
                   not_configured)a

  @typedoc "Everything a turn needs; built by `PhoenixKitAgent.Turns.start/6`."
  @type turn :: %{
          turn_ref: String.t(),
          session_ref: PhoenixKit.Users.Auth.SessionRef.t(),
          user_uuid: String.t(),
          conversation_uuid: String.t(),
          endpoint_uuid: String.t(),
          text: String.t(),
          attachment_uuids: [String.t()],
          system_prompt: String.t() | nil,
          history: [map()],
          request_context: keyword(),
          max_rounds: pos_integer(),
          result_chars: pos_integer(),
          capture?: boolean()
        }

  @doc """
  Stores the user's message of `turn`, then runs its rounds until the model
  answers without tool calls.
  """
  @spec run(turn()) :: :ok
  def run(turn) do
    :ok = Monitor.check_stop()
    message = store_user_message!(turn)
    {turn, transcript} = with_pictures(Map.put(turn, :user_message_uuid, message.uuid))
    round(turn, 1, transcript)
  end

  # The pictures of this message's attachments go along with its text, in this
  # turn only (spec §9): the history keeps the extracted text, not the pixels.
  # A turn that carries pictures is never captured into the AI journal, whatever
  # the module's setting: the pixels would be written there as base64. One that
  # carries only notes about pictures it could not show has no pixels to write.
  #
  # `pictures?` holds until the model has answered once: a first call that
  # fails as the provider's refusal may be a refusal of the pictures, and then
  # the files are taken off the message, to be sent again (`unsend/2`).
  defp with_pictures(%{attachment_uuids: []} = turn),
    do: {Map.put(turn, :pictures?, false), turn.history}

  defp with_pictures(turn) do
    turn = Map.put(turn, :pictures?, false)

    case Attachments.model_parts(turn.attachment_uuids, turn.user_uuid, turn.endpoint_uuid) do
      [] ->
        {turn, turn.history}

      parts ->
        {earlier, [current]} = Enum.split(turn.history, -1)
        {notes, pictures} = Enum.split_with(parts, &(&1["type"] == "text"))
        text = Enum.reduce(notes, current.content, &(&2 <> "\n\n" <> &1["text"]))

        content =
          if pictures == [],
            do: text,
            else: [%{"type" => "text", "text" => text} | pictures]

        turn = if pictures == [], do: turn, else: %{turn | capture?: false, pictures?: true}
        {turn, earlier ++ [%{current | content: content}]}
    end
  end

  @doc """
  The usage sink behind `PhoenixKitAgent.handle_ai_usage/1`: links an AI
  request row to the message its `attribution` names (see the moduledoc).
  """
  @spec record_usage(struct()) :: :ok
  def record_usage(%{uuid: request_uuid} = request) when is_binary(request_uuid) do
    case attributed_message(request) do
      nil ->
        :ok

      message_uuid ->
        if Process.get(@awaiting) == message_uuid,
          do: Process.put({@awaiting, message_uuid}, request),
          else: link_stored(message_uuid, request)

        :ok
    end
  end

  def record_usage(_other), do: :ok

  # ── the rounds ──────────────────────────────────────────────────

  defp round(%{max_rounds: max} = turn, r, _transcript) when r > max,
    do: notice(turn, "max_tool_rounds", "The assistant used all its tool rounds for this turn.")

  defp round(turn, r, transcript) do
    with :ok <- may_go_on(turn),
         {:ok, tools} <- visible_tools(turn) do
      {definitions, allowed} = Tools.for_model(tools)

      case ask_model(turn, transcript, definitions) do
        {:ok, %Message{role: "assistant", tool_calls: calls} = message}
        when is_list(calls) and calls != [] ->
          case run_calls(turn, calls, allowed) do
            {:ok, results} ->
              latest = [assistant_entry(message) | results]
              turn = %{turn | pictures?: false}
              round(turn, r + 1, fit_turn(transcript, latest, turn.result_chars) ++ latest)

            {:error, reason} ->
              stopped(turn, reason)
          end

        _answered_or_failed ->
          :ok
      end
    else
      {:error, :chat_gone} -> exit({:shutdown, :chat_gone})
      {:error, reason} -> stopped(turn, reason)
    end
  end

  defp may_go_on(turn) do
    :ok = Monitor.check_stop()

    with {:ok, _user_uuid} <-
           Conversations.authorize_session(turn.session_ref, impersonated: false) do
      cond do
        not chat_alive?(turn) ->
          {:error, :chat_gone}

        not PhoenixKitAI.enabled?() ->
          {:error, :ai_disabled}

        not Locks.held?(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) ->
          {:error, :lock_lost}

        true ->
          :ok
      end
    end
  end

  defp chat_alive?(turn) do
    RepoHelper.repo().exists?(
      from(c in Conversation,
        where:
          c.uuid == ^turn.conversation_uuid and c.user_uuid == ^turn.user_uuid and
            c.status != "deleted"
      )
    )
  end

  # The earlier transcript, with the oldest results of this turn turned into
  # stubs until the results still in it and those of the newest round fit
  # `@max_calls_per_round` results. The newest round is never cut: the model
  # has not seen it yet. The history holds no `tool` entries.
  defp fit_turn(earlier, latest, result_chars) do
    budget = @max_calls_per_round * result_chars
    used = results_size(earlier) + results_size(latest)

    {fitted, _used} =
      Enum.map_reduce(earlier, used, fn
        %{role: "tool", content: content} = entry, used
        when used > budget and content != @omitted ->
          {%{entry | content: @omitted}, used - String.length(content)}

        entry, used ->
          {entry, used}
      end)

    fitted
  end

  defp results_size(entries) do
    entries
    |> Enum.filter(&(&1.role == "tool" and &1.content != @omitted))
    |> Enum.map(&String.length(&1.content))
    |> Enum.sum()
  end

  defp visible_tools(turn) do
    case Executor.visible_for(turn.session_ref, :admin, allow: :read) do
      {:ok, tools, _headers} -> {:ok, tools}
      {:error, :unauthorized, _detail, %{reason: reason}, _headers} -> {:error, reason}
      {:error, code, _detail, _context, _headers} -> {:error, code}
    end
  end

  # ── the model call ──────────────────────────────────────────────

  defp ask_model(turn, transcript, definitions) do
    message_uuid = UUIDv7.generate()
    started = System.monotonic_time(:millisecond)

    opts =
      [
        user_uuid: turn.user_uuid,
        source: "agent",
        cache: false,
        capture_request_content: turn.capture?,
        attribution: %{"agent_message_uuid" => message_uuid}
      ] ++ if(definitions == [], do: [], else: [tools: definitions])

    Process.put(@awaiting, message_uuid)

    result =
      try do
        PhoenixKitAI.complete(turn.endpoint_uuid, system(turn) ++ transcript, opts)
      after
        Process.delete(@awaiting)
      end

    # The call is over and its journal row written: a stop asked for while it
    # ran ends the turn here, before the answer is stored.
    :ok = Monitor.check_stop()

    request = Process.delete({@awaiting, message_uuid})
    latency_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, response} ->
        store_answer(turn, message_uuid, response, request, latency_ms)

      {:error, reason} ->
        unsent? = unsend(turn, reason)

        notice(turn, error_code(reason), model_error_text(reason, unsent?),
          uuid: message_uuid,
          ai_request_uuid: request && request.uuid
        )

        with {:budget_exceeded, scope} <- reason,
             do: Limits.ai_budget_reached(turn.user_uuid, scope)

        {:error, reason}
    end
  end

  defp system(%{system_prompt: nil}), do: []
  defp system(%{system_prompt: prompt}), do: [%{role: "system", content: prompt}]

  defp store_answer(turn, message_uuid, response, request, latency_ms) do
    content =
      case PhoenixKitAI.extract_content(response) do
        {:ok, text} when is_binary(text) -> Message.strip_nul(text)
        _no_text -> nil
      end

    # A call without a name can be neither run nor sent back: strict
    # providers refuse a replayed call named "".
    calls =
      response
      |> PhoenixKitAI.extract_tool_calls()
      |> Enum.with_index(1)
      |> Enum.map(&stored_call/1)
      |> Enum.reject(&is_nil(&1["name"]))

    fields = [uuid: message_uuid, ai_request_uuid: request && request.uuid]
    usage = usage(request, response, latency_ms)

    attrs =
      if calls == [] and (content == nil or String.trim(content) == "") do
        %{
          role: "notice",
          content: "The model gave no answer. Try again.",
          error: "empty_answer"
        }
      else
        %{role: "assistant", content: content, tool_calls: if(calls == [], do: nil, else: calls)}
      end

    {:ok, store!(turn, attrs |> Map.put(:turn_ref, turn.turn_ref) |> Map.merge(usage), fields)}
  end

  # Model, tokens, cost and latency: from the journal row when the usage sink
  # caught it (cost is in micro-dollars there too), else from the response.
  defp usage(nil, response, latency_ms) do
    usage = response["usage"] || %{}

    %{
      model: response["model"],
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      latency_ms: latency_ms
    }
  end

  defp usage(request, response, latency_ms) do
    %{
      model: request.model || response["model"],
      input_tokens: request.input_tokens,
      output_tokens: request.output_tokens,
      cost_micro_usd: request.cost_cents,
      latency_ms: request.latency_ms || latency_ms
    }
  end

  # A tool call as stored and replayed: `{id, name, arguments}` as the model
  # sent them (a missing id gets a stand-in, so the result can answer it).
  defp stored_call({raw, index}) do
    raw = if is_map(raw), do: raw, else: %{}
    function = if is_map(raw["function"]), do: raw["function"], else: %{}

    %{
      "id" => non_blank(raw["id"]) || "call_#{index}",
      "name" => non_blank(function["name"]),
      "arguments" => function["arguments"]
    }
  end

  defp assistant_entry(%Message{content: content, tool_calls: calls}) do
    %{
      role: "assistant",
      content: content,
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            "id" => call["id"],
            "type" => "function",
            "function" => %{
              "name" => call["name"],
              "arguments" => encoded_arguments(call["arguments"])
            }
          }
        end)
    }
  end

  defp encoded_arguments(arguments) when is_binary(arguments), do: arguments
  defp encoded_arguments(nil), do: "{}"
  defp encoded_arguments(arguments), do: Jason.encode!(arguments)

  # ── a tool call ─────────────────────────────────────────────────

  # The calls of one answer, in order; before each, a stop asked for ends the
  # turn and a lock taken over ends it with a notice.
  defp run_calls(turn, calls, allowed) do
    calls
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {call, n}, {:ok, results} ->
      :ok = Monitor.check_stop()

      if Locks.held?(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) do
        result =
          if n <= @max_calls_per_round,
            do: run_call(turn, call, allowed),
            else: run_call(turn, call, %{}, too_many_calls())

        {:cont, {:ok, [result | results]}}
      else
        {:halt, {:error, :lock_lost}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp run_call(turn, call, allowed, denial \\ denied()) do
    {registry_name, outcome, result} =
      case Map.fetch(allowed, call["name"]) do
        {:ok, tool} -> execute(turn, tool, call["arguments"])
        :error -> {denied_name(call["name"]), "denied", denial}
      end

    tool_result = Tools.fit(result, turn.result_chars)

    store!(turn, %{
      turn_ref: turn.turn_ref,
      role: "tool",
      tool_call_id: call["id"],
      tool_name: registry_name,
      tool_outcome: outcome,
      tool_result: tool_result
    })

    %{
      role: "tool",
      tool_call_id: call["id"],
      name: call["name"],
      content: Jason.encode!(tool_result)
    }
  end

  defp execute(turn, tool, arguments) do
    case Tools.arguments(arguments) do
      {:ok, input} ->
        case Executor.execute_as(turn.session_ref, :admin, tool.name, input,
               allow: :read,
               request_context: turn.request_context
             ) do
          {:ok, %{result: result}, _headers} ->
            {tool.name, "ok", result}

          {:error, code, detail, context, _headers} ->
            {tool.name, "error", refusal(code, detail, context)}
        end

      :error ->
        {tool.name, "error",
         %{"error" => "invalid_arguments", "message" => "The arguments must be a JSON object."}}
    end
  end

  defp refusal(code, detail, context) do
    base = %{"error" => to_string(code), "message" => detail}

    with %{errors: errors} when is_list(errors) <- context,
         {:ok, _json} <- Jason.encode(errors) do
      Map.put(base, "errors", errors)
    else
      _ -> base
    end
  end

  defp denied,
    do: %{"error" => "denied", "message" => "This tool is not available to you here."}

  defp too_many_calls do
    %{
      "error" => "denied",
      "message" => "Too many tool calls at once; at most #{@max_calls_per_round} run per round."
    }
  end

  # The registry name when the model's name maps to one, else its own name.
  defp denied_name(name), do: name |> Names.resolve(:admin) |> clip()

  # ── storing ─────────────────────────────────────────────────────

  # A message of the turn, or the end of the turn: a deleted chat ends it
  # quietly; a refused message ends it with only the field names and
  # validation codes in the log, never the values.
  defp store_user_message!(turn) do
    attrs = %{turn_ref: turn.turn_ref, role: "user", content: turn.text}

    turn.user_uuid
    |> Conversations.add_user_turn_message(turn.conversation_uuid, attrs, turn.attachment_uuids)
    |> stored!(attrs)
  end

  defp store!(turn, attrs, fields \\ []) do
    turn.user_uuid
    |> Conversations.add_turn_message(turn.conversation_uuid, attrs, fields)
    |> stored!(attrs)
  end

  defp stored!(result, attrs) do
    case result do
      {:ok, message} ->
        message

      {:error, :not_found} ->
        exit({:shutdown, :chat_gone})

      {:error, %Ecto.Changeset{} = changeset} ->
        codes =
          Enum.map(changeset.errors, fn {field, {_text, opts}} -> {field, opts[:validation]} end)

        Logger.warning(
          "[PhoenixKitAgent] a #{attrs.role} message of a turn was not stored: #{inspect(codes)}"
        )

        exit({:shutdown, :store_failed})
    end
  end

  # ── notices ─────────────────────────────────────────────────────

  defp stopped(turn, reason) when is_atom(reason) do
    notice(turn, Atom.to_string(reason), stop_text(reason))
  end

  defp stop_text(reason)
       when reason in [:session_gone, :mismatch, :inactive, :unconfirmed, :referral_required],
       do: "Your session has ended, so the assistant stopped."

  defp stop_text(:forbidden), do: "The assistant is no longer available to you."
  defp stop_text(:ai_disabled), do: "The AI module is switched off."
  defp stop_text(:rate_limited), do: "Too many requests at once; try again in a minute."
  defp stop_text(:not_found), do: "This chat is gone."
  defp stop_text(:lock_lost), do: "The answer was interrupted. Try again."
  defp stop_text(_other), do: "The assistant stopped."

  defp notice(turn, error, content, fields \\ []) do
    _ =
      Conversations.add_turn_message(
        turn.user_uuid,
        turn.conversation_uuid,
        %{turn_ref: turn.turn_ref, role: "notice", content: content, error: error},
        fields
      )

    :ok
  end

  defp error_code({:budget_exceeded, _scope}), do: "budget_exceeded"
  defp error_code({:api_error, _status}), do: "api_error"
  defp error_code({:connection_error, _reason}), do: "connection_error"
  defp error_code(reason) when reason in @model_errors, do: Atom.to_string(reason)
  defp error_code(_reason), do: "model_error"

  defp model_error_text({:budget_exceeded, _scope}, _unsent?), do: "The AI budget is used up."

  defp model_error_text(_reason, true),
    do:
      "The model did not answer; it may not take the pictures. " <>
        "The files were not sent with the message: you can send them again."

  defp model_error_text(_reason, false), do: "The model did not answer. Try again."

  # The first model call that carried the message's pictures was refused by
  # the provider (spec §9: a model that cannot take them): the files are taken
  # off the message and wait to be sent again. A budget, a key, a timeout or
  # the network say nothing of the pictures, and leave them where they are.
  defp unsend(%{pictures?: true} = turn, reason) do
    if error_code(reason) in ["api_error", "model_error"] do
      :ok =
        Conversations.unlink_attachments(
          turn.user_uuid,
          turn.conversation_uuid,
          turn.user_message_uuid
        )

      true
    else
      false
    end
  end

  defp unsend(_turn, _reason), do: false

  # ── the AI request link ─────────────────────────────────────────

  defp attributed_message(%{metadata: metadata}) when is_map(metadata) do
    attribution = metadata["attribution"] || metadata[:attribution]

    with %{} <- attribution,
         uuid when is_binary(uuid) <- attribution["agent_message_uuid"],
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      uuid
    else
      _ -> nil
    end
  end

  defp attributed_message(_request), do: nil

  defp link_stored(message_uuid, %{uuid: request_uuid, user_uuid: user_uuid})
       when is_binary(user_uuid) do
    RepoHelper.repo().update_all(
      from(m in Message,
        join: c in Conversation,
        on: c.uuid == m.conversation_uuid,
        where: m.uuid == ^message_uuid and is_nil(m.ai_request_uuid) and c.user_uuid == ^user_uuid
      ),
      set: [ai_request_uuid: request_uuid]
    )

    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKitAgent] AI request not linked: #{inspect(error.__struct__)}")
      :ok
  end

  defp link_stored(_message_uuid, _request_without_user), do: :ok

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: clip(value)
  end

  defp non_blank(_value), do: nil

  defp clip(text), do: String.slice(text, 0, 200)
end
