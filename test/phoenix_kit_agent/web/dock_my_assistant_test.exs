defmodule PhoenixKitAgent.Web.DockMyAssistantTest do
  @moduledoc """
  "My assistant" in the chat panel's settings region: the user's three models
  (the ones he may choose among, or read-only while none is opened), his limits
  read-only, and the personal instructions beside them. Only the session's own
  user is written, by `UserConfig.put_personal_models/3`; whatever a crafted
  event carries beyond the three models is dropped.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAgent.{Config, UserConfig}
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Web.Dock

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    PhoenixKitAI.Guard.reset_caches()
    on_exit(&PhoenixKitAI.Guard.reset_caches/0)

    {:ok, role} = Roles.create_role(%{name: "AgentMine#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("mine")
    {:ok, _} = Roles.assign_role(user, role.name)
    {ref, token} = session_fixture(user)

    default = all_round(%{name: "SiteDefault"})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", default.uuid)

    %{
      conn: conn,
      user: user,
      role: role,
      ref: ref,
      token: token,
      default: default,
      chat: all_round(%{name: "Chatty"}),
      seer: all_round(%{name: "Seer"}),
      ear: all_round(%{name: "Ear"}),
      blind:
        capable(%{"tools" => "yes", "vision" => "no", "audio_input" => "no"}, %{name: "Blind"}),
      outside: all_round(%{name: "Outsider"})
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp dock(ctx) do
    {:ok, view, _html} =
      ctx.conn
      |> Plug.Test.init_test_session(%{"user_token" => ctx.token})
      |> live_isolated(Dock, session: %{"user_uuid" => ctx.user.uuid, "locale" => "en"})

    view
  end

  defp open_settings(ctx) do
    view = dock(ctx)
    view |> element("#pk-agent-instructions-toggle") |> render_click()
    view
  end

  defp capable(flags, attrs) do
    model = Map.get(attrs, :model, "a/model-#{System.unique_integer([:positive])}")

    endpoint_fixture(
      attrs
      |> Map.put(:model, model)
      |> Map.put(:provider_settings, %{"capabilities" => Map.put(flags, "model", model)})
    )
  end

  defp all_round(attrs),
    do: capable(%{"tools" => "yes", "vision" => "yes", "audio_input" => "yes"}, attrs)

  defp allow!(endpoints),
    do: {:ok, _} = Config.put_selectable_endpoints(Enum.map(endpoints, & &1.uuid), [])

  defp row(ctx), do: Repo.get(UserSettings, ctx.user.uuid)

  defp save(view, models),
    do: view |> form("#pk-agent-models-form", models: models) |> render_submit()

  defp switch_off!(endpoint) do
    Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^endpoint.uuid),
      set: [enabled: false]
    )
  end

  # ── the region ──────────────────────────────────────────────────────

  describe "the settings region" do
    test "holds the models, the limits and the instructions, and closes together", ctx do
      view = dock(ctx)
      refute has_element?(view, "#pk-agent-my-assistant")

      view |> element("#pk-agent-instructions-toggle") |> render_click()

      assert has_element?(view, "#pk-agent-settings #pk-agent-my-assistant")
      assert has_element?(view, "#pk-agent-settings #pk-agent-limits")
      assert has_element?(view, "#pk-agent-settings #pk-agent-instructions-form")

      view |> element("#pk-agent-instructions-toggle") |> render_click()

      refute has_element?(view, "#pk-agent-settings")
      refute has_element?(view, "#pk-agent-limits")
    end

    test "the limits are shown, read-only, with who sets them", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        daily_cost_limit_micro_usd: 2_500_000,
        monthly_cost_limit_micro_usd: 30_000_000,
        daily_turn_limit: 17
      })

      view = open_settings(ctx)

      assert has_element?(view, "#pk-agent-limit-daily-cost", "2.50")
      assert has_element?(view, "#pk-agent-limit-monthly-cost", "30.00")
      assert has_element?(view, "#pk-agent-limit-turns", "17")
      assert has_element?(view, "#pk-agent-limits", "administrator")
      refute has_element?(view, "#pk-agent-limits input")
      refute has_element?(view, "#pk-agent-limits form")
    end

    test "is capped and scrolls inside, so it never pushes the chat out", ctx do
      view = open_settings(ctx)

      assert has_element?(
               view,
               "#pk-agent-settings[class*='max-h-[60dvh]'][class*='overflow-y-auto'][class*='shrink-0']"
             )
    end

    test "nothing in it is about another user", ctx do
      other = user_fixture("someone-else")
      Repo.insert!(%UserSettings{user_uuid: other.uuid, system_prompt: "OTHER-PROMPT"})
      allow!([ctx.chat])

      html = ctx |> open_settings() |> render()

      refute html =~ other.email
      refute html =~ other.uuid
      refute html =~ "OTHER-PROMPT"
    end

    test "buttons keep the touch size of the panel's other buttons", ctx do
      allow!([ctx.chat])
      view = open_settings(ctx)

      assert has_element?(
               view,
               "#pk-agent-models-save[class*='pointer-coarse:min-h-11'][class*='pointer-coarse:min-w-11']"
             )

      assert has_element?(
               view,
               "#pk-agent-model-chat-field .select[class*='pointer-coarse:min-h-11']"
             )
    end
  end

  describe "while no model is opened for choosing" do
    test "the three are read-only, with the model in effect and a note", ctx do
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", ctx.seer.uuid)
      view = open_settings(ctx)

      refute has_element?(view, "#pk-agent-models-form")
      assert has_element?(view, "#pk-agent-models-closed")
      assert has_element?(view, "#pk-agent-model-chat-model", "SiteDefault")
      assert has_element?(view, "#pk-agent-model-vision-model", "Seer")
      assert has_element?(view, "#pk-agent-model-chat-effective[data-source='default']")
      refute has_element?(view, "#pk-agent-my-assistant select")
    end

    test "a model of his own in effect is shown the same way", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: ctx.chat.uuid})
      view = open_settings(ctx)

      assert has_element?(view, "#pk-agent-model-chat-model", "Chatty")
      assert has_element?(view, "#pk-agent-model-chat-effective[data-source='own']")
      assert has_element?(view, "#pk-agent-model-chat-outside-list")
    end

    test "a crafted save changes nothing", ctx do
      allow!([ctx.chat])
      view = open_settings(ctx)
      {:ok, _} = Config.put_selectable_endpoints([], [])

      render_hook(view, "save_models", %{"models" => %{"endpoint_uuid" => ctx.chat.uuid}})

      assert row(ctx) == nil
    end
  end

  describe "choosing among the allowed models" do
    setup ctx do
      allow!([ctx.chat, ctx.seer, ctx.ear, ctx.blind])
      :ok
    end

    test "each field offers the default and the allowed models that fit its task", ctx do
      view = open_settings(ctx)

      for dom <- ~w(chat vision speech) do
        assert has_element?(view, "#pk-agent-model-#{dom}", "")
        assert has_element?(view, "#pk-agent-model-#{dom} option[value='']", "Default:")
        refute has_element?(view, "#pk-agent-model-#{dom} option[value='#{ctx.outside.uuid}']")
      end

      assert has_element?(view, "#pk-agent-model-chat option[value=''][selected]", "SiteDefault")
      assert has_element?(view, "#pk-agent-model-chat option[value='#{ctx.chat.uuid}']")
      assert has_element?(view, "#pk-agent-model-vision option[value='#{ctx.seer.uuid}']")
      refute has_element?(view, "#pk-agent-model-vision option[value='#{ctx.blind.uuid}']")
      refute has_element?(view, "#pk-agent-model-speech option[value='#{ctx.blind.uuid}']")
      refute has_element?(view, "#pk-agent-models-closed")
    end

    test "a model without a price is marked in the choices, one with a price is not", ctx do
      bare = all_round(%{name: "Bare", provider: "deepseek", model: "deepseek-chat"})
      priced = all_round(%{name: "Priced", provider: "anthropic", model: "claude-sonnet-5-5"})
      allow!([ctx.chat, bare, priced])

      view = open_settings(ctx)

      for dom <- ~w(chat vision speech) do
        assert has_element?(
                 view,
                 "#pk-agent-model-#{dom} option[value='#{bare.uuid}']",
                 "money is not counted"
               )

        refute has_element?(
                 view,
                 "#pk-agent-model-#{dom} option[value='#{priced.uuid}']",
                 "money is not counted"
               )
      end

      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, endpoint_uuid: bare.uuid})
      {:ok, _} = Config.put_selectable_endpoints([], [])
      view = open_settings(ctx)
      assert has_element?(view, "#pk-agent-model-chat-model", "money is not counted")
    end

    test "each select points to what is said under it", ctx do
      view = open_settings(ctx)

      for dom <- ~w(chat vision speech) do
        assert has_element?(
                 view,
                 "select#pk-agent-model-#{dom}[aria-describedby='pk-agent-model-#{dom}-effective']"
               )
      end
    end

    test "saves each of the three through the form and says what is in effect", ctx do
      view = open_settings(ctx)

      save(view, %{
        endpoint_uuid: ctx.chat.uuid,
        vision_endpoint_uuid: ctx.seer.uuid,
        speech_endpoint_uuid: ctx.ear.uuid
      })

      row = row(ctx)

      assert {row.endpoint_uuid, row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {ctx.chat.uuid, ctx.seer.uuid, ctx.ear.uuid}

      assert has_element?(view, "#pk-agent-models-saved")
      assert has_element?(view, "#pk-agent-model-chat-effective[data-source='own']", "Chatty")
      assert has_element?(view, "#pk-agent-model-vision-effective[data-source='own']", "Seer")
      assert has_element?(view, "#pk-agent-model-chat option[value='#{ctx.chat.uuid}'][selected]")
      refute has_element?(view, "#pk-agent-model-chat-outside-list")
    end

    test "the default again clears only that field", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        endpoint_uuid: ctx.chat.uuid,
        vision_endpoint_uuid: ctx.seer.uuid
      })

      view = open_settings(ctx)
      save(view, %{vision_endpoint_uuid: ""})

      row = row(ctx)
      assert row.vision_endpoint_uuid == nil
      assert row.endpoint_uuid == ctx.chat.uuid
      assert has_element?(view, "#pk-agent-model-vision-effective[data-source='default']")
    end

    test "a model that fell back is told so and stays selected", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.user.uuid, vision_endpoint_uuid: ctx.seer.uuid})
      switch_off!(ctx.seer)

      view = open_settings(ctx)

      assert has_element?(view, "#pk-agent-model-vision-effective[data-source='fallback']")

      assert has_element?(
               view,
               "#pk-agent-model-vision option[value='#{ctx.seer.uuid}'][selected]"
             )

      save(view, %{endpoint_uuid: ctx.chat.uuid})
      assert row(ctx).vision_endpoint_uuid == ctx.seer.uuid
    end

    test "a model outside the list stays selected, may be kept, and may be replaced", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        vision_endpoint_uuid: ctx.outside.uuid
      })

      view = open_settings(ctx)

      assert has_element?(view, "#pk-agent-model-vision-outside-list")

      assert has_element?(
               view,
               "#pk-agent-model-vision option[value='#{ctx.outside.uuid}'][selected]"
             )

      # Kept while another field changes.
      save(view, %{endpoint_uuid: ctx.chat.uuid})
      assert row(ctx).vision_endpoint_uuid == ctx.outside.uuid
      assert has_element?(view, "#pk-agent-model-vision-outside-list")

      # Replaced by a listed one.
      save(view, %{vision_endpoint_uuid: ctx.seer.uuid})
      assert row(ctx).vision_endpoint_uuid == ctx.seer.uuid
      refute has_element?(view, "#pk-agent-model-vision-outside-list")
    end

    test "a model taken off the list after the page opened is refused at its field", ctx do
      view = open_settings(ctx)
      allow!([ctx.seer])

      render_hook(view, "save_models", %{"models" => %{"endpoint_uuid" => ctx.chat.uuid}})

      assert has_element?(view, "#pk-agent-model-chat-field p.text-error")
      assert row(ctx) == nil
    end
  end

  describe "a crafted event" do
    setup ctx do
      allow!([ctx.chat, ctx.seer, ctx.ear, ctx.blind])

      Repo.insert!(%UserSettings{
        user_uuid: ctx.user.uuid,
        enabled: true,
        system_prompt: "ADMIN-PROMPT",
        daily_turn_limit: 7,
        daily_cost_limit_micro_usd: 123_000,
        notify_on_limit: true,
        busy_turn_ref: "turn-in-flight",
        busy_since: ~U[2026-01-01 00:00:00.000000Z],
        updated_by_uuid: ctx.user.uuid
      })

      %{before: Repo.get!(UserSettings, ctx.user.uuid)}
    end

    defp same_but_models?(before, current) do
      keep =
        ~w(enabled system_prompt daily_turn_limit daily_cost_limit_micro_usd monthly_cost_limit_micro_usd
                notify_on_limit notify_user_uuids busy_turn_ref busy_since updated_by_uuid
                personal_instructions max_attachment_mb max_attachments_per_message)a

      Map.take(before, keep) == Map.take(current, keep)
    end

    test "with a model not on the list, or none that exists, changes nothing", ctx do
      view = open_settings(ctx)

      for forged <- [ctx.outside.uuid, Ecto.UUID.generate(), "nonsense", "", " "] do
        for field <- ~w(endpoint_uuid vision_endpoint_uuid speech_endpoint_uuid), forged != "" do
          render_hook(view, "save_models", %{"models" => %{field => forged}})
        end
      end

      current = row(ctx)

      assert {current.endpoint_uuid, current.vision_endpoint_uuid, current.speech_endpoint_uuid} ==
               {nil, nil, nil}

      assert same_but_models?(ctx.before, current)
    end

    test "with a listed model that does not fit the task of the field changes nothing", ctx do
      view = open_settings(ctx)

      render_hook(view, "save_models", %{"models" => %{"vision_endpoint_uuid" => ctx.blind.uuid}})
      render_hook(view, "save_models", %{"models" => %{"speech_endpoint_uuid" => ctx.blind.uuid}})

      assert has_element?(view, "#pk-agent-model-speech-field p.text-error")
      current = row(ctx)
      assert {current.vision_endpoint_uuid, current.speech_endpoint_uuid} == {nil, nil}
      assert same_but_models?(ctx.before, current)
    end

    test "one bad field writes none of the others", ctx do
      view = open_settings(ctx)

      render_hook(view, "save_models", %{
        "models" => %{
          "endpoint_uuid" => ctx.chat.uuid,
          "vision_endpoint_uuid" => ctx.outside.uuid
        }
      })

      assert row(ctx).endpoint_uuid == nil
    end

    test "naming another user changes his row, not the user's own", ctx do
      stranger = user_fixture("stranger")
      view = open_settings(ctx)

      render_hook(view, "save_models", %{
        "user_uuid" => stranger.uuid,
        "uuid" => stranger.uuid,
        "models" => %{
          "user_uuid" => stranger.uuid,
          "endpoint_uuid" => ctx.chat.uuid
        }
      })

      assert Repo.get(UserSettings, stranger.uuid) == nil
      assert row(ctx).endpoint_uuid == ctx.chat.uuid
    end

    test "with fields beyond the three writes the models and nothing else", ctx do
      view = open_settings(ctx)

      render_hook(view, "save_models", %{
        "models" => %{
          "endpoint_uuid" => ctx.chat.uuid,
          "enabled" => "false",
          "system_prompt" => "Mine now",
          "daily_turn_limit" => "100000",
          "daily_cost_limit_usd" => "9999",
          "notify_on_limit" => "false",
          "busy_turn_ref" => "forged",
          "busy_since" => "2020-01-01T00:00:00Z",
          "updated_by_uuid" => Ecto.UUID.generate(),
          "personal_instructions" => "Forged"
        }
      })

      current = row(ctx)
      assert current.endpoint_uuid == ctx.chat.uuid
      assert same_but_models?(ctx.before, current)
    end

    test "that is not text is ignored and takes nothing down", ctx do
      view = open_settings(ctx)

      for forged <- [nil, 7, [ctx.chat.uuid], %{"a" => ctx.chat.uuid}] do
        render_hook(view, "save_models", %{"models" => %{"endpoint_uuid" => forged}})
      end

      render_hook(view, "save_models", %{"models" => "x"})
      render_hook(view, "save_models", %{})

      assert Process.alive?(view.pid)
      assert row(ctx).endpoint_uuid == nil
      assert has_element?(view, "#pk-agent-models-form")
    end

    test "before the region is open writes nothing", ctx do
      view = dock(ctx)

      render_hook(view, "save_models", %{"models" => %{"endpoint_uuid" => ctx.chat.uuid}})

      assert row(ctx).endpoint_uuid == nil
    end

    test "a save keeps the turn lock and the admin's fields", ctx do
      view = open_settings(ctx)
      save(view, %{endpoint_uuid: ctx.chat.uuid})

      current = row(ctx)
      assert current.busy_turn_ref == "turn-in-flight"
      assert same_but_models?(ctx.before, current)
    end
  end

  describe "when the right to use the assistant goes while the region is open" do
    test "a save is refused, the user's row stays, and the panel says so", ctx do
      allow!([ctx.chat])
      view = open_settings(ctx)

      :ok = Permissions.revoke_permission(ctx.role.uuid, "agent")
      render_hook(view, "save_models", %{"models" => %{"endpoint_uuid" => ctx.chat.uuid}})

      assert has_element?(view, "#pk-agent-dock-error")
      assert row(ctx) == nil
    end
  end

  describe "the next turn and the microphone" do
    test "the new model is the one in effect at once", ctx do
      allow!([ctx.chat])
      view = open_settings(ctx)
      save(view, %{endpoint_uuid: ctx.chat.uuid})

      assert UserConfig.effective(ctx.user.uuid).endpoint_uuid == ctx.chat.uuid
      assert UserConfig.model(ctx.user.uuid, :chat).source == :own
    end
  end
end
