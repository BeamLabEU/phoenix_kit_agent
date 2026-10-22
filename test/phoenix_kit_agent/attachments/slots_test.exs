defmodule PhoenixKitAgent.Attachments.SlotsTest do
  @moduledoc """
  The places for work on files on a node: a few at a time, one user not taking
  them all, the others waiting a short while for a free place.
  """

  # The slots are one process of the node and the limits are application
  # environment: not for parallel tests.
  use ExUnit.Case, async: false

  alias PhoenixKitAgent.Attachments.Slots

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:phoenix_kit_agent, :attachment_limits)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_agent, :attachment_limits, previous),
        else: Application.delete_env(:phoenix_kit_agent, :attachment_limits)
    end)

    limits(concurrent_jobs: 2, jobs_per_user: 1, queue_wait_ms: 2_000, queued_jobs: 2)
    :ok
  end

  defp limits(opts), do: Application.put_env(:phoenix_kit_agent, :attachment_limits, opts)

  # A process that asks for a place for `user`, tells the test the answer, and
  # holds the place until told to go. Linked, so that a failed test leaves no
  # place held.
  defp client(user) do
    test = self()

    spawn_link(fn ->
      send(test, {:acquired, self(), Slots.acquire(user)})

      receive do
        :release -> :ok
      end
    end)
  end

  defp holder(user) do
    pid = client(user)
    {pid, receive_result(pid)}
  end

  defp receive_result(pid) do
    receive do
      {:acquired, ^pid, result} -> result
    after
      5_000 -> :no_answer
    end
  end

  defp release(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp spawn_waiter(user) do
    pid = client(user)
    # The call is in the server's queue once the server answers anything.
    _ = :sys.get_state(Slots)
    pid
  end

  test "places are given up to concurrent_jobs, to users within their share" do
    {a, :ok} = holder("u1")
    {b, :ok} = holder("u2")

    limits(concurrent_jobs: 2, jobs_per_user: 1, queue_wait_ms: 0)
    {c, {:error, :unavailable}} = holder("u3")

    for pid <- [a, b, c], do: release(pid)
  end

  test "one user cannot take the places of the others" do
    {a, :ok} = holder("u1")

    # u1 has its share; the second place is for another user, not for u1.
    waiter = spawn_waiter("u1")
    {b, :ok} = holder("u2")

    refute_receive {:acquired, ^waiter, _}, 100

    # u1 gets in as soon as its own first job is done.
    release(a)
    assert_receive {:acquired, ^waiter, :ok}, 2_000

    release(b)
  end

  test "a file waits for a place and takes it when one is free, in turn" do
    {a, :ok} = holder("u1")
    {b, :ok} = holder("u2")

    first = spawn_waiter("u3")
    second = spawn_waiter("u4")
    refute_receive {:acquired, _, _}, 100

    release(a)
    assert_receive {:acquired, ^first, :ok}, 2_000
    refute_receive {:acquired, ^second, _}, 100

    release(b)
    assert_receive {:acquired, ^second, :ok}, 2_000
  end

  test "a file that waits longer than queue_wait_ms is unavailable" do
    {a, :ok} = holder("u1")
    {b, :ok} = holder("u2")
    limits(concurrent_jobs: 2, jobs_per_user: 1, queue_wait_ms: 50, queued_jobs: 2)

    waiter = spawn_waiter("u3")
    assert_receive {:acquired, ^waiter, {:error, :unavailable}}, 2_000

    release(a)
    release(b)
  end

  test "more waiting than queued_jobs is unavailable at once" do
    {a, :ok} = holder("u1")
    {b, :ok} = holder("u2")

    one = spawn_waiter("u3")
    two = spawn_waiter("u4")
    three = spawn_waiter("u5")

    assert_receive {:acquired, ^three, {:error, :unavailable}}, 1_000
    refute_receive {:acquired, ^one, _}, 100
    refute_receive {:acquired, ^two, _}, 100

    release(a)
    release(b)
    assert_receive {:acquired, ^one, :ok}, 2_000
    assert_receive {:acquired, ^two, :ok}, 2_000
  end

  test "a place of a process that dies is free again, and so is a place in the queue" do
    {a, :ok} = holder("u1")
    {b, :ok} = holder("u2")

    gone = spawn_waiter("u3")
    ref = Process.monitor(gone)
    Process.exit(gone, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gone, _}
    _ = :sys.get_state(Slots)
    waiter = spawn_waiter("u4")

    Process.exit(a, :kill)
    assert_receive {:acquired, ^waiter, :ok}, 2_000

    release(b)
  end

  test "where the slots are not running a file is unavailable, not a crash" do
    assert Slots.acquire("u1", :no_such_slots) == {:error, :unavailable}
  end
end
