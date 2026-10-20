defmodule PhoenixKitAgent.MigrationsTest do
  @moduledoc """
  The module-owned chain, run as the real SQL inside the sandbox: the tables it
  builds, their foreign keys and the list index, a re-run, and a down/up round
  trip — through the statements and through `Ecto.Migrator` with the wrapper a
  host's generated migration uses.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Migrations
  alias PhoenixKitAgent.Test.SchemaMigration

  @tables ~w(
    phoenix_kit_agent_conversations
    phoenix_kit_agent_messages
    phoenix_kit_agent_attachments
    phoenix_kit_agent_user_settings
    phoenix_kit_agent_limit_events
  )

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp existing_tables do
    query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ANY($1) ORDER BY 1",
      [@tables]
    )
    |> List.flatten()
  end

  defp marker do
    case query("SELECT obj_description('public.phoenix_kit_agent_conversations'::regclass)") do
      [[marker]] -> marker
    end
  end

  # {child table, child column, parent table, ON DELETE action}
  defp foreign_keys do
    query("""
    SELECT c.conrelid::regclass::text, a.attname, c.confrelid::regclass::text, c.confdeltype
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.contype = 'f' AND c.conrelid::regclass::text LIKE 'phoenix_kit_agent_%'
    ORDER BY 1, 2
    """)
    |> Enum.map(fn [child, column, parent, action] -> {child, column, parent, action} end)
  end

  describe "the chain as built at boot" do
    test "is at the current version, with all five tables" do
      assert Migrations.current_version() == 1
      assert marker() == "pk_agent_schema:1"
      assert existing_tables() == Enum.sort(@tables)
      assert Migrations.migrated_version_runtime() == 1
    end

    test "user rows cascade, journal and endpoint links are set to null, files are set to null" do
      fks = foreign_keys()

      # "c" = CASCADE, "n" = SET NULL
      expected = [
        {"phoenix_kit_agent_attachments", "conversation_uuid", "phoenix_kit_agent_conversations",
         "c"},
        {"phoenix_kit_agent_attachments", "file_uuid", "phoenix_kit_files", "n"},
        {"phoenix_kit_agent_attachments", "message_uuid", "phoenix_kit_agent_messages", "c"},
        {"phoenix_kit_agent_attachments", "user_uuid", "phoenix_kit_users", "c"},
        {"phoenix_kit_agent_conversations", "user_uuid", "phoenix_kit_users", "c"},
        {"phoenix_kit_agent_limit_events", "user_uuid", "phoenix_kit_users", "c"},
        {"phoenix_kit_agent_messages", "ai_request_uuid", "phoenix_kit_ai_requests", "n"},
        {"phoenix_kit_agent_messages", "conversation_uuid", "phoenix_kit_agent_conversations",
         "c"},
        {"phoenix_kit_agent_user_settings", "endpoint_uuid", "phoenix_kit_ai_endpoints", "n"},
        {"phoenix_kit_agent_user_settings", "updated_by_uuid", "phoenix_kit_users", "n"},
        {"phoenix_kit_agent_user_settings", "user_uuid", "phoenix_kit_users", "c"}
      ]

      assert fks == expected
    end

    test "the chat list has its index: by user and status, newest first" do
      [[indexdef]] =
        query(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_agent_conversations_user_list_index'"
        )

      assert indexdef =~ "(user_uuid, status, last_message_at DESC)"
    end

    test "one limit notice per user, kind and period" do
      [[indexdef]] =
        query(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'phoenix_kit_agent_limit_events_user_kind_period_index'"
        )

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "(user_uuid, limit_kind, period_key)"
    end
  end

  describe "up_statements/2 and down_statements/2" do
    test "a second up changes nothing and does not fail" do
      run(Migrations.up_statements("public"))
      run(Migrations.up_statements("public"))

      assert marker() == "pk_agent_schema:1"
      assert existing_tables() == Enum.sort(@tables)
    end

    test "down to 0 drops every table of the module, and up builds them again" do
      run(Migrations.down_statements("public", 0))
      assert existing_tables() == []

      run(Migrations.up_statements("public"))
      assert existing_tables() == Enum.sort(@tables)
      assert marker() == "pk_agent_schema:1"
    end

    test "down does not touch a table that is not the module's" do
      run(Migrations.down_statements("public", 0))

      assert [[_]] =
               query(
                 "SELECT 1 FROM information_schema.tables WHERE table_name = 'phoenix_kit_users'"
               )
    end

    test "a version the chain does not have is refused in both directions" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 2) end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public", 2) end
    end

    test "an invalid prefix is refused" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("bad prefix; DROP", 1) end
    end

    test "up to 0 applies nothing" do
      assert Migrations.up_statements("public", 0) == []
    end
  end

  describe "through Ecto.Migrator, as a host's generated migration runs it" do
    # The sandbox owns the one connection the test may use; the migrator's lock
    # would want a second one. The version is past every version core's chain
    # recorded, so the migrator does not warn about running an older one.
    @migrator_opts [log: false, migration_lock: false]

    test "down then up again" do
      version = 9_000_000_000_000_000 + System.unique_integer([:positive])

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert :ok = Ecto.Migrator.down(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == []
      assert Migrations.migrated_version_runtime() == 0

      assert :ok = Ecto.Migrator.up(Repo, version, SchemaMigration, @migrator_opts)
      assert existing_tables() == Enum.sort(@tables)
      assert Migrations.migrated_version_runtime() == 1
    end
  end
end
