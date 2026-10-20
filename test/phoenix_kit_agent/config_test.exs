defmodule PhoenixKitAgent.ConfigTest do
  @moduledoc """
  The module settings (`agent_*`, spec §5.6): their defaults (spec §14 В11), how
  a stored value is read, and the form that saves the defaults.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitAgent.Config

  describe "defaults" do
    test "the limits are $1 a day, $10 a month, 200 turns, 20 MB files, 5 per message" do
      assert Config.limit_defaults() == %{
               daily_cost_limit_micro_usd: 1_000_000,
               monthly_cost_limit_micro_usd: 10_000_000,
               daily_turn_limit: 200,
               max_attachment_mb: 20,
               max_attachments_per_message: 5
             }
    end

    test "the turn: 8 tool rounds, 300 s, 12 000 characters of a tool result" do
      assert Config.max_tool_rounds() == 8
      assert Config.turn_deadline_s() == 300
      assert Config.tool_result_chars() == 12_000
      assert Config.history_chars() > 0
    end

    test "nothing chosen: no endpoints, no prompt, no watchers, no captured bodies" do
      assert Config.default_endpoint_uuid() == nil
      assert Config.vision_endpoint_uuid() == nil
      assert Config.system_prompt() == nil
      assert Config.limit_watchers() == []
      assert Config.capture_ai_content?() == false
    end
  end

  describe "reading stored values" do
    test "a stored limit is read, a broken or negative one is the default" do
      Settings.update_setting("agent_daily_turn_limit", "50")
      assert Config.limit_defaults().daily_turn_limit == 50

      Settings.update_setting("agent_daily_turn_limit", "lots")
      assert Config.limit_defaults().daily_turn_limit == 200

      Settings.update_setting("agent_daily_turn_limit", "-3")
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "a limit of 0 is kept: it blocks" do
      Settings.update_setting("agent_daily_cost_limit_micro_usd", "0")
      assert Config.limit_defaults().daily_cost_limit_micro_usd == 0
    end

    test "a technical value of 0 is the default: the turn would be impossible" do
      Settings.update_setting("agent_max_tool_rounds", "0")
      assert Config.max_tool_rounds() == 8
    end

    test "capture is on only for exactly true" do
      Settings.update_setting("agent_capture_ai_content", "yes")
      refute Config.capture_ai_content?()

      Settings.update_setting("agent_capture_ai_content", "true")
      assert Config.capture_ai_content?()
    end

    test "watchers are a JSON list of uuids; a broken entry or a repeat is dropped" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      Settings.update_json_setting("agent_limit_watchers", %{
        "uuids" => [a, "not-a-uuid", b, a, 42]
      })

      assert Config.limit_watchers() == [a, b]
    end

    test "remove_limit_watcher/1 takes one uuid out and leaves the rest" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      {:ok, _} = Config.put_limit_watchers([a, b], [])

      assert {:ok, _} = Config.remove_limit_watcher(a)
      assert Config.limit_watchers() == [b]

      assert {:ok, :unchanged} = Config.remove_limit_watcher(Ecto.UUID.generate())
      assert Config.limit_watchers() == [b]
    end
  end

  describe "the long settings: the module prompt and the watchers" do
    # Core keeps a string setting to 1000 characters; these are stored as
    # JSON, which has no such cap.
    test "a module prompt longer than 1000 characters is saved and read back" do
      user = user_fixture()
      prompt = String.duplicate("Answer in Estonian. ", 200)

      assert {:ok, _} = Config.put_system_prompt(prompt, actor_uuid: user.uuid)
      assert Config.system_prompt() == prompt

      assert {:ok, _} = Config.put_system_prompt("   ", [])
      assert Config.system_prompt() == nil
    end

    test "the module prompt loses its NUL characters and has a length cap" do
      assert {:ok, _} =
               Config.put_system_prompt("Be <<0>>brief." |> String.replace("<<0>>", <<0>>), [])

      assert Config.system_prompt() == "Be brief."

      too_long = String.duplicate("x", 16_001)
      assert {:error, %Ecto.Changeset{} = changeset} = Config.put_system_prompt(too_long, [])
      assert %{text: [_]} = errors_on(changeset)
      assert Config.system_prompt() == "Be brief."

      assert {:ok, _} = Config.put_system_prompt(String.duplicate("x", 16_000), [])
    end

    test "more watchers than a string setting holds are saved and read back" do
      uuids = for _ <- 1..60, do: Ecto.UUID.generate()

      assert {:ok, _} = Config.put_limit_watchers(uuids ++ [hd(uuids)], [])
      assert Config.limit_watchers() == uuids
    end

    test "a watcher that is not a uuid is refused, nothing is saved" do
      assert {:error, :invalid_uuid} = Config.put_limit_watchers([Ecto.UUID.generate(), "x"], [])
      assert Config.limit_watchers() == []
    end
  end

  describe "the defaults form" do
    test "shows money in dollars" do
      form = Config.defaults_form_values()

      assert form["daily_cost_limit_usd"] == "1"
      assert form["monthly_cost_limit_usd"] == "10"
      assert form["daily_turn_limit"] == "200"
    end

    test "saves dollars as micro-dollars, with a comma or a dot" do
      user = user_fixture()

      params = %{
        Config.defaults_form_values()
        | "daily_cost_limit_usd" => "2,5",
          "monthly_cost_limit_usd" => "12.25",
          "daily_turn_limit" => "100",
          "max_tool_rounds" => "6"
      }

      assert {:ok, _} = Config.save_defaults(params, actor_uuid: user.uuid)

      assert Config.limit_defaults().daily_cost_limit_micro_usd == 2_500_000
      assert Config.limit_defaults().monthly_cost_limit_micro_usd == 12_250_000
      assert Config.limit_defaults().daily_turn_limit == 100
      assert Config.max_tool_rounds() == 6
    end

    test "refuses what is not a number, a negative limit, or a value out of range, and saves nothing" do
      params = %{
        Config.defaults_form_values()
        | "daily_cost_limit_usd" => "-1",
          "daily_turn_limit" => "many",
          "max_tool_rounds" => "0"
      }

      assert {:error, changeset} = Config.save_defaults(params, [])

      assert %{daily_cost_limit_usd: [_], daily_turn_limit: [_], max_tool_rounds: [_]} =
               errors_on(changeset)

      assert Config.limit_defaults().daily_cost_limit_micro_usd == 1_000_000
      assert Config.limit_defaults().daily_turn_limit == 200
    end

    test "a value left at its built-in default is not stored" do
      params = %{Config.defaults_form_values() | "daily_turn_limit" => "150"}

      assert {:ok, ["agent_daily_turn_limit"]} = Config.save_defaults(params, [])
      assert Settings.get_setting("agent_daily_cost_limit_micro_usd", nil) in [nil, ""]
    end

    test "a write that fails half-way leaves every setting as it was" do
      # The keys are written in key order; the second one is refused by the
      # database after the first was written.
      Repo.query!("""
      CREATE FUNCTION pg_temp.agent_refuse_rounds() RETURNS trigger AS $$
      BEGIN
        IF NEW.key = 'agent_max_tool_rounds' THEN RAISE EXCEPTION 'refused'; END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER agent_refuse_rounds BEFORE INSERT OR UPDATE ON phoenix_kit_settings
      FOR EACH ROW EXECUTE FUNCTION pg_temp.agent_refuse_rounds()
      """)

      params = %{
        Config.defaults_form_values()
        | "daily_turn_limit" => "150",
          "max_tool_rounds" => "6"
      }

      assert {:error, :not_saved} = Config.save_defaults(params, [])
      assert Settings.get_setting("agent_daily_turn_limit", nil) in [nil, ""]
      assert Config.limit_defaults().daily_turn_limit == 200
      assert Config.max_tool_rounds() == 8
    end

    test "a sub-micro-dollar fraction is refused, not rounded" do
      params = %{Config.defaults_form_values() | "daily_cost_limit_usd" => "0.0000001"}

      assert {:error, changeset} = Config.save_defaults(params, [])
      assert %{daily_cost_limit_usd: [_]} = errors_on(changeset)
    end
  end
end
