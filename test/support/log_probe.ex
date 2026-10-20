defmodule PhoenixKitAgent.Test.LogProbe do
  @moduledoc """
  A `:logger` handler for the leak tests: every log event that passes the
  primary filters — its message, its metadata (`:crash_reason` included) and
  OTP crash reports — goes whole to the test process, so a test can look for
  a secret anywhere in it, not only in the formatted line.

  `capture/1` runs `fun` with the logger level at `:debug` and returns
  `{result, events}`; each event is `inspect/2`ed without limits.
  """

  @handler :phoenix_kit_agent_log_probe

  @doc false
  def log(event, %{config: %{pid: pid}}), do: send(pid, {__MODULE__, event})

  @doc "Runs `fun` and returns its result with every log event it caused, as text."
  def capture(fun) do
    level = Logger.level()
    :ok = :logger.add_handler(@handler, __MODULE__, %{level: :all, config: %{pid: self()}})
    Logger.configure(level: :debug)

    try do
      result = fun.()
      {result, collect([])}
    after
      Logger.configure(level: level)
      :logger.remove_handler(@handler)
    end
  end

  defp collect(acc) do
    receive do
      {__MODULE__, event} ->
        collect([inspect(event, limit: :infinity, printable_limit: :infinity) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
