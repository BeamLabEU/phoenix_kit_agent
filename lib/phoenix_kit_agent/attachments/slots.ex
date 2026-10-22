defmodule PhoenixKitAgent.Attachments.Slots do
  @moduledoc """
  The places for work on files on the node (spec §9): at most
  `Bounds` `concurrent_jobs` files are processed at the same time, of whom at
  most `jobs_per_user` are one user's. A file that finds no place waits for
  one, in turn, up to `queue_wait_ms`; with `queued_jobs` waiting already, or
  when the time is up, it is refused (`{:error, :unavailable}`) and the file
  `failed` as `unavailable`.

  A place is held by the process that took it and is free when that process
  ends, however it ends; a waiting process that ends leaves the queue. The
  limits are read at each decision, so changing them needs no restart. Users
  are told apart by uuid only; nothing of a file is known here.
  """

  use GenServer

  alias PhoenixKitAgent.Attachments.Bounds

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  A place for the calling process, for `user_uuid`: `:ok` once there is one,
  `{:error, :unavailable}` when there is no room in the queue or the wait is
  over (or the slots are not running). The place is held until the caller ends.
  """
  @spec acquire(String.t(), GenServer.server()) :: :ok | {:error, :unavailable}
  def acquire(user_uuid, server \\ __MODULE__) do
    GenServer.call(server, {:acquire, user_uuid}, Bounds.get(:queue_wait_ms) + 5_000)
  catch
    :exit, _not_running_or_stuck -> {:error, :unavailable}
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{active: %{}, queue: []}}

  @impl GenServer
  def handle_call({:acquire, user}, {pid, _tag} = from, state) do
    mon = Process.monitor(pid)

    cond do
      grantable?(state, user) ->
        {:reply, :ok, put_in(state.active[mon], user)}

      Bounds.get(:queue_wait_ms) == 0 or length(state.queue) >= Bounds.get(:queued_jobs) ->
        Process.demonitor(mon, [:flush])
        {:reply, {:error, :unavailable}, state}

      true ->
        timer = Process.send_after(self(), {:expire, mon}, Bounds.get(:queue_wait_ms))
        entry = %{mon: mon, from: from, user: user, timer: timer}
        {:noreply, %{state | queue: state.queue ++ [entry]}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, mon, :process, _pid, _reason}, state) do
    state = %{state | active: Map.delete(state.active, mon)}

    case Enum.find(state.queue, &(&1.mon == mon)) do
      nil -> {:noreply, dispatch(state)}
      entry -> {:noreply, state |> drop(entry) |> dispatch()}
    end
  end

  def handle_info({:expire, mon}, state) do
    case Enum.find(state.queue, &(&1.mon == mon)) do
      nil ->
        {:noreply, state}

      entry ->
        Process.demonitor(mon, [:flush])
        GenServer.reply(entry.from, {:error, :unavailable})
        {:noreply, drop(state, entry)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, entry) do
    Process.cancel_timer(entry.timer)
    %{state | queue: Enum.reject(state.queue, &(&1.mon == entry.mon))}
  end

  # The waiting, in turn: the first that may take a place takes it; one whose
  # user has their share already is passed over, not blocking those behind.
  defp dispatch(state) do
    case Enum.find(state.queue, &grantable?(state, &1.user)) do
      nil ->
        state

      entry ->
        GenServer.reply(entry.from, :ok)
        state = drop(state, entry)
        dispatch(put_in(state.active[entry.mon], entry.user))
    end
  end

  defp grantable?(state, user) do
    map_size(state.active) < Bounds.get(:concurrent_jobs) and
      Enum.count(state.active, fn {_mon, held_by} -> held_by == user end) <
        Bounds.get(:jobs_per_user)
  end
end
