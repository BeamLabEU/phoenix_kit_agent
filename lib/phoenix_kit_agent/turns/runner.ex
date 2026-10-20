defmodule PhoenixKitAgent.Turns.Runner do
  @moduledoc """
  The rounds of one turn (spec §6.1, "раунд r = 1..max_tool_rounds"), run in
  the turn's task. Each round:

    a. checks the session again (`Conversations.authorize_session/2`) and that
       the AI module is on — a revoked session, a blocked user, a lost `agent`
       permission or a switched-off assistant end the turn with a notice;
    b. lists the session's tools (`Executor.visible_for/3`, `allow: :read`) and
       shows them to the model (`PhoenixKitAgent.Turns.Tools`);
    c. sends the system prompt, the history and this turn's messages;
    d. calls the model (`PhoenixKitAI.complete/3`, `source: "agent"`, the user,
       no cache, the module's content capture, and the uuid the answer will be
       stored under as `attribution`);
    e. stores the answer; without tool calls the turn is over;
    f. runs each tool call — only a name shown in **this** round reaches the
       executor (`execute_as/5`, `allow: :read`), any other is `denied` — and
       stores each result, truncated.

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
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Turns.Tools

  @awaiting {__MODULE__, :awaiting_ai_request}

  @typedoc "Everything a turn needs; built by `PhoenixKitAgent.Turns.start/6`."
  @type turn :: %{
          turn_ref: String.t(),
          session_ref: PhoenixKit.Users.Auth.SessionRef.t(),
          user_uuid: String.t(),
          conversation_uuid: String.t(),
          endpoint_uuid: String.t(),
          system_prompt: String.t() | nil,
          history: [map()],
          request_context: keyword(),
          max_rounds: pos_integer(),
          result_chars: pos_integer(),
          capture?: boolean()
        }

  @doc "Runs the rounds of `turn` until the model answers without tool calls."
  @spec run(turn()) :: :ok
  def run(turn), do: round(turn, 1, turn.history)

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
        {:ok, %Message{tool_calls: calls} = message} when is_list(calls) and calls != [] ->
          results = Enum.map(calls, &run_call(turn, &1, allowed))
          round(turn, r + 1, transcript ++ [assistant_entry(message)] ++ results)

        _answered_or_failed ->
          :ok
      end
    else
      {:error, reason} -> stopped(turn, reason)
    end
  end

  defp may_go_on(turn) do
    with {:ok, _user_uuid} <-
           Conversations.authorize_session(turn.session_ref, impersonated: false) do
      if PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled}
    end
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

    request = Process.delete({@awaiting, message_uuid})
    latency_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, response} ->
        store_answer(turn, message_uuid, response, request, latency_ms)

      {:error, reason} ->
        notice(turn, error_code(reason), model_error_text(reason),
          uuid: message_uuid,
          ai_request_uuid: request && request.uuid
        )

        {:error, reason}
    end
  end

  defp system(%{system_prompt: nil}), do: []
  defp system(%{system_prompt: prompt}), do: [%{role: "system", content: prompt}]

  defp store_answer(turn, message_uuid, response, request, latency_ms) do
    content =
      case PhoenixKitAI.extract_content(response) do
        {:ok, text} when is_binary(text) -> text
        _no_text -> nil
      end

    calls =
      response
      |> PhoenixKitAI.extract_tool_calls()
      |> Enum.with_index(1)
      |> Enum.map(&stored_call/1)

    attrs =
      Map.merge(
        %{
          turn_ref: turn.turn_ref,
          role: "assistant",
          content: content,
          tool_calls: if(calls == [], do: nil, else: calls)
        },
        usage(request, response, latency_ms)
      )

    Conversations.add_turn_message(turn.user_uuid, turn.conversation_uuid, attrs,
      uuid: message_uuid,
      ai_request_uuid: request && request.uuid
    )
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
              "name" => call["name"] || "",
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

  defp run_call(turn, call, allowed) do
    {registry_name, outcome, result} =
      case Map.fetch(allowed, call["name"] || "") do
        {:ok, tool} -> execute(turn, tool, call["arguments"])
        :error -> {denied_name(call["name"]), "denied", denied()}
      end

    tool_result = Tools.fit(result, turn.result_chars)

    Conversations.add_turn_message(turn.user_uuid, turn.conversation_uuid, %{
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
      name: call["name"] || "",
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

  # The registry name when the model's name maps to one, else its own name.
  defp denied_name(name) when is_binary(name), do: name |> Names.resolve(:admin) |> clip()
  defp denied_name(_none), do: nil

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
  defp error_code(reason), do: reason |> inspect() |> clip()

  defp model_error_text({:budget_exceeded, _scope}), do: "The AI budget is used up."
  defp model_error_text(_reason), do: "The model did not answer. Try again."

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
      Logger.warning("[PhoenixKitAgent] AI request not linked: #{Exception.message(error)}")
      :ok
  end

  defp link_stored(_message_uuid, _request_without_user), do: :ok

  defp non_blank(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: clip(value)
  end

  defp non_blank(_value), do: nil

  defp clip(text), do: String.slice(text, 0, 200)
end
