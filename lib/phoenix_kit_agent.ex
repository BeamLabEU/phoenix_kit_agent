defmodule PhoenixKitAgent do
  @moduledoc """
  AI agent module for PhoenixKit.

  A personal assistant inside a PhoenixKit application: per-user chats kept
  in the database, files attached to messages, a managed system prompt, and a
  model-and-tools loop over the PhoenixKit API registry. Model calls, endpoints,
  credentials, budget and the request journal come from `phoenix_kit_ai`.

  ## System Management

  - `enabled?/0` - Check if the agent module is enabled (default: off)
  - `enable_system/0` - Enable the agent module
  - `disable_system/0` - Disable the agent module

  ## Permissions

  - `agent` — use the assistant.
  - `agent.manage` — the module defaults, other users' settings and spending.
    Core gives every module sub-key to the Admin role automatically, so Admin
    holds `agent.manage` from the first boot; that is accepted (spec §8).

  There is deliberately no `agent.view_all`: auto-granted to Admin, it would
  open every user's chats — with the customer data their tool results hold —
  to every Admin.

  ## Data

  Tables come from the module's own migration chain
  (`PhoenixKitAgent.Migrations`); attachment bytes live in a hidden Storage
  library (`PhoenixKitAgent.Library`); module settings are read through
  `PhoenixKitAgent.Config`. Deleting a user runs
  `PhoenixKitAgent.UserDeletion` first.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Turns.Runner

  @enabled_key "agent_enabled"

  # Single-sourced from mix.exs so a release bump touches one place only.
  @version Mix.Project.config()[:version]

  @doc """
  Returns whether the agent module is enabled. Defaults to `false`, including
  when the setting cannot be read.
  """
  @impl PhoenixKit.Module
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  rescue
    _ -> false
  catch
    # `Settings.get_boolean_setting/2` can hit a shutting-down pool and exit on
    # `DBConnection.Holder.checkout/3`; the callback contract is "false as
    # fallback", which includes process exits.
    :exit, _ -> false
  end

  @doc """
  Enables the agent module.
  """
  @impl PhoenixKit.Module
  @spec enable_system() :: {:ok, term()} | {:error, term()}
  def enable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, true, module_key())
  end

  @doc """
  Disables the agent module.
  """
  @impl PhoenixKit.Module
  @spec disable_system() :: {:ok, term()} | {:error, term()}
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, module_key())
  end

  @impl PhoenixKit.Module
  def module_key, do: "agent"

  @impl PhoenixKit.Module
  def module_name, do: "AI Agent"

  @impl PhoenixKit.Module
  def required_modules, do: ["ai"]

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitAgent.Migrations

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "AI Agent",
      icon: "hero-sparkles",
      description: "Use the AI assistant, with the rights of one's own session",
      gettext_backend: PhoenixKitAgent.Gettext,
      sub_permissions: [
        %{
          key: "manage",
          label: "Manage the AI assistant",
          description:
            "Edit the module defaults and other users' assistant settings, and see everyone's spending"
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_agent,
        label: "AI Agent",
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-sparkles",
        path: "agent",
        priority: 650,
        level: :admin,
        permission: "agent.manage",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true
      ),
      Tab.new!(
        id: :admin_agent_users,
        label: "Users",
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-users",
        path: "agent/users",
        priority: 651,
        level: :admin,
        permission: "agent.manage",
        parent: :admin_agent,
        match: :exact,
        live_view: {PhoenixKitAgent.Web.UsersLive, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_agent,
        label: "AI Agent",
        gettext_backend: PhoenixKitAgent.Gettext,
        icon: "hero-sparkles",
        path: "agent",
        priority: 935,
        level: :admin,
        parent: :admin_settings,
        permission: "agent.manage",
        match: :exact,
        live_view: {PhoenixKitAgent.Web.SettingsLive, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def children, do: [PhoenixKitAgent.Turns.Supervisor]

  @doc """
  The `phoenix_kit_ai` usage sink: a request row whose `attribution` names an
  assistant message (`"agent_message_uuid"`) is linked to it
  (`messages.ai_request_uuid`). See `PhoenixKitAgent.Turns.Runner`.
  """
  @spec handle_ai_usage(struct()) :: :ok
  def handle_ai_usage(request), do: Runner.record_usage(request)

  @doc """
  Before a user row is deleted: removes their attachment files from the
  module's hidden library (only files nothing else uses), their folder there,
  and their uuid from other users' notice lists and from the limit watchers.
  Their rows in the module's tables go with the user (`ON DELETE CASCADE`).
  See `PhoenixKitAgent.UserDeletion`.
  """
  @impl PhoenixKit.Module
  def before_user_delete(user_uuid), do: PhoenixKitAgent.UserDeletion.run(user_uuid)
end
