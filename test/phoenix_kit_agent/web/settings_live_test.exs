defmodule PhoenixKitAgent.Web.SettingsLiveTest do
  @moduledoc """
  Settings → AI Agent: the module defaults, open to `agent.manage` only — on
  mount and on every save, whatever the route gate let through.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
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

    test "nobody signed in is sent away", %{conn: conn} do
      assert {:error, {:live_redirect, _}} = live(conn, @path)
    end
  end
end
