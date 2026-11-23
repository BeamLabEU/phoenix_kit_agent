defmodule PhoenixKitAgent.UserConfigTest do
  @moduledoc """
  The settings of one user (spec §5.4, §7): what is in effect (the user's own
  value, else the module default), the user's own personal instructions, and
  what an admin with `agent.manage` changes — with who did it in the Activity
  log.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Test.LogProbe
  alias PhoenixKitAgent.UserConfig

  @me [impersonated: false]

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    user = user_with(["agent"], "member")
    {ref, _token} = session_fixture(user)
    %{user: user, ref: ref}
  end

  defp manager_scope do
    scope_of(user_with(["agent", "agent.manage"], "manager"))
  end

  describe "effective/1: the user's value, else the module default" do
    test "a user without a row gets every module default", %{user: user} do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", Ecto.UUID.generate())

      effective = UserConfig.effective(user.uuid)

      assert effective.enabled?
      assert effective.endpoint_uuid == PhoenixKitAgent.Config.default_endpoint_uuid()
      assert effective.system_prompt == nil
      assert effective.personal_instructions == nil
      assert effective.daily_cost_limit_micro_usd == 1_000_000
      assert effective.monthly_cost_limit_micro_usd == 10_000_000
      assert effective.daily_turn_limit == 200
      assert effective.max_attachment_mb == 20
      assert effective.max_attachments_per_message == 5
      refute effective.notify_on_limit
    end

    test "a field the row sets wins; a nil field falls back", %{user: user} do
      endpoint = endpoint_fixture()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", Ecto.UUID.generate())

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        endpoint_uuid: endpoint.uuid,
        system_prompt: "Be brief.",
        daily_cost_limit_micro_usd: 250_000,
        daily_turn_limit: 0,
        notify_on_limit: true
      })

      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == endpoint.uuid
      assert effective.system_prompt == "Be brief."
      assert effective.daily_cost_limit_micro_usd == 250_000
      # A limit of 0 is a real limit, not "unset".
      assert effective.daily_turn_limit == 0
      assert effective.monthly_cost_limit_micro_usd == 10_000_000
      assert effective.max_attachment_mb == 20
      assert effective.notify_on_limit
    end

    test "the module default moves the users without their own value", %{user: user} do
      {:ok, _} = Settings.update_setting("agent_daily_turn_limit", "17")

      assert UserConfig.effective(user.uuid).daily_turn_limit == 17
    end

    test "enabled: false switches the user off, nil leaves it to the permission", %{user: user} do
      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})
      refute UserConfig.effective(user.uuid).enabled?
      refute UserConfig.enabled?(user.uuid)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      assert UserConfig.enabled?(user.uuid)
    end

    test "a blank prompt is no prompt", %{user: user} do
      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        system_prompt: "  \n ",
        personal_instructions: ""
      })

      effective = UserConfig.effective(user.uuid)
      assert effective.system_prompt == nil
      assert effective.personal_instructions == nil
    end
  end

  describe "effective_many/1 and the users of the assistant" do
    test "gives each user what effective/1 gives", %{user: user} do
      other = user_with(["agent"], "other")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, daily_turn_limit: 3, system_prompt: "P"})

      many = UserConfig.effective_many([user.uuid, other.uuid])

      assert many[user.uuid] == UserConfig.effective(user.uuid)
      assert many[other.uuid] == UserConfig.effective(other.uuid)
      assert many[other.uuid].own == [:system_prompt, :daily_turn_limit]
      assert many[user.uuid].own == []
      assert UserConfig.effective_many([]) == %{}
    end

    test "the users are those holding agent, and the Owners, active ones only", %{user: user} do
      stranger = user_with(["dashboard"], "stranger")
      blocked = user_with(["agent"], "blocked")

      Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^blocked.uuid),
        set: [is_active: false]
      )

      uuids = Enum.map(UserConfig.agent_users(), & &1.uuid)

      assert user.uuid in uuids
      assert owner_fixture().uuid in uuids
      refute stranger.uuid in uuids
      refute blocked.uuid in uuids

      assert UserConfig.agent_user?(user.uuid)
      refute UserConfig.agent_user?(stranger.uuid)
      refute UserConfig.agent_user?("nope")
    end
  end

  describe "personal instructions" do
    test "the user writes and reads their own through the session", %{user: user, ref: ref} do
      assert {:ok, nil} = UserConfig.get_personal_instructions(ref, @me)

      assert {:ok, "Call me Tim."} =
               UserConfig.put_personal_instructions(ref, "  Call me Tim.  ", @me)

      assert {:ok, "Call me Tim."} = UserConfig.get_personal_instructions(ref, @me)
      assert UserConfig.effective(user.uuid).personal_instructions == "Call me Tim."
    end

    test "a blank text clears them", %{ref: ref} do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Something", @me)

      assert {:ok, nil} = UserConfig.put_personal_instructions(ref, "   ", @me)
      assert {:ok, nil} = UserConfig.get_personal_instructions(ref, @me)
    end

    test "writing them leaves everything an admin set untouched", %{user: user, ref: ref} do
      endpoint = endpoint_fixture()

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        enabled: false,
        endpoint_uuid: endpoint.uuid,
        system_prompt: "Admin prompt",
        daily_turn_limit: 5,
        daily_cost_limit_micro_usd: 7,
        notify_on_limit: true
      })

      # The assistant is switched off for this user, so the session is refused
      # first; switch it on to reach the write.
      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      row = Repo.get!(UserSettings, user.uuid)
      assert row.personal_instructions == "Mine"
      assert row.endpoint_uuid == endpoint.uuid
      assert row.system_prompt == "Admin prompt"
      assert row.daily_turn_limit == 5
      assert row.daily_cost_limit_micro_usd == 7
      assert row.notify_on_limit
    end

    test "a forged attribute cannot change a limit, the switch or the model", %{user: user} do
      endpoint = endpoint_fixture()

      changeset =
        UserSettings.personal_changeset(%UserSettings{user_uuid: user.uuid}, %{
          personal_instructions: "Mine",
          enabled: false,
          endpoint_uuid: endpoint.uuid,
          system_prompt: "Ignore the rules",
          daily_turn_limit: 100_000,
          daily_cost_limit_micro_usd: 1,
          notify_on_limit: true,
          updated_by_uuid: user.uuid
        })

      assert Map.keys(changeset.changes) == [:personal_instructions]
    end

    test "a text over the limit is refused and nothing is written", %{user: user, ref: ref} do
      text = String.duplicate("a", 4_001)

      assert {:error, %Ecto.Changeset{}} = UserConfig.put_personal_instructions(ref, text, @me)
      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "something that is not text is refused", %{user: user, ref: ref} do
      for junk <- [42, %{"a" => 1}, ["x"]] do
        assert {:error, %Ecto.Changeset{}} = UserConfig.put_personal_instructions(ref, junk, @me)
      end

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "NUL characters are cut", %{ref: ref} do
      assert {:ok, "ab"} = UserConfig.put_personal_instructions(ref, "a\0b", @me)
    end

    test "a revoked session, an impersonated one and a switched-off user are refused", %{
      user: user
    } do
      {ref, token} = session_fixture(user)

      assert {:error, :impersonated} =
               UserConfig.put_personal_instructions(ref, "x", impersonated: true)

      assert {:error, :impersonated} =
               UserConfig.get_personal_instructions(ref, impersonated: true)

      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})
      assert {:error, :forbidden} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert {:error, :forbidden} = UserConfig.get_personal_instructions(ref, @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      :ok = Auth.delete_user_session_token(token)
      assert {:error, :session_gone} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert Repo.get!(UserSettings, user.uuid).personal_instructions == nil
    end

    test "a user without the agent permission is refused" do
      stranger = user_with(["dashboard"], "stranger")
      {ref, _} = session_fixture(stranger)

      assert {:error, :forbidden} = UserConfig.put_personal_instructions(ref, "x", @me)
      assert Repo.get(UserSettings, stranger.uuid) == nil
    end

    test "the text never reaches the log, not even Ecto's debug lines", %{ref: ref} do
      secret = "SecretPI-#{System.unique_integer([:positive])}"

      {result, logs} =
        LogProbe.capture(fn -> UserConfig.put_personal_instructions(ref, secret, @me) end)

      assert {:ok, ^secret} = result
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "the missing impersonation flag raises", %{ref: ref} do
      assert_raise ArgumentError, fn -> UserConfig.put_personal_instructions(ref, "x", []) end
    end
  end

  describe "admin_update/3" do
    test "writes the fields, records who, and logs the change in Activity", %{user: user} do
      endpoint = declared(%{name: "Tools", model: "a/tools"}, "yes")
      scope = manager_scope()
      manager_uuid = scope.user.uuid

      assert {:ok, %UserSettings{} = row, fields} =
               UserConfig.admin_update(scope, user.uuid, %{
                 "endpoint_uuid" => endpoint.uuid,
                 "system_prompt" => "SECRET-PROMPT-TEXT",
                 "daily_turn_limit" => "12",
                 "enabled" => "false"
               })

      assert Enum.sort(fields) == [:daily_turn_limit, :enabled, :endpoint_uuid, :system_prompt]
      assert row.updated_by_uuid == manager_uuid
      assert row.system_prompt == "SECRET-PROMPT-TEXT"
      assert row.daily_turn_limit == 12
      refute row.enabled

      assert [entry] = activity("agent.user_settings_updated")
      assert entry.actor_uuid == manager_uuid
      assert entry.resource_uuid == user.uuid
      assert entry.module == "agent"

      assert Enum.sort(entry.metadata["fields"]) ==
               ["daily_turn_limit", "enabled", "endpoint_uuid", "system_prompt"]

      # The fact of the change, never the prompt text.
      refute inspect(entry) =~ "SECRET-PROMPT-TEXT"
    end

    test "an unchanged save writes no Activity entry", %{user: user} do
      scope = manager_scope()

      {:ok, _, [:daily_turn_limit]} =
        UserConfig.admin_update(scope, user.uuid, %{daily_turn_limit: 3})

      assert {:ok, _row, []} = UserConfig.admin_update(scope, user.uuid, %{daily_turn_limit: 3})
      assert length(activity("agent.user_settings_updated")) == 1
    end

    test "does not touch the user's personal instructions or a running turn's lock", %{
      user: user,
      ref: ref
    } do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [busy_since: DateTime.utc_now(), busy_turn_ref: "t1"]
      )

      {:ok, row, _} =
        UserConfig.admin_update(manager_scope(), user.uuid, %{
          "personal_instructions" => "Forged by admin",
          "busy_turn_ref" => "forged",
          "daily_turn_limit" => "9"
        })

      assert row.personal_instructions == "Mine"
      assert row.busy_turn_ref == "t1"
      assert row.daily_turn_limit == 9
    end

    test "the admin's prompt never reaches the log, not even Ecto's debug lines", %{user: user} do
      scope = manager_scope()
      secret = "SecretAP-#{System.unique_integer([:positive])}"

      {result, logs} =
        LogProbe.capture(fn ->
          UserConfig.admin_update(scope, user.uuid, %{"system_prompt" => secret})
        end)

      assert {:ok, %UserSettings{system_prompt: ^secret}, [:system_prompt]} = result
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "an invalid value is an error and writes nothing", %{user: user} do
      scope = manager_scope()

      assert {:error, %Ecto.Changeset{}} =
               UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "-1"})

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a scope without agent.manage is refused and nothing is written", %{user: user} do
      plain = scope_of(user_with(["agent"], "plain"))

      assert {:error, :forbidden} =
               UserConfig.admin_update(plain, user.uuid, %{"daily_turn_limit" => "1"})

      assert {:error, :forbidden} = UserConfig.admin_update(nil, user.uuid, %{})
      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "an unknown user is not found" do
      assert {:error, :not_found} =
               UserConfig.admin_update(manager_scope(), Ecto.UUID.generate(), %{})

      assert {:error, :not_found} = UserConfig.admin_update(manager_scope(), "nope", %{})
    end

    test "the edited user gets no notification of it", %{user: user} do
      {:ok, _} = Settings.update_setting("notifications_enabled", "true")

      {:ok, _, [:system_prompt]} =
        UserConfig.admin_update(manager_scope(), user.uuid, %{"system_prompt" => "SECRET"})

      assert Repo.all(
               from(n in PhoenixKit.Notifications.Notification,
                 where: n.recipient_uuid == ^user.uuid
               )
             ) == []
    end

    test "a money limit above $1,000,000 is an error, not a database exception", %{user: user} do
      scope = manager_scope()

      for value <- [1_000_000_000_001, 9_223_372_036_854_775_808] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 UserConfig.admin_update(scope, user.uuid, %{
                   "daily_cost_limit_micro_usd" => value,
                   "monthly_cost_limit_micro_usd" => value
                 })

        assert %{daily_cost_limit_micro_usd: [_], monthly_cost_limit_micro_usd: [_]} =
                 errors_on(changeset)
      end

      assert {:ok, _, _} =
               UserConfig.admin_update(scope, user.uuid, %{
                 "monthly_cost_limit_micro_usd" => 1_000_000_000_000
               })
    end

    test "an Owner's settings are changed by an Owner only" do
      owner = owner_fixture()
      manager = manager_scope()

      assert {:error, :forbidden} =
               UserConfig.admin_update(manager, owner.uuid, %{"daily_turn_limit" => "1"})

      assert Repo.get(UserSettings, owner.uuid) == nil
      assert activity("agent.user_settings_updated") == []

      assert {:ok, _, [:daily_turn_limit]} =
               UserConfig.admin_update(scope_of(owner), owner.uuid, %{"daily_turn_limit" => "1"})
    end

    test "with expected values: a save over someone else's change is refused", %{user: user} do
      scope = manager_scope()
      {:ok, _, _} = UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "5"})

      # What the first admin's form showed when it opened: no limit of their own.
      opened = %{daily_turn_limit: nil, system_prompt: nil}

      assert {:error, :stale} =
               UserConfig.admin_update(
                 scope,
                 user.uuid,
                 %{"daily_turn_limit" => "", "system_prompt" => "Mine"},
                 expected: opened
               )

      row = Repo.get!(UserSettings, user.uuid)
      assert row.daily_turn_limit == 5
      assert row.system_prompt == nil
      assert length(activity("agent.user_settings_updated")) == 1

      assert {:ok, _, [:system_prompt]} =
               UserConfig.admin_update(scope, user.uuid, %{"system_prompt" => "Mine"},
                 expected: %{daily_turn_limit: 5, system_prompt: nil}
               )
    end

    test "with expected values: a field outside them does not make the save stale", %{
      user: user,
      ref: ref
    } do
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      assert {:ok, _, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{"daily_turn_limit" => "3"},
                 expected: %{daily_turn_limit: nil}
               )
    end

    test "blank limit fields go back to the module default", %{user: user} do
      scope = manager_scope()
      {:ok, _, _} = UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => "3"})
      assert UserConfig.effective(user.uuid).daily_turn_limit == 3

      {:ok, _, [:daily_turn_limit]} =
        UserConfig.admin_update(scope, user.uuid, %{"daily_turn_limit" => ""})

      assert UserConfig.effective(user.uuid).daily_turn_limit == 200
    end
  end

  describe "admin_update/4: the model must fit the agent.chat AI task" do
    setup do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      :ok
    end

    test "a model known to take no tools is refused and nothing is written", %{user: user} do
      unfit = declared(%{name: "Plain", model: "a/no-tools"}, "no")

      assert {:error, {:model_unfit, [:tools], :endpoint_uuid}} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unfit.uuid,
                 "daily_turn_limit" => "4"
               })

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a model nobody knows takes tools is refused and nothing is written", %{user: user} do
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})

      assert {:error, {:model_unverified, [:tools], :endpoint_uuid}} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unknown.uuid
               })

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "a model that takes tools is saved, and none (the module default) too", %{user: user} do
      fit = declared(%{name: "Tools", model: "a/tools"}, "yes")
      scope = manager_scope()

      assert {:ok, %UserSettings{endpoint_uuid: endpoint_uuid}, [:endpoint_uuid]} =
               UserConfig.admin_update(scope, user.uuid, %{"endpoint_uuid" => fit.uuid})

      assert endpoint_uuid == fit.uuid

      assert {:ok, %UserSettings{endpoint_uuid: nil}, [:endpoint_uuid]} =
               UserConfig.admin_update(scope, user.uuid, %{"endpoint_uuid" => nil})
    end

    test "a model kept as it is is not checked again", %{user: user} do
      unfit = declared(%{name: "Plain", model: "a/no-tools"}, "no")
      Repo.insert!(%UserSettings{user_uuid: user.uuid, endpoint_uuid: unfit.uuid})

      assert {:ok, _row, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => unfit.uuid,
                 "daily_turn_limit" => "4"
               })
    end
  end

  # ── the three models ──────────────────────────────────────────────────

  # An endpoint whose model's abilities an admin declared (`flags`:
  # "tools", "vision", "audio_input" → "yes" / "no").
  defp capable(flags, attrs \\ %{}) do
    model = Map.get(attrs, :model, "a/model-#{System.unique_integer([:positive])}")

    endpoint_fixture(
      attrs
      |> Map.put(:model, model)
      |> Map.put(:provider_settings, %{"capabilities" => Map.put(flags, "model", model)})
    )
  end

  # An endpoint that suits every task of the assistant.
  defp all_round(attrs \\ %{}),
    do: capable(%{"tools" => "yes", "vision" => "yes", "audio_input" => "yes"}, attrs)

  defp allow!(endpoints),
    do: {:ok, _} = Config.put_selectable_endpoints(Enum.map(endpoints, & &1.uuid), [])

  defp disable!(endpoint) do
    Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^endpoint.uuid),
      set: [enabled: false]
    )
  end

  describe "effective/1: the three models" do
    test "a user without a row gets the default of each task", %{user: user} do
      {chat, vision, speech} = {all_round(), all_round(), all_round()}
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat.uuid)
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", vision.uuid)
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", speech.uuid)

      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == chat.uuid
      assert effective.vision_endpoint_uuid == vision.uuid
      assert effective.speech_endpoint_uuid == speech.uuid

      assert %{
               chat: %{source: :default, uuid: chat_uuid, own_uuid: nil},
               vision: %{source: :default},
               speech: %{source: :default}
             } = effective.models

      assert chat_uuid == chat.uuid
    end

    test "nothing set anywhere: nothing in effect", %{user: user} do
      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == nil
      assert effective.vision_endpoint_uuid == nil
      assert effective.speech_endpoint_uuid == nil
    end

    test "a row with only the chat model behaves as before", %{user: user} do
      own = endpoint_fixture()
      vision = all_round()
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", vision.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, endpoint_uuid: own.uuid})

      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == own.uuid
      assert effective.models.chat.source == :own
      assert effective.vision_endpoint_uuid == vision.uuid
      assert effective.models.vision.source == :default
      assert effective.speech_endpoint_uuid == nil
      assert effective.own == [:endpoint_uuid]
    end

    test "each own model wins in its own task only", %{user: user} do
      {own_vision, own_speech} = {all_round(), all_round()}
      default = all_round()

      for key <- ~w(default vision speech),
          do: Settings.update_setting("agent_#{key}_endpoint_uuid", default.uuid)

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        vision_endpoint_uuid: own_vision.uuid,
        speech_endpoint_uuid: own_speech.uuid
      })

      effective = UserConfig.effective(user.uuid)

      assert effective.endpoint_uuid == default.uuid
      assert effective.vision_endpoint_uuid == own_vision.uuid
      assert effective.speech_endpoint_uuid == own_speech.uuid

      assert %{
               chat: %{source: :default},
               vision: %{source: :own, default_uuid: default_uuid},
               speech: %{source: :own}
             } = effective.models

      assert default_uuid == default.uuid
      assert effective.own == [:vision_endpoint_uuid, :speech_endpoint_uuid]
    end

    test "effective_many/1 gives each user what effective/1 gives", %{user: user} do
      other = user_with(["agent"], "other")
      {a, b} = {all_round(), all_round()}
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: a.uuid})
      Repo.insert!(%UserSettings{user_uuid: other.uuid, speech_endpoint_uuid: b.uuid})

      many = UserConfig.effective_many([user.uuid, other.uuid])

      assert many[user.uuid] == UserConfig.effective(user.uuid)
      assert many[other.uuid] == UserConfig.effective(other.uuid)
      assert many[user.uuid].vision_endpoint_uuid == a.uuid
      assert many[other.uuid].vision_endpoint_uuid == nil
    end

    test "a deleted own model is the default again", %{user: user} do
      own = all_round()
      default = all_round()
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", default.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: own.uuid})
      {:ok, _} = PhoenixKitAI.delete_endpoint(own)

      effective = UserConfig.effective(user.uuid)

      assert effective.vision_endpoint_uuid == default.uuid
      assert effective.models.vision.source == :default
    end

    test "an own model that was switched off falls back, and says so", %{user: user} do
      own = all_round()
      default = all_round()
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", default.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, speech_endpoint_uuid: own.uuid})
      disable!(own)

      effective = UserConfig.effective(user.uuid)

      assert effective.speech_endpoint_uuid == default.uuid

      assert %{source: :fallback, own_uuid: own_uuid, uuid: uuid} = effective.models.speech
      assert own_uuid == own.uuid
      assert uuid == default.uuid
    end

    test "an own model that lost its credentials falls back too", %{user: user} do
      own = all_round()
      default = endpoint_fixture()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", default.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, endpoint_uuid: own.uuid})

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^own.uuid),
        set: [api_key: "", integration_uuid: nil, provider: "no-such-provider"]
      )

      assert %{endpoint_uuid: uuid, models: %{chat: %{source: :fallback}}} =
               UserConfig.effective(user.uuid)

      assert uuid == default.uuid
    end

    test "an own model with no default behind it, once unusable, leaves nothing in effect",
         %{user: user} do
      own = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: own.uuid})
      disable!(own)

      assert %{vision_endpoint_uuid: nil, models: %{vision: %{source: :fallback}}} =
               UserConfig.effective(user.uuid)
    end

    test "an own model that left the list of those users may choose stays, marked", %{user: user} do
      own = all_round()
      kept = all_round()
      allow!([kept])
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: own.uuid})

      assert %{
               vision_endpoint_uuid: uuid,
               models: %{vision: %{source: :own, outside_list?: true}}
             } =
               UserConfig.effective(user.uuid)

      assert uuid == own.uuid

      allow!([kept, own])
      assert %{models: %{vision: %{outside_list?: false}}} = UserConfig.effective(user.uuid)
    end

    test "model/2 is the model of one task", %{user: user} do
      own = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, speech_endpoint_uuid: own.uuid})

      assert %{uuid: uuid, source: :own} = UserConfig.model(user.uuid, :speech)
      assert uuid == own.uuid
      assert %{uuid: nil, source: :default} = UserConfig.model(user.uuid, :vision)
    end
  end

  describe "the picture rule on what effective/1 gives (no ImageMagick needed)" do
    alias PhoenixKitAgent.Attachments.Processor

    test "an own picture model describes even for a chat model that sees", %{user: user} do
      chat = all_round()
      own = all_round()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: own.uuid})

      assert {:ok, {:describe, described_by}} =
               user.uuid |> UserConfig.effective() |> Processor.picture_mode()

      assert described_by == own.uuid
    end

    test "without one, a chat model that sees gets the pixels", %{user: user} do
      chat = all_round()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat.uuid)

      assert {:ok, :pixels} = user.uuid |> UserConfig.effective() |> Processor.picture_mode()
    end

    test "an own picture model that was switched off leaves the old rule: pixels", %{user: user} do
      chat = all_round()
      own = all_round()
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat.uuid)
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: own.uuid})
      disable!(own)

      assert {:ok, :pixels} = user.uuid |> UserConfig.effective() |> Processor.picture_mode()
    end
  end

  describe "speech?/1: voice is offered when the user's own speech model exists" do
    test "the default alone, his own alone, none, and his own gone", %{user: user} do
      refute UserConfig.speech?(user.uuid)

      default = all_round()
      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", default.uuid)
      assert UserConfig.speech?(user.uuid)

      {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", "")
      refute UserConfig.speech?(user.uuid)

      own = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, speech_endpoint_uuid: own.uuid})
      assert UserConfig.speech?(user.uuid)

      disable!(own)
      refute UserConfig.speech?(user.uuid)
    end

    test "is off while the AI module cannot write speech down", %{user: user} do
      own = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, speech_endpoint_uuid: own.uuid})
      Application.put_env(:phoenix_kit_agent, :speech_ai, __MODULE__)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)

      refute UserConfig.speech?(user.uuid)
    end
  end

  describe "endpoint_uuids/1: what the AI task guard watches" do
    test "the default and every user's own model of the task, and no other task's", %{user: user} do
      {default, own_vision, own_chat} = {all_round(), all_round(), all_round()}
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", default.uuid)

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        vision_endpoint_uuid: own_vision.uuid,
        endpoint_uuid: own_chat.uuid
      })

      assert Enum.sort(UserConfig.endpoint_uuids(:vision)) ==
               Enum.sort([default.uuid, own_vision.uuid])

      assert UserConfig.endpoint_uuids() == [own_chat.uuid]
      assert UserConfig.endpoint_uuids(:speech) == []
    end
  end

  describe "put_personal_models/3: the user's own choice" do
    setup %{user: user} do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      %{good: all_round(%{name: "Good"}), user: user}
    end

    test "nothing may be chosen until an administrator names the endpoints", %{
      ref: ref,
      user: user,
      good: good
    } do
      assert {:error, {:vision_endpoint_uuid, :not_allowed}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "the user's own change is in the activity log, with him as the actor", %{
      ref: ref,
      user: user,
      good: good
    } do
      other = all_round(%{name: "Other"})
      allow!([good, other])

      assert {:ok, [:endpoint_uuid]} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => good.uuid}, @me)

      assert {:ok, [:endpoint_uuid]} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => other.uuid}, @me)

      # Nothing changed: nothing logged.
      assert {:ok, []} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => other.uuid}, @me)

      assert [first, second] =
               "agent.user_settings_updated"
               |> activity()
               |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

      for entry <- [first, second] do
        assert entry.actor_uuid == user.uuid
        assert entry.resource_uuid == user.uuid
        assert entry.module == "agent"
        assert entry.metadata["fields"] == ["endpoint_uuid"]
      end

      assert first.metadata["changes"] == %{
               "endpoint_uuid" => %{"from" => nil, "to" => good.uuid}
             }

      assert second.metadata["changes"] == %{
               "endpoint_uuid" => %{"from" => good.uuid, "to" => other.uuid}
             }
    end

    test "a refused choice logs nothing", %{ref: ref, good: good} do
      assert {:error, _} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => good.uuid}, @me)

      assert activity("agent.user_settings_updated") == []
    end

    test "a speech model is refused where the AI module cannot write speech down", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      Application.put_env(:phoenix_kit_agent, :speech_ai, __MODULE__)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)
      refute Config.transcribe?()

      assert {:error, {:speech_endpoint_uuid, :not_allowed}} =
               UserConfig.put_personal_models(ref, %{"speech_endpoint_uuid" => good.uuid}, @me)

      assert Repo.get(UserSettings, user.uuid) == nil

      # Going back to the default stays possible.
      assert {:ok, _} = UserConfig.put_personal_models(ref, %{"speech_endpoint_uuid" => ""}, @me)
    end

    test "an allowed, valid model is taken, for each task, and is in effect at once", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])

      assert {:ok, fields} =
               UserConfig.put_personal_models(
                 ref,
                 %{
                   "endpoint_uuid" => good.uuid,
                   "vision_endpoint_uuid" => good.uuid,
                   "speech_endpoint_uuid" => good.uuid
                 },
                 @me
               )

      assert Enum.sort(fields) == [:endpoint_uuid, :speech_endpoint_uuid, :vision_endpoint_uuid]

      row = Repo.get!(UserSettings, user.uuid)

      assert {row.endpoint_uuid, row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {good.uuid, good.uuid, good.uuid}

      effective = UserConfig.effective(user.uuid)

      assert Enum.all?(
               Map.values(effective.models),
               &(&1.source == :own and &1.uuid == good.uuid)
             )
    end

    test "atom keys do as well as strings; a field not named stays", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      other = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, speech_endpoint_uuid: other.uuid})

      assert {:ok, [:vision_endpoint_uuid]} =
               UserConfig.put_personal_models(ref, %{vision_endpoint_uuid: good.uuid}, @me)

      row = Repo.get!(UserSettings, user.uuid)
      assert row.vision_endpoint_uuid == good.uuid
      assert row.speech_endpoint_uuid == other.uuid
    end

    test "blank or nil is \"the default\"", %{ref: ref, user: user, good: good} do
      allow!([good])

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        vision_endpoint_uuid: good.uuid,
        speech_endpoint_uuid: good.uuid
      })

      assert {:ok, fields} =
               UserConfig.put_personal_models(
                 ref,
                 %{"vision_endpoint_uuid" => "", "speech_endpoint_uuid" => nil},
                 @me
               )

      assert Enum.sort(fields) == [:speech_endpoint_uuid, :vision_endpoint_uuid]
      row = Repo.get!(UserSettings, user.uuid)
      assert {row.vision_endpoint_uuid, row.speech_endpoint_uuid} == {nil, nil}
    end

    test "a model that is not on the list is refused, whatever the task", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      stranger = all_round()

      for field <- ~w(endpoint_uuid vision_endpoint_uuid speech_endpoint_uuid) do
        assert {:error, {key, :not_allowed}} =
                 UserConfig.put_personal_models(ref, %{field => stranger.uuid}, @me)

        assert Atom.to_string(key) == field
      end

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "a model that does not exist, or is not a uuid, is refused", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])

      assert {:error, {:vision_endpoint_uuid, :not_allowed}} =
               UserConfig.put_personal_models(
                 ref,
                 %{"vision_endpoint_uuid" => Ecto.UUID.generate()},
                 @me
               )

      assert {:error, %Ecto.Changeset{}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => "nope"}, @me)

      assert {:error, %Ecto.Changeset{}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => [good.uuid]}, @me)

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "a listed model that does not fit the task of the field is refused", %{
      ref: ref,
      user: user
    } do
      blind = capable(%{"tools" => "yes", "vision" => "no", "audio_input" => "no"})
      deaf = capable(%{"tools" => "yes", "vision" => "yes", "audio_input" => "no"})
      plain = capable(%{"tools" => "no", "vision" => "yes", "audio_input" => "yes"})
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})
      allow!([blind, deaf, plain, unknown])

      assert {:error, {:vision_endpoint_uuid, {:model_unfit, [:vision]}}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => blind.uuid}, @me)

      assert {:error, {:speech_endpoint_uuid, {:model_unfit, [:audio_input]}}} =
               UserConfig.put_personal_models(ref, %{"speech_endpoint_uuid" => deaf.uuid}, @me)

      assert {:error, {:endpoint_uuid, {:model_unfit, [:tools]}}} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => plain.uuid}, @me)

      assert {:error, {:endpoint_uuid, {:model_unverified, _unclear}}} =
               UserConfig.put_personal_models(ref, %{"endpoint_uuid" => unknown.uuid}, @me)

      assert Repo.get(UserSettings, user.uuid) == nil

      # A model that fits one task is not thereby fit for the other.
      assert {:ok, [:vision_endpoint_uuid]} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => deaf.uuid}, @me)
    end

    test "a listed model that was switched off is refused", %{ref: ref, user: user, good: good} do
      allow!([good])
      disable!(good)

      assert {:error, {:vision_endpoint_uuid, :unusable}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "one refused field writes nothing, the good ones included", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      stranger = all_round()

      assert {:error, {:speech_endpoint_uuid, :not_allowed}} =
               UserConfig.put_personal_models(
                 ref,
                 %{"vision_endpoint_uuid" => good.uuid, "speech_endpoint_uuid" => stranger.uuid},
                 @me
               )

      assert Repo.get(UserSettings, user.uuid) == nil
    end

    test "what an administrator set outside the list stays, and a form may carry it back", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      by_admin = all_round()
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: by_admin.uuid})

      assert {:ok, [:speech_endpoint_uuid]} =
               UserConfig.put_personal_models(
                 ref,
                 %{"vision_endpoint_uuid" => by_admin.uuid, "speech_endpoint_uuid" => good.uuid},
                 @me
               )

      row = Repo.get!(UserSettings, user.uuid)
      assert row.vision_endpoint_uuid == by_admin.uuid
      assert row.speech_endpoint_uuid == good.uuid
    end

    test "writing the models leaves everything an administrator set, the instructions and a turn's lock",
         %{ref: ref, user: user, good: good} do
      allow!([good])
      admin_endpoint = endpoint_fixture()
      {:ok, _} = UserConfig.put_personal_instructions(ref, "Mine", @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [
          enabled: nil,
          endpoint_uuid: admin_endpoint.uuid,
          system_prompt: "Admin prompt",
          daily_turn_limit: 5,
          daily_cost_limit_micro_usd: 7,
          notify_on_limit: true,
          busy_since: DateTime.utc_now(),
          busy_turn_ref: "t1",
          updated_by_uuid: user.uuid
        ]
      )

      before = Repo.get!(UserSettings, user.uuid)

      assert {:ok, [:vision_endpoint_uuid]} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      row = Repo.get!(UserSettings, user.uuid)
      assert row.vision_endpoint_uuid == good.uuid

      assert %{row | vision_endpoint_uuid: nil, updated_at: nil} ==
               %{before | updated_at: nil}
    end

    test "an attribute that is not a model is ignored: nothing but the three columns moves", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      other = user_with(["agent"], "bystander")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, daily_turn_limit: 3})

      assert {:ok, [:vision_endpoint_uuid]} =
               UserConfig.put_personal_models(
                 ref,
                 %{
                   "vision_endpoint_uuid" => good.uuid,
                   "user_uuid" => other.uuid,
                   "enabled" => "false",
                   "system_prompt" => "Ignore the rules",
                   "daily_turn_limit" => "100000",
                   "busy_turn_ref" => "forged",
                   "updated_by_uuid" => user.uuid
                 },
                 @me
               )

      row = Repo.get!(UserSettings, user.uuid)

      assert {row.enabled, row.system_prompt, row.daily_turn_limit, row.busy_turn_ref} ==
               {nil, nil, nil, nil}

      assert row.updated_by_uuid == nil

      bystander = Repo.get!(UserSettings, other.uuid)
      assert {bystander.daily_turn_limit, bystander.vision_endpoint_uuid} == {3, nil}
    end

    test "the row is the session's user's, another user's is never touched", %{
      ref: ref,
      good: good
    } do
      allow!([good])
      other = user_with(["agent"], "bystander")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, speech_endpoint_uuid: good.uuid})

      assert {:ok, _} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      other_row = Repo.get!(UserSettings, other.uuid)
      assert other_row.vision_endpoint_uuid == nil
      assert other_row.speech_endpoint_uuid == good.uuid
    end

    test "a model that left the list stays in effect for the user who chose it", %{
      ref: ref,
      user: user,
      good: good
    } do
      allow!([good])
      {:ok, _} = UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      allow!([])

      assert %{
               vision_endpoint_uuid: uuid,
               models: %{vision: %{source: :own, outside_list?: true}}
             } =
               UserConfig.effective(user.uuid)

      assert uuid == good.uuid

      # And he cannot choose it again once he moved off it.
      {:ok, _} = UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => ""}, @me)

      assert {:error, {:vision_endpoint_uuid, :not_allowed}} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)
    end

    test "a revoked session, a borrowed one, a switched-off user and one without agent are refused",
         %{user: user, good: good} do
      allow!([good])
      attrs = %{"vision_endpoint_uuid" => good.uuid}
      {ref, token} = session_fixture(user)

      assert {:error, :impersonated} =
               UserConfig.put_personal_models(ref, attrs, impersonated: true)

      Repo.insert!(%UserSettings{user_uuid: user.uuid, enabled: false})
      assert {:error, :forbidden} = UserConfig.put_personal_models(ref, attrs, @me)

      Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^user.uuid),
        set: [enabled: nil]
      )

      :ok = Auth.delete_user_session_token(token)
      assert {:error, :session_gone} = UserConfig.put_personal_models(ref, attrs, @me)
      assert Repo.get!(UserSettings, user.uuid).vision_endpoint_uuid == nil

      stranger = user_with(["dashboard"], "stranger")
      {stranger_ref, _} = session_fixture(stranger)
      assert {:error, :forbidden} = UserConfig.put_personal_models(stranger_ref, attrs, @me)
      assert Repo.get(UserSettings, stranger.uuid) == nil
    end

    test "a linked Telegram chat cannot choose models", %{good: good} do
      allow!([good])
      member = user_with(["agent", "agent.telegram"], "tg")
      ref = telegram_link_fixture(member, UUIDv7.generate(), 4245)

      assert {:error, :not_in_telegram} =
               UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => good.uuid}, @me)

      assert Repo.get(UserSettings, member.uuid) == nil
    end

    test "the missing impersonation flag raises", %{ref: ref} do
      assert_raise ArgumentError, fn -> UserConfig.put_personal_models(ref, %{}, []) end
    end
  end

  describe "admin_update/4: the three models" do
    setup do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      :ok
    end

    test "all three are set at once, in or out of the users' list, and logged by field name", %{
      user: user
    } do
      {a, b, c} = {all_round(), all_round(), all_round()}
      allow!([a])

      assert {:ok, row, fields} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => a.uuid,
                 "vision_endpoint_uuid" => b.uuid,
                 "speech_endpoint_uuid" => c.uuid
               })

      assert Enum.sort(fields) == [:endpoint_uuid, :speech_endpoint_uuid, :vision_endpoint_uuid]

      assert {row.endpoint_uuid, row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {a.uuid, b.uuid, c.uuid}

      assert [entry] = activity("agent.user_settings_updated")

      assert Enum.sort(entry.metadata["fields"]) ==
               ["endpoint_uuid", "speech_endpoint_uuid", "vision_endpoint_uuid"]
    end

    test "a save that offers only the other fields leaves the user's own picture and speech models",
         %{user: user} do
      {a, b} = {all_round(), all_round()}

      Repo.insert!(%UserSettings{
        user_uuid: user.uuid,
        vision_endpoint_uuid: a.uuid,
        speech_endpoint_uuid: b.uuid
      })

      assert {:ok, row, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => nil,
                 "daily_turn_limit" => "9"
               })

      assert {row.vision_endpoint_uuid, row.speech_endpoint_uuid} == {a.uuid, b.uuid}
    end

    test "a picture model that cannot take pictures is refused, with its field named", %{
      user: user
    } do
      blind = capable(%{"tools" => "yes", "vision" => "no", "audio_input" => "no"})
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})
      scope = manager_scope()

      assert {:error, {:model_unfit, [:vision], :vision_endpoint_uuid}} =
               UserConfig.admin_update(scope, user.uuid, %{"vision_endpoint_uuid" => blind.uuid})

      assert {:error, {:model_unfit, [:audio_input], :speech_endpoint_uuid}} =
               UserConfig.admin_update(scope, user.uuid, %{"speech_endpoint_uuid" => blind.uuid})

      assert {:error, {:model_unverified, _unclear, :speech_endpoint_uuid}} =
               UserConfig.admin_update(scope, user.uuid, %{"speech_endpoint_uuid" => unknown.uuid})

      assert Repo.get(UserSettings, user.uuid) == nil
      assert activity("agent.user_settings_updated") == []
    end

    test "the chat model's refusal has the same shape, with its field", %{user: user} do
      plain = capable(%{"tools" => "no"})

      assert {:error, {:model_unfit, [:tools], :endpoint_uuid}} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "endpoint_uuid" => plain.uuid
               })
    end

    test "a model kept as it is is not checked again, and none is the default", %{user: user} do
      blind = capable(%{"tools" => "yes", "vision" => "no"})
      Repo.insert!(%UserSettings{user_uuid: user.uuid, vision_endpoint_uuid: blind.uuid})

      assert {:ok, _row, [:daily_turn_limit]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "vision_endpoint_uuid" => blind.uuid,
                 "daily_turn_limit" => "4"
               })

      assert {:ok, %UserSettings{vision_endpoint_uuid: nil}, [:vision_endpoint_uuid]} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{"vision_endpoint_uuid" => ""})
    end

    test "a form opened before the user chose his own picture model is stale", %{
      user: user,
      ref: ref
    } do
      own = all_round()
      allow!([own])
      {:ok, _} = UserConfig.put_personal_models(ref, %{"vision_endpoint_uuid" => own.uuid}, @me)

      assert {:error, :stale} =
               UserConfig.admin_update(
                 manager_scope(),
                 user.uuid,
                 %{"vision_endpoint_uuid" => ""},
                 expected: %{vision_endpoint_uuid: nil}
               )

      assert Repo.get!(UserSettings, user.uuid).vision_endpoint_uuid == own.uuid
    end

    test "an endpoint that does not exist is a changeset error", %{user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               UserConfig.admin_update(manager_scope(), user.uuid, %{
                 "speech_endpoint_uuid" => Ecto.UUID.generate()
               })

      assert %{speech_endpoint_uuid: [_]} = errors_on(changeset)
    end
  end

  # An endpoint whose model's tools an admin declared.
  defp declared(attrs, tools) do
    model = Map.fetch!(attrs, :model)

    endpoint_fixture(
      Map.put(attrs, :provider_settings, %{
        "capabilities" => %{"model" => model, "tools" => tools}
      })
    )
  end

  defp activity(action) do
    Repo.all(from(a in PhoenixKit.Activity.Entry, where: a.action == ^action))
  end
end
