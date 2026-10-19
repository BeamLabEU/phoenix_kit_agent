defmodule PhoenixKitAgent.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Uses `PhoenixKitAgent.Test.Repo` with SQL Sandbox for per-test isolation.
  Tests using this case are tagged `:integration`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitAgent.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAgent.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
