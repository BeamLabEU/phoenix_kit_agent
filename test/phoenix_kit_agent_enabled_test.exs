defmodule PhoenixKitAgent.EnabledTest do
  use PhoenixKitAgent.DataCase, async: false

  describe "enabled?/0" do
    test "is false by default" do
      assert PhoenixKitAgent.enabled?() == false
    end

    test "round-trips true then false via enable_system/0 and disable_system/0" do
      assert {:ok, _} = PhoenixKitAgent.enable_system()
      assert PhoenixKitAgent.enabled?() == true

      assert {:ok, _} = PhoenixKitAgent.disable_system()
      assert PhoenixKitAgent.enabled?() == false
    end

    test "enabling stores the agent_enabled setting" do
      assert {:ok, _} = PhoenixKitAgent.enable_system()

      assert PhoenixKit.Settings.get_boolean_setting("agent_enabled", false) == true
    end
  end
end
