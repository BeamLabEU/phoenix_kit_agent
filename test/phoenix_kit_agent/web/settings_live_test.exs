defmodule PhoenixKitAgent.Web.SettingsLiveTest do
  @moduledoc """
  Settings → AI Agent: the module defaults, open to `agent.manage` only — on
  mount and on every save, whatever the route gate let through.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, RoleAssignment, Roles}
  alias PhoenixKitAgent.Config

  @path "/en/admin/settings/agent"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    :ok
  end

  describe "with agent.manage" do
    setup %{conn: conn} do
      manager = user_with(["agent", "agent.manage"], "manager")
      %{conn: log_in(conn, manager), manager: manager}
    end

    test "shows the defaults, money in dollars", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#agent-settings-form")

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[daily_cost_limit_usd]'][value='1']"
             )

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[monthly_cost_limit_usd]'][value='10']"
             )

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[daily_turn_limit]'][value='200']"
             )

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[max_attachment_mb]'][value='20']"
             )

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[max_attachments_per_message]'][value='5']"
             )
    end

    test "a default model that reports no cost: money is marked as not counted", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#agent-settings-money-off")

      direct = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", direct.uuid)

      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#agent-settings-money-off", "only the turn limit")

      counted = endpoint_fixture()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", counted.uuid)

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#agent-settings-money-off")
    end

    test "saves the defaults, with who saved them in the settings history", %{
      conn: conn,
      manager: manager
    } do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#agent-settings-form",
        settings: %{daily_cost_limit_usd: "2,5", daily_turn_limit: "150"}
      )
      |> render_submit()

      assert has_element?(view, "#flash-info")
      assert Config.limit_defaults().daily_cost_limit_micro_usd == 2_500_000
      assert Config.limit_defaults().daily_turn_limit == 150

      assert [entry] =
               Repo.all(
                 from(a in PhoenixKit.Activity.Entry,
                   where: fragment("?->>'key' = ?", a.metadata, "agent_daily_turn_limit")
                 )
               )

      assert entry.actor_uuid == manager.uuid
    end

    test "an invalid value is shown as an error and nothing is saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#agent-settings-form", settings: %{daily_turn_limit: "lots"})
      |> render_submit()

      assert has_element?(view, "#agent-settings-form p.text-error")
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "a save the database refuses keeps the form as typed and says nothing was saved",
         %{conn: conn} do
      Repo.query!("""
      CREATE FUNCTION pg_temp.agent_refuse_settings() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'refused'; END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER agent_refuse_settings BEFORE INSERT OR UPDATE ON phoenix_kit_settings
      FOR EACH ROW EXECUTE FUNCTION pg_temp.agent_refuse_settings()
      """)

      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#agent-settings-form", settings: %{daily_turn_limit: "150"})
      |> render_submit()

      assert has_element?(view, "#flash-error")

      assert has_element?(
               view,
               "#agent-settings-form input[name='settings[daily_turn_limit]'][value='150']"
             )

      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "an event without the form's fields changes nothing and does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      render_hook(view, "save", %{})
      render_hook(view, "validate", %{"other" => "x"})
      render_hook(view, "validate", %{"settings" => "x"})
      render_hook(view, "save", %{"settings" => ["x"]})

      assert has_element?(view, "#agent-settings-form")
      assert Config.limit_defaults().daily_turn_limit == 200
    end
  end

  describe "agent_capture_ai_content: the Owner's switch" do
    defp owner_user, do: owner_fixture()

    # A user of the real Admin role, which holds `agent.manage` as core
    # grants it to Admin (the test database has not seen this module before).
    defp admin_user do
      _ = owner_fixture()
      user = user_fixture("admin")
      {:ok, _} = Roles.assign_role(user, "Admin")
      admin = Roles.get_role_by_name("Admin")

      for key <- ["agent", "agent.manage"],
          do: {:ok, _} = Permissions.grant_permission(admin.uuid, key)

      user
    end

    # Core refuses to hand out Owner by hand; the assignment is written as
    # the first-user rule does.
    defp owner_assignment(user, :insert) do
      owner = Roles.get_role_by_name("Owner")
      Repo.insert!(%RoleAssignment{user_uuid: user.uuid, role_uuid: owner.uuid})
    end

    defp owner_assignment(user, :delete) do
      owner = Roles.get_role_by_name("Owner")

      Repo.delete_all(
        from(a in RoleAssignment, where: a.user_uuid == ^user.uuid and a.role_uuid == ^owner.uuid)
      )
    end

    defp capture_entries do
      Repo.all(
        from(a in PhoenixKit.Activity.Entry,
          where: fragment("?->>'key' = ?", a.metadata, "agent_capture_ai_content")
        )
      )
    end

    test "the Owner sees the switch with the warning, and turns it on and off", %{conn: conn} do
      owner = owner_user()
      {:ok, view, _html} = live(log_in(conn, owner), @path)

      assert has_element?(view, "#agent-capture-form")
      assert has_element?(view, "#agent-capture-note")
      refute Config.capture_ai_content?()

      view |> form("#agent-capture-form", capture: %{enabled: "true"}) |> render_submit()

      assert Config.capture_ai_content?()
      assert has_element?(view, "#flash-info")
      assert [entry] = capture_entries()
      assert entry.actor_uuid == owner.uuid

      view |> form("#agent-capture-form", capture: %{enabled: "false"}) |> render_submit()
      refute Config.capture_ai_content?()
    end

    test "an Admin with agent.manage sees the state but has no switch", %{conn: conn} do
      admin = admin_user()
      assert Scope.can?(scope_of(admin), "agent.manage")
      refute Scope.owner?(scope_of(admin))

      {:ok, view, _html} = live(log_in(conn, admin), @path)

      assert has_element?(view, "#agent-settings-form")
      assert has_element?(view, "#agent-capture-status")
      assert has_element?(view, "#agent-capture-note")
      refute has_element?(view, "#agent-capture-form")
    end

    test "a forged submit from an Admin changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(log_in(conn, admin_user()), @path)

      render_hook(view, "save_capture", %{"capture" => %{"enabled" => "true"}})

      assert has_element?(view, "#flash-error")
      refute Config.capture_ai_content?()
      assert capture_entries() == []
    end

    test "nor can the defaults form carry it", %{conn: conn} do
      {:ok, view, _html} = live(log_in(conn, admin_user()), @path)

      render_hook(view, "save", %{
        "settings" => %{"daily_turn_limit" => "150", "agent_capture_ai_content" => "true"},
        "capture" => %{"enabled" => "true"},
        "agent_capture_ai_content" => "true"
      })

      assert Config.limit_defaults().daily_turn_limit == 150
      refute Config.capture_ai_content?()
      assert capture_entries() == []
    end

    test "a page opened by an Owner who stopped being one changes nothing", %{conn: conn} do
      second = admin_user()
      owner_assignment(second, :insert)

      {:ok, view, _html} = live(log_in(conn, second), @path)
      assert has_element?(view, "#agent-capture-form")

      owner_assignment(second, :delete)

      view |> form("#agent-capture-form", capture: %{enabled: "true"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      refute Config.capture_ai_content?()
    end

    test "an Owner whose session acts as Admin does not switch it", %{conn: conn} do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")
      second = admin_user()
      owner_assignment(second, :insert)

      {conn, token} = log_in_session(conn, second)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#agent-capture-form")

      act_as(token, Roles.get_role_by_name("Admin"))

      view |> form("#agent-capture-form", capture: %{enabled: "true"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      refute Config.capture_ai_content?()
    end

    test "an event without the form's fields changes nothing and does not crash", %{conn: conn} do
      owner = owner_user()
      {:ok, view, _html} = live(log_in(conn, owner), @path)

      render_hook(view, "save_capture", %{})
      render_hook(view, "save_capture", %{"capture" => "x"})
      render_hook(view, "save_capture", %{"capture" => %{"enabled" => "maybe"}})

      assert has_element?(view, "#agent-capture-form")
      refute Config.capture_ai_content?()
    end
  end

  describe "without agent.manage" do
    test "the page does not open for a user who only uses the assistant", %{conn: conn} do
      conn = log_in(conn, user_with(["agent"], "user"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, @path)
      refute to =~ "settings/agent"
    end

    test "a save from a page opened before the right was taken away changes nothing", %{
      conn: conn
    } do
      manager = user_with(["agent", "agent.manage"], "manager")
      {:ok, view, _html} = live(log_in(conn, manager), @path)

      [role] =
        manager
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent.manage")

      view
      |> form("#agent-settings-form", settings: %{daily_turn_limit: "1"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Config.limit_defaults().daily_turn_limit == 200
      assert Settings.get_setting("agent_daily_turn_limit", nil) in [nil, ""]
    end

    test "a save after the session switched to a role without agent.manage changes nothing",
         %{conn: conn} do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")
      manager = user_with(["agent", "agent.manage"], "manager")
      {:ok, plain} = Roles.create_role(%{name: "AgentPlain#{System.unique_integer([:positive])}"})
      {:ok, _} = Permissions.grant_permission(plain.uuid, "agent")
      {:ok, _} = Roles.assign_role(manager, plain.name)

      {conn, token} = log_in_session(conn, manager)
      {:ok, view, _html} = live(conn, @path)
      act_as(token, plain)

      view
      |> form("#agent-settings-form", settings: %{daily_turn_limit: "1"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "nobody signed in is sent away", %{conn: conn} do
      assert {:error, {:live_redirect, _}} = live(conn, @path)
    end
  end
end
