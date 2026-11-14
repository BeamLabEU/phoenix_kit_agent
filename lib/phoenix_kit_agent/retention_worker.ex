defmodule PhoenixKitAgent.RetentionWorker do
  @moduledoc """
  Applies the chat retention (`PhoenixKitAgent.Retention`) every night:
  scheduled by the module's `oban_crons/0` (core's `default` queue). With no
  period set (`agent_retention_days`, the default) a run does nothing at all.

  One run at a time: while a run is queued or executing, another is not
  inserted. A batch that fails is an error and Oban retries it (3 attempts);
  the chats already deleted stay deleted.

  "While a run is executing" includes a job orphaned in that state by a crash:
  with no Oban Lifeline plugin on the host it would block every later night, so
  the host must run it (see the README).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker],
      keys: [],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias PhoenixKitAgent.Retention

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Retention.run() do
      {:ok, _summary} -> :ok
      {:skipped, _why} -> :ok
    end
  end
end
