defmodule PhoenixKitAgent.Speech do
  @moduledoc """
  A recording written down for a user of the assistant: a voice message of the
  linked Telegram chat, or a clip of the chat panel's microphone. The text is
  the user's own words, to be sent as a message: this module only recognises,
  it starts no turn and keeps nothing.

  `transcribe/4` is the one door. It answers `{:error, :speech_off}` unless
  `PhoenixKitAgent.Config.speech?/0` (the AI module can write speech down and
  a speech model is chosen on Settings → AI Agent), then, in this order and
  before anything is paid:

    1. the AI module is on;
    2. the session may use the assistant now, as `PhoenixKitAgent.Conversations`
       decides it — a site session that is not borrowed, or a linked Telegram
       chat that is still linked and holds `agent.telegram`; the user is the one
       the session names, never a uuid a client sent;
    3. the recording is not over `max_bytes/0`;
    4. the user's limits (`PhoenixKitAgent.Limits.check/3`, money of the speech
       endpoint as `Models.reports_cost?/2` counts it), under a lock of the
       user's recognitions, so each one sees what the last one cost.

  The call is `PhoenixKitAI.transcribe/3` with the user's `user_uuid:`,
  `source: "agent"` and `task: "agent.speech"`, so the journal row is the
  user's and `PhoenixKitAgent.Spend` counts it. The words are not kept in the
  journal (`capture_request_content: false`), and nothing of the audio or the
  text is logged.

  The answer is `{:ok, text}` or `{:error, code}`: `:speech_off`, `:no_speech`
  (the recording holds none), `:too_long`, `:unfit` (the chosen model cannot
  take audio), `:failed`, `:ai_disabled`, `:budget_exceeded`, `:task_blocked`,
  `:task_limit_exceeded`, `{:limit_reached, kind}`, or the refusal of
  `Conversations` (`:forbidden`, `:session_gone`, `:impersonated`, …). The
  texts are `PhoenixKitAgent.Web.Dock.Texts.speech_error/1`.
  """

  require Logger

  alias PhoenixKitAgent.{Config, Conversations, Limits, UserConfig}
  alias PhoenixKitAgent.Schemas.Message

  @max_bytes 10 * 1_048_576
  @max_seconds 120
  @timeout_ms 60_000

  @guard_refusals ~w(task_blocked task_limit_exceeded)a

  @typedoc "Why a recording was not written down."
  @type error ::
          :speech_off
          | :no_speech
          | :too_long
          | :unfit
          | :failed
          | :ai_disabled
          | :budget_exceeded
          | :task_blocked
          | :task_limit_exceeded
          | {:limit_reached, Limits.kind()}
          | atom()

  @doc "The longest recording taken, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The longest recording taken, in seconds."
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: @max_seconds

  @doc """
  Writes `bytes`, a recording in `format` (`"wav"`, `"ogg"`, …; `nil` where
  the bytes tell it), down for the
  user of `session_ref` (a site session or a linked Telegram chat, see
  `PhoenixKitAgent.Conversations`). `opts` must hold `impersonated:`, as the
  functions of `Conversations` do.
  """
  @spec transcribe(Conversations.session_ref(), binary(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def transcribe(session_ref, bytes, format, opts)
      when is_binary(bytes) and (is_binary(format) or is_nil(format)) do
    with :ok <- speech_on(),
         :ok <- ai_enabled(),
         {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts),
         :ok <- size_ok(bytes) do
      one_at_a_time(user_uuid, fn -> paid(user_uuid, bytes, format) end)
    end
  end

  defp speech_on, do: if(Config.speech?(), do: :ok, else: {:error, :speech_off})

  defp ai_enabled, do: if(PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled})

  defp size_ok(bytes), do: if(byte_size(bytes) > @max_bytes, do: {:error, :too_long}, else: :ok)

  # One recognition of a user at a time, on every connected node: the lock is
  # held by this process, and freed when it returns or is killed.
  defp one_at_a_time(user_uuid, fun),
    do: :global.trans({{__MODULE__, :transcribe, user_uuid}, self()}, fun)

  defp paid(user_uuid, bytes, format) do
    endpoint = Config.speech_endpoint_uuid()

    with {:ok, endpoint} <- chosen(endpoint),
         :ok <- within_limits(user_uuid, endpoint) do
      ask(endpoint, user_uuid, bytes, format)
    end
  end

  defp chosen(nil), do: {:error, :speech_off}
  defp chosen(endpoint), do: {:ok, endpoint}

  defp within_limits(user_uuid, endpoint) do
    case Limits.check(UserConfig.effective(user_uuid), endpoint, use: :speech) do
      :ok -> :ok
      {:error, {:limit_reached, status}} -> {:error, {:limit_reached, status.kind}}
    end
  end

  defp ask(endpoint, user_uuid, bytes, format) do
    result =
      Config.speech_ai().transcribe(endpoint, audio(bytes, format),
        user_uuid: user_uuid,
        source: "agent",
        task: "agent.speech",
        max_audio_bytes: @max_bytes,
        timeout: @timeout_ms,
        capture_request_content: false,
        # Never answered from, nor put into, a cache the other users share.
        cache: false
      )

    outcome(result)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] speech recognition failed: #{inspect(exception.__struct__)}"
      )

      {:error, :failed}
  catch
    kind, _reason ->
      Logger.warning("[PhoenixKitAgent] speech recognition failed: #{kind}")
      {:error, :failed}
  end

  defp audio(bytes, nil), do: %{data: bytes}
  defp audio(bytes, format), do: %{data: bytes, format: format}

  defp outcome({:ok, %{text: text}}) when is_binary(text) do
    case text |> Message.strip_nul() |> String.trim() do
      "" -> {:error, :no_speech}
      words -> {:ok, words}
    end
  end

  defp outcome({:error, :empty_input}), do: {:error, :no_speech}
  defp outcome({:error, {:audio_too_large, _bytes, _max}}), do: {:error, :too_long}
  defp outcome({:error, {:model_unfit, _needs}}), do: {:error, :unfit}
  defp outcome({:error, {:model_unverified, _needs}}), do: {:error, :unfit}
  defp outcome({:error, {:budget_exceeded, _scope}}), do: {:error, :budget_exceeded}

  defp outcome({:error, reason}) when is_tuple(reason) and elem(reason, 0) in @guard_refusals,
    do: {:error, elem(reason, 0)}

  defp outcome({:error, reason}) when reason in @guard_refusals, do: {:error, reason}

  defp outcome(_failed), do: {:error, :failed}
end
