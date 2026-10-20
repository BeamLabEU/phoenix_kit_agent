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

      import PhoenixKitAgent.DataCase, only: [errors_on: 1]
      import PhoenixKitAgent.Fixtures

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

  @doc "A changeset's errors as `%{field => [message]}`."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
