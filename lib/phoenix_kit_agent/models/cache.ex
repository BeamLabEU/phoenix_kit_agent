defmodule PhoenixKitAgent.Models.Cache do
  @moduledoc """
  A small in-memory cache for `PhoenixKitAgent.Models`: the answer to "does
  this endpoint's model take images" costs a request to the provider's model
  listing, and it is asked on every picture and every turn that carries one.

  The table is owned by a process in the module's supervision tree
  (`PhoenixKitAgent.children/0`). Where that process is not running (a host
  that did not start the module's children) nothing is cached and every call
  goes through, which is slower and not wrong.
  """

  @table __MODULE__

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Agent, :start_link, [&create_table/0, [name: __MODULE__]]},
      type: :worker
    }
  end

  defp create_table, do: :ets.new(@table, [:named_table, :public, read_concurrency: true])

  @doc """
  The value kept for `key`, else `fun.()` — kept for `ttl_fun.(value)`
  milliseconds.
  """
  @spec fetch(term(), (term() -> non_neg_integer()), (-> value)) :: value when value: term()
  def fetch(key, ttl_fun, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {:ok, expires, value} when expires > now ->
        value

      _missing_or_stale ->
        value = fun.()
        put(key, now + ttl_fun.(value), value)
        value
    end
  end

  @doc "Forgets everything."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :none

      _table ->
        case :ets.lookup(@table, key) do
          [{^key, expires, value}] -> {:ok, expires, value}
          [] -> :none
        end
    end
  end

  defp put(key, expires, value) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, expires, value})
    :ok
  end
end
