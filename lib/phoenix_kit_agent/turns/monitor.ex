defmodule PhoenixKitAgent.Turns.Monitor do
  @moduledoc """
  Starts the task of each turn under `PhoenixKitAgent.Turns.TaskSupervisor`,
  watches it, and ends the turn whatever way the task ends (spec §6.1 step 5):

    * the task returns — the turn wrote its own answer or notice;
    * the deadline passes (`agent_turn_deadline_s`) — the task is killed and
      a `deadline` notice is written;
    * the user stops it (`PhoenixKitAgent.Turns.stop/3`, exit reason
      `{:shutdown, :stopped}`) — nothing is written, a partial answer is not
      kept;
    * anything else (a crash, a kill) — an `interrupted` notice.

  Then both locks of the turn are released and the chat's topic hears
  `{:agent_turn_finished, conversation_uuid, turn_ref}`.

  The task is monitored before it does anything: it registers in
  `PhoenixKitAgent.Turns.Registry` under its `turn_ref`, says so, and waits
  for the go-ahead, so a turn can neither end unseen nor be unreachable for
  "Stop" once `start_turn/3` has returned. If this process goes down, the
  supervisor (`:rest_for_one`) takes the running turns down with it; their
  locks then expire by their TTL.
  """

  use GenServer

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Turns.{Locks, Runner}

  @registry PhoenixKitAgent.Turns.Registry
  @task_supervisor PhoenixKitAgent.Turns.TaskSupervisor
  @ready_timeout 5_000
  @go_timeout 10_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts `turn` (see `PhoenixKitAgent.Turns.Runner`) in a task with
  `deadline_ms` to live. `callers` become the task's `$callers`, so the
  process that started the turn is its caller, as for a `Task` it starts.
  """
  @spec start_turn(Runner.turn(), pos_integer(), [pid()]) :: {:ok, pid()} | {:error, term()}
  def start_turn(turn, deadline_ms, callers) do
    GenServer.call(__MODULE__, {:start, turn, deadline_ms, callers}, @ready_timeout * 2)
  catch
    :exit, reason -> {:error, {:monitor_unavailable, reason}}
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:start, turn, deadline_ms, callers}, _from, turns) do
    monitor = self()

    case Task.Supervisor.start_child(@task_supervisor, fn ->
           task(monitor, turn, callers)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:turn_ready, ^pid} ->
            timer = Process.send_after(self(), {:deadline, ref}, deadline_ms)
            send(pid, :turn_go)
            entry = %{turn: turn, pid: pid, timer: timer, deadline?: false}
            {:reply, {:ok, pid}, Map.put(turns, ref, entry)}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:reply, {:error, {:not_started, reason}}, turns}
        after
          @ready_timeout ->
            Process.demonitor(ref, [:flush])
            Process.exit(pid, :kill)
            {:reply, {:error, :not_started}, turns}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, turns}
    end
  end

  @impl GenServer
  def handle_info({:deadline, ref}, turns) do
    case Map.fetch(turns, ref) do
      {:ok, entry} ->
        Process.exit(entry.pid, :kill)
        {:noreply, Map.put(turns, ref, %{entry | deadline?: true})}

      :error ->
        {:noreply, turns}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, turns) do
    case Map.pop(turns, ref) do
      {nil, turns} ->
        {:noreply, turns}

      {entry, turns} ->
        Process.cancel_timer(entry.timer)
        finish(entry, reason)
        {:noreply, turns}
    end
  end

  def handle_info(_other, turns), do: {:noreply, turns}

  # ── the task ────────────────────────────────────────────────────

  defp task(monitor, turn, callers) do
    Process.put(:"$callers", callers)
    {:ok, _} = Registry.register(@registry, turn.turn_ref, turn.conversation_uuid)
    send(monitor, {:turn_ready, self()})

    receive do
      :turn_go -> Runner.run(turn)
    after
      @go_timeout -> exit(:not_started)
    end
  end

  # ── the end of a turn ───────────────────────────────────────────

  defp finish(%{turn: turn} = entry, reason) do
    safely(fn -> write_end(turn, ending(entry, reason)) end)
    safely(fn -> Locks.release(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) end)

    PubSub.broadcast(
      Conversations.topic(turn.conversation_uuid),
      {:agent_turn_finished, turn.conversation_uuid, turn.turn_ref}
    )
  end

  defp ending(%{deadline?: true}, _reason), do: :deadline
  defp ending(_entry, :normal), do: :done
  defp ending(_entry, {:shutdown, :stopped}), do: :stopped
  defp ending(_entry, _reason), do: :interrupted

  defp write_end(_turn, ending) when ending in [:done, :stopped], do: :ok

  defp write_end(turn, :deadline) do
    add_notice(
      turn,
      "deadline",
      "The answer took longer than allowed and was stopped. Try again, or ask for less at once."
    )
  end

  defp write_end(turn, :interrupted),
    do: add_notice(turn, "interrupted", "The answer was interrupted. Try again.")

  defp add_notice(turn, error, content) do
    Conversations.add_turn_message(turn.user_uuid, turn.conversation_uuid, %{
      turn_ref: turn.turn_ref,
      role: "notice",
      content: content,
      error: error
    })
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> Logger.warning("[PhoenixKitAgent] ending a turn: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("[PhoenixKitAgent] ending a turn: #{inspect(kind)} #{inspect(reason)}")
  end
end
