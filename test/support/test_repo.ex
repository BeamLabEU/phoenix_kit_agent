defmodule PhoenixKitAgent.Test.Repo do
  @moduledoc """
  Test-only Ecto repo for integration tests.

  Configured in `config/test.exs`, started by `test_helper.exs`.
  Uses `Ecto.Adapters.SQL.Sandbox` for transaction-based test isolation.
  """
  use Ecto.Repo,
    otp_app: :phoenix_kit_agent,
    adapter: Ecto.Adapters.Postgres
end
