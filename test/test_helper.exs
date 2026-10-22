# Test helper for PhoenixKitAgent.
#
# Level 1: Unit tests (pure functions, callbacks) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitAgent.DataCase)
#          need a real PostgreSQL database. `mix test` creates it through the
#          `test.setup` alias contract below; if it is unusable the run ABORTS —
#          it must not downgrade to "excluding :integration" and report green.
#
# First-time setup:
#
#   createdb phoenix_kit_agent_test      # or: mix test.setup
#
# The schema is built from core's versioned migrations via
# `PhoenixKit.Migration.ensure_current/2`, the same call a host app makes.
# This module has no tables of its own yet.
#
# The ONLY sanctioned way to run without a database is the explicit opt-in
#
#   PK_AGENT_SKIP_DB=1 mix test
#
# which excludes `:integration` and says so loudly.

# Elixir 1.19 does not auto-load modules from test support paths at
# test-helper time, so load them explicitly.
support_dir = Path.expand("support", __DIR__)

[
  {PhoenixKitAgent.Test.Repo, "test_repo.ex"},
  {PhoenixKitAgent.DataCase, "data_case.ex"}
]
|> Enum.each(fn {mod, file} ->
  Code.ensure_loaded?(mod) || Code.require_file(file, support_dir)
end)

alias PhoenixKitAgent.Test.Repo, as: TestRepo

db_config = Application.get_env(:phoenix_kit_agent, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_agent_test"
skip_db? = System.get_env("PK_AGENT_SKIP_DB") in ["1", "true"]

repo_available =
  if skip_db? do
    IO.puts("""

    PK_AGENT_SKIP_DB=1 — skipping database "#{db_name}", excluding :integration tests.
    This is a manual opt-out for a machine with no Postgres; do NOT set it in CI.
    """)

    false
  else
    # One classified connection attempt with the repo's OWN credentials, before
    # the pool starts (ships in core; a failure here is a real infrastructure
    # problem, not something to route around).
    case PhoenixKit.TestSupport.PostgresPreflight.check(db_config) do
      :ok ->
        :ok

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)

        raise """
        Cannot reach test database "#{db_name}" — see the preflight diagnostic above.
        Run: createdb #{db_name}, or set PK_AGENT_SKIP_DB=1 to run unit tests only.
        """
    end

    {:ok, _} = TestRepo.start_link()
    PhoenixKit.Migration.ensure_current(TestRepo, log: false)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
    true
  end

Application.put_env(:phoenix_kit_agent, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the Settings API.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

exclude = if skip_db?, do: [:integration], else: []
ExUnit.start(exclude: exclude)
