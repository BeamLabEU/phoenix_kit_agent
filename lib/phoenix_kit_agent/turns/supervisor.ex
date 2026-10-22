defmodule PhoenixKitAgent.Turns.Supervisor do
  @moduledoc """
  The processes of the turn loop, started by the host through
  `PhoenixKitAgent.children/0`:

    * `PhoenixKitAgent.Turns.Registry` — a running turn's task under its
      `turn_ref` (what "Stop" finds it by);
    * `PhoenixKitAgent.Turns.Monitor` — starts, watches and ends the turns;
    * `PhoenixKitAgent.Turns.TaskSupervisor` — the turns' tasks.

  `:rest_for_one`: when the monitor goes down, the running turns go down with
  it, so no turn ever runs unwatched (past its deadline, or with its locks
  never released).
  """

  use Supervisor

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: PhoenixKitAgent.Turns.Registry},
        PhoenixKitAgent.Turns.Monitor,
        {Task.Supervisor, name: PhoenixKitAgent.Turns.TaskSupervisor}
      ],
      strategy: :rest_for_one
    )
  end
end
