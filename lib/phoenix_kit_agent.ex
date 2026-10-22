defmodule PhoenixKitAgent do
  @moduledoc """
  AI agent module for PhoenixKit.

  A personal assistant inside a PhoenixKit application: per-user chats kept
  in the database, files attached to messages, a managed system prompt, and a
  model-and-tools loop over the PhoenixKit API registry. Model calls, endpoints,
  credentials, budget and the request journal come from `phoenix_kit_ai`.

  This is the module skeleton. Chats, settings, permissions and the UI arrive
  in the next phases; for now the module only registers itself and can be
  switched on and off.

  ## System Management

  - `enabled?/0` - Check if the agent module is enabled (default: off)
  - `enable_system/0` - Enable the agent module
  - `disable_system/0` - Disable the agent module
  """

  use PhoenixKit.Module

  alias PhoenixKit.Settings

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
end
