defmodule PhoenixKitAgent.Turns.Monitor do
  @moduledoc """
  Starts the task of each turn under `PhoenixKitAgent.Turns.TaskSupervisor`,
  watches it, and ends the turn whatever way the task ends (spec §6.1 step 5):

    * the task returns — the turn wrote its own answer or notice;
    * the deadline passes (`agent_turn_deadline_s`) — the task is killed and
      a `deadline` notice is written;
    * the user stops it (`PhoenixKitAgent.Turns.stop/4`, exit reason
      `{:shutdown, :stopped}`) — nothing is written, a partial answer is not
      kept;
    * it never got the go-ahead (`{:shutdown, :not_started}`, see below) —
      nothing is written: the turn wrote nothing yet;
    * anything else (a crash, a kill) — an `interrupted` notice.

  Then both locks of the turn are released and the chat's topic hears
  `{:agent_turn_finished, conversation_uuid, turn_ref}`. Those writes run in a
  short-lived process of their own, so a slow database delays no other start
  and no deadline.

  ## The start handshake

  The task is monitored before it does anything. It registers in
  `PhoenixKitAgent.Turns.Registry` under its `turn_ref`, tells the process
  that starts the turn so, and waits for that process's go-ahead — not this
  one's. So a turn runs only once `start_turn/3` has returned `{:ok, pid}` to
  its caller, and is then already reachable for "Stop". A caller that gave up
  (this process was too busy to take the start in time, or the task did not
  report ready) sends no go-ahead, and the task ends on its own without
  touching the chat or the locks its caller has already released.

  If this process goes down, the supervisor (`:rest_for_one`) takes the
  running turns down with it; their locks then expire by their TTL.
  """

  use GenServer

  require Logger

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKitAgent.Conversations
  alias PhoenixKitAgent.Turns.{Locks, Runner}

  @registry PhoenixKitAgent.Turns.Registry
  @task_supervisor PhoenixKitAgent.Turns.TaskSupervisor

  # The handshake's unit, in ms: the caller waits up to twice this for this
  # process to take the start and once this for the task to be ready; the
  # task waits up to twice this for the go-ahead.
  @handshake_ms 5_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts `turn` (see `PhoenixKitAgent.Turns.Runner`) in a task with
  `deadline_ms` to live, and lets it run once it is registered (see "The start
  handshake"). `callers` become the task's `$callers`, so the process that
  started the turn is its caller, as for a `Task` it starts.
  """
  @spec start_turn(Runner.turn(), pos_integer(), [pid()]) :: {:ok, pid()} | {:error, term()}
  def start_turn(turn, deadline_ms, callers) do
    token = Process.alias()

    try do
      with {:ok, pid} <- request_start(turn, deadline_ms, callers, token),
           :ok <- await_ready(pid, token) do
        send(pid, {:turn_go, token})
        {:ok, pid}
      end
    after
      Process.unalias(token)
      flush_ready(token)
    end
  end

  defp request_start(turn, deadline_ms, callers, token) do
    GenServer.call(__MODULE__, {:start, turn, deadline_ms, callers, token}, handshake_ms() * 2)
  catch
    :exit, reason -> {:error, {:monitor_unavailable, reason}}
  end

  defp await_ready(pid, token) do
    ref = Process.monitor(pid)

    receive do
      {:turn_ready, ^token} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:not_started, reason}}
    after
      handshake_ms() ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, {:shutdown, :not_started})
        {:error, :not_started}
    end
  end

  # A ready message that came in as the wait gave up; nothing else is sent to
  # the alias, and after `unalias/1` nothing more arrives.
  defp flush_ready(token) do
    receive do
      {:turn_ready, ^token} -> :ok
    after
      0 -> :ok
    end
  end

  defp handshake_ms,
    do: Application.get_env(:phoenix_kit_agent, :turn_handshake_ms, @handshake_ms)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:start, turn, deadline_ms, callers, token}, _from, turns) do
    go_wait = handshake_ms() * 2

    case Task.Supervisor.start_child(@task_supervisor, fn ->
           task(turn, callers, token, go_wait)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        timer = Process.send_after(self(), {:deadline, ref}, deadline_ms)

        entry = %{
          turn: Map.take(turn, [:turn_ref, :user_uuid, :conversation_uuid]),
          pid: pid,
          timer: timer,
          deadline?: false
        }

        {:reply, {:ok, pid}, Map.put(turns, ref, entry)}

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
        turn = entry.turn
        ending = ending(entry, reason)

        case Task.Supervisor.start_child(@task_supervisor, fn -> finish(turn, ending) end) do
          {:ok, _pid} -> :ok
          {:error, _reason} -> finish(turn, ending)
        end

        {:noreply, turns}
    end
  end

  def handle_info(_other, turns), do: {:noreply, turns}

  # ── the task ────────────────────────────────────────────────────

  defp task(turn, callers, token, go_wait) do
    Process.put(:"$callers", callers)
    {:ok, _} = Registry.register(@registry, turn.turn_ref, turn.conversation_uuid)
    send(token, {:turn_ready, token})

    receive do
      {:turn_go, ^token} -> Runner.run(turn)
    after
      go_wait -> exit({:shutdown, :not_started})
    end
  end

  # ── the end of a turn ───────────────────────────────────────────

  defp finish(turn, ending) do
    safely(fn -> write_end(turn, ending) end)
    safely(fn -> Locks.release(turn.user_uuid, turn.conversation_uuid, turn.turn_ref) end)

    PubSub.broadcast(
      Conversations.topic(turn.conversation_uuid),
      {:agent_turn_finished, turn.conversation_uuid, turn.turn_ref}
    )
  end

  # A task that returned is done, even when its deadline fired a moment late.
  defp ending(_entry, :normal), do: :done
  defp ending(%{deadline?: true}, _reason), do: :deadline
  defp ending(_entry, {:shutdown, :stopped}), do: :stopped
  defp ending(_entry, {:shutdown, :not_started}), do: :not_started
  defp ending(_entry, _reason), do: :interrupted

  defp write_end(_turn, ending) when ending in [:done, :stopped, :not_started], do: :ok

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
