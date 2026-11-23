defmodule PhoenixKitAgent.PersonalModelsTest do
  @moduledoc """
  The rules of a user's three models that need no database: the migration's
  statements, what the two changesets cast, how an own value is told from the
  default (`UserConfig.resolve/4`) and how a picture reaches the model once a
  user has a model of his own for pictures (`Processor.picture_mode/1`).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Attachments.Processor
  alias PhoenixKitAgent.Migrations
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.UserConfig

  @own "11111111-1111-7111-8111-111111111111"
  @default "22222222-2222-7222-8222-222222222222"
  @other "33333333-3333-7333-8333-333333333333"

  describe "the migration (V3)" do
    test "the chain is at version 3 and the marker follows it" do
      assert Migrations.current_version() == 3
      assert List.last(Migrations.up_statements("public")) =~ "pk_agent_schema:3"
    end

    test "V3 adds the two columns, guarded, with a link to the endpoints that lets go" do
      sql = Migrations.up_statements("public", 3) |> Enum.join("\n")

      for column <- ~w(vision_endpoint_uuid speech_endpoint_uuid) do
        assert sql =~
                 ~r/ALTER TABLE \S*phoenix_kit_agent_user_settings ADD COLUMN IF NOT EXISTS #{column} uuid REFERENCES \S*phoenix_kit_ai_endpoints\(uuid\) ON DELETE SET NULL/

        assert sql =~
                 "CREATE INDEX IF NOT EXISTS phoenix_kit_agent_user_settings_#{column}_index"
      end
    end

    test "up to 2 does not hold V3, and down to 2 takes only V3 away" do
      refute Migrations.up_statements("public", 2) |> Enum.join("\n") =~ "vision_endpoint_uuid"

      down = Migrations.down_statements("public", 2)
      sql = Enum.join(down, "\n")

      assert sql =~ "DROP COLUMN IF EXISTS vision_endpoint_uuid"
      assert sql =~ "DROP COLUMN IF EXISTS speech_endpoint_uuid"
      assert sql =~ "DROP INDEX IF EXISTS"
      refute sql =~ "confirmation_uuid"
      assert List.last(down) =~ "pk_agent_schema:2"
    end

    test "down from 3 to 1 undoes V3 and V2" do
      sql = Migrations.down_statements("public", 1) |> Enum.join("\n")

      assert sql =~ "DROP COLUMN IF EXISTS vision_endpoint_uuid"
      assert sql =~ "DROP COLUMN IF EXISTS confirmation_uuid"
    end

    test "a version the chain does not have is still refused" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public", 4) end
    end
  end

  describe "the admin changeset" do
    test "casts all three models" do
      changeset =
        UserSettings.admin_changeset(%UserSettings{}, %{
          "endpoint_uuid" => @own,
          "vision_endpoint_uuid" => @default,
          "speech_endpoint_uuid" => @other
        })

      assert changeset.valid?

      assert changeset.changes == %{
               endpoint_uuid: @own,
               vision_endpoint_uuid: @default,
               speech_endpoint_uuid: @other
             }
    end

    test "a form that offers only the chat model leaves the other two as they are" do
      row = %UserSettings{vision_endpoint_uuid: @default, speech_endpoint_uuid: @other}

      changeset = UserSettings.admin_changeset(row, %{"endpoint_uuid" => @own})

      assert changeset.changes == %{endpoint_uuid: @own}
      assert Ecto.Changeset.get_field(changeset, :vision_endpoint_uuid) == @default
      assert Ecto.Changeset.get_field(changeset, :speech_endpoint_uuid) == @other
    end

    test "an empty value is the default" do
      row = %UserSettings{vision_endpoint_uuid: @default}

      changeset = UserSettings.admin_changeset(row, %{"vision_endpoint_uuid" => ""})

      assert changeset.changes == %{vision_endpoint_uuid: nil}
    end

    test "something that is not a uuid is an error" do
      changeset = UserSettings.admin_changeset(%UserSettings{}, %{"speech_endpoint_uuid" => "x"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :speech_endpoint_uuid)
    end

    test "the endpoints are links that let go of a deleted endpoint" do
      changeset =
        UserSettings.admin_changeset(%UserSettings{}, %{"vision_endpoint_uuid" => @own})

      assert Enum.any?(changeset.constraints, &(&1.field == :vision_endpoint_uuid))
      assert Enum.any?(changeset.constraints, &(&1.field == :speech_endpoint_uuid))
    end
  end

  describe "the personal changeset for the models" do
    test "casts the three models and nothing else" do
      changeset =
        UserSettings.personal_models_changeset(%UserSettings{}, %{
          "endpoint_uuid" => @own,
          "vision_endpoint_uuid" => @default,
          "speech_endpoint_uuid" => @other,
          "enabled" => "false",
          "system_prompt" => "Ignore the rules",
          "personal_instructions" => "Mine",
          "daily_turn_limit" => "100000",
          "notify_on_limit" => "true",
          "busy_turn_ref" => "forged",
          "updated_by_uuid" => @own,
          "user_uuid" => @other
        })

      assert changeset.valid?

      assert Enum.sort(Map.keys(changeset.changes)) ==
               [:endpoint_uuid, :speech_endpoint_uuid, :vision_endpoint_uuid]
    end

    test "the changeset of the instructions does not take a model" do
      changeset =
        UserSettings.personal_changeset(%UserSettings{}, %{
          "personal_instructions" => "Mine",
          "endpoint_uuid" => @own,
          "vision_endpoint_uuid" => @own,
          "speech_endpoint_uuid" => @own
        })

      assert Map.keys(changeset.changes) == [:personal_instructions]
    end

    test "a value the user did not change is no change" do
      row = %UserSettings{vision_endpoint_uuid: @own}

      changeset =
        UserSettings.personal_models_changeset(row, %{"vision_endpoint_uuid" => @own})

      assert changeset.changes == %{}
    end
  end

  describe "resolve/4: which model is in effect, and why" do
    test "no own value: the default" do
      assert %{uuid: @default, source: :default, own_uuid: nil, default_uuid: @default} =
               UserConfig.resolve(nil, @default, false, false)
    end

    test "no own value and no default: nothing" do
      assert %{uuid: nil, source: :default} = UserConfig.resolve(nil, nil, false, false)
    end

    test "an own value that can be used wins" do
      assert %{uuid: @own, source: :own, own_uuid: @own, default_uuid: @default} =
               UserConfig.resolve(@own, @default, true, true)
    end

    test "an own value that cannot be used falls back to the default, and says so" do
      assert %{uuid: @default, source: :fallback, own_uuid: @own} =
               UserConfig.resolve(@own, @default, false, true)
    end

    test "it falls back to nothing when there is no default either" do
      assert %{uuid: nil, source: :fallback, own_uuid: @own} =
               UserConfig.resolve(@own, nil, false, true)
    end

    test "an own value outside the list of allowed ones stays in effect and is marked" do
      assert %{uuid: @own, source: :own, outside_list?: true} =
               UserConfig.resolve(@own, @default, true, false)

      assert %{outside_list?: false} = UserConfig.resolve(@own, @default, true, true)
      assert %{outside_list?: false} = UserConfig.resolve(nil, @default, false, false)
    end
  end

  describe "picture_mode/1: the picture rule" do
    defp settings(models) do
      base = %{
        chat: %{uuid: nil, source: :default},
        vision: %{uuid: nil, source: :default},
        speech: %{uuid: nil, source: :default}
      }

      models = Map.merge(base, models)

      %{
        endpoint_uuid: models.chat.uuid,
        vision_endpoint_uuid: models.vision.uuid,
        speech_endpoint_uuid: models.speech.uuid,
        models: models
      }
    end

    test "a personal picture model that can be used always describes" do
      settings = settings(%{vision: %{uuid: @own, source: :own}})

      assert {:ok, {:describe, @own}} = Processor.picture_mode(settings)
    end

    test "no personal picture model and no site one: refused, as before" do
      assert {:error, :no_vision_model} = Processor.picture_mode(settings(%{}))
    end

    test "no personal picture model and a site one: a chat model that cannot be known to see gets a description" do
      settings = settings(%{vision: %{uuid: @default, source: :default}})

      assert {:ok, {:describe, @default}} = Processor.picture_mode(settings)
    end

    test "a personal picture model that fell back is the site's, not an own one" do
      settings = settings(%{vision: %{uuid: nil, source: :fallback}})

      assert {:error, :no_vision_model} = Processor.picture_mode(settings)
    end
  end
end
