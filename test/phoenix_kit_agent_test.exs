defmodule PhoenixKitAgentTest do
  use ExUnit.Case, async: true

  # `function_exported?/3` answers false for a module that is merely not
  # loaded, so load it before asserting on callbacks.
  setup_all do
    Code.ensure_loaded!(PhoenixKitAgent)
    :ok
  end

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitAgent.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      assert Keyword.get(PhoenixKitAgent.__info__(:attributes), :phoenix_kit_module) == [true]
    end
  end

  describe "identity" do
    test "module_key/0 is \"agent\"" do
      assert PhoenixKitAgent.module_key() == "agent"
    end

    test "module_name/0 is \"AI Agent\"" do
      assert PhoenixKitAgent.module_name() == "AI Agent"
    end

    test "required_modules/0 requires the ai module" do
      assert PhoenixKitAgent.required_modules() == ["ai"]
    end

    test "version/0 is the mix.exs version" do
      assert PhoenixKitAgent.version() == Mix.Project.config()[:version]
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitAgent, :enable_system, 0)
      assert function_exported?(PhoenixKitAgent, :disable_system, 0)
    end
  end
end
