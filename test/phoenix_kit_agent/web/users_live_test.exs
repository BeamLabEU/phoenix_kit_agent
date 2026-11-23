defmodule PhoenixKitAgent.Web.UsersLiveTest do
  @moduledoc """
  Admin → Agent → Users (spec §7, §10): the people who hold `agent`, with their
  model, limits, spending and notice flag, and the form that sets one user's
  settings. Open to `agent.manage` only — on mount and again on every event.
  """

  use PhoenixKitAgent.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.{ModuleRegistry, Settings}
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKitAgent.Config
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Test.{LogProbe, Tools}
  alias PhoenixKitAgent.UserConfig
  alias PhoenixKitAgent.Web.UsersLive

  @path "/en/admin/agent/users"
  @stub __MODULE__

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    # What the models can do comes from the AI module's capabilities, never
    # from a request of the page.
    Req.Test.stub(@stub, fn _conn -> flunk("the page asked a provider") end)
    PhoenixKitAI.Guard.reset_caches()
    on_exit(&PhoenixKitAI.Guard.reset_caches/0)

    :ok
  end

  defp manager, do: user_with(["agent", "agent.manage"], "manager")

  # An endpoint whose model's tools an admin declared.
  defp declared(attrs, tools) do
    model = Map.fetch!(attrs, :model)

    endpoint_fixture(
      Map.put(attrs, :provider_settings, %{
        "capabilities" => %{"model" => model, "tools" => tools}
      })
    )
  end

  defp activity do
    Repo.all(
      from(a in PhoenixKit.Activity.Entry, where: a.action == "agent.user_settings_updated")
    )
  end

  defp spend!(user, endpoint, cost) do
    Repo.insert!(%PhoenixKitAI.Request{
      endpoint_uuid: endpoint.uuid,
      user_uuid: user.uuid,
      model: endpoint.model,
      status: "success",
      cost: journal_cost(cost),
      metadata: %{"source" => "agent"},
      inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
  end

  describe "with agent.manage: the list" do
    setup %{conn: conn} do
      admin = manager()
      %{conn: log_in(conn, admin), admin: admin}
    end

    test "lists the people who hold agent, not the others", %{conn: conn, admin: admin} do
      member = user_with(["agent"], "member")
      stranger = user_with(["dashboard"], "stranger")

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#agent-users")
      assert has_element?(view, "#agent-user-#{member.uuid}")
      assert has_element?(view, "#agent-user-#{admin.uuid}")
      refute has_element?(view, "#agent-user-#{stranger.uuid}")
    end

    test "shows the model, the limits, the spending and the notice flag", %{conn: conn} do
      member = user_with(["agent"], "member")
      endpoint = endpoint_fixture(%{name: "Own model", model: "a/with-tools"})

      Repo.insert!(%UserSettings{
        user_uuid: member.uuid,
        endpoint_uuid: endpoint.uuid,
        daily_cost_limit_micro_usd: 250_000,
        daily_turn_limit: 7,
        notify_on_limit: true
      })

      spend!(member, endpoint, 120_000)
      spend!(member, endpoint, 30_000)

      {:ok, view, _html} = live(conn, @path)
      row = "#agent-user-#{member.uuid}"

      assert has_element?(view, "#{row}-model", "Own model")
      assert has_element?(view, "#{row}-limits", "0.25")
      assert has_element?(view, "#{row}-limits", "10")
      assert has_element?(view, "#{row}-limits", "7")
      assert has_element?(view, "#{row}-day", "0.15")
      assert has_element?(view, "#{row}-month", "0.15")
      assert has_element?(view, "#{row}-notify[data-on]")
    end

    test "a user without settings shows the module defaults and no spending", %{conn: conn} do
      member = user_with(["agent"], "member")
      default = endpoint_fixture(%{name: "Module model", model: "a/with-tools"})
      {:ok, _} = PhoenixKit.Settings.update_setting("agent_default_endpoint_uuid", default.uuid)

      {:ok, view, _html} = live(conn, @path)
      row = "#agent-user-#{member.uuid}"

      assert has_element?(view, "#{row}-model", "Module model")
      assert has_element?(view, "#{row}-limits", "200")
      assert has_element?(view, "#{row}-day", "0")
      refute has_element?(view, "#{row}-notify[data-on]")
      refute has_element?(view, "#{row}-status[data-off]")
    end

    test "a model that reports no cost: money is marked as not counted", %{conn: conn} do
      counted = user_with(["agent"], "counted")
      direct = user_with(["agent"], "direct")
      openrouter = endpoint_fixture(%{name: "Router", model: "a/with-tools"})
      deepseek = endpoint_fixture(%{name: "Direct", provider: "deepseek", model: "deepseek-chat"})
      Repo.insert!(%UserSettings{user_uuid: counted.uuid, endpoint_uuid: openrouter.uuid})
      Repo.insert!(%UserSettings{user_uuid: direct.uuid, endpoint_uuid: deepseek.uuid})

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#agent-user-#{direct.uuid}-money-off", "only the turn limit")
      refute has_element?(view, "#agent-user-#{counted.uuid}-money-off")
    end

    test "an Anthropic list price or a manual price counts money; no price is marked", %{
      conn: conn
    } do
      claude =
        endpoint_fixture(%{name: "Claude", provider: "anthropic", model: "claude-sonnet-5-5"})

      manual =
        endpoint_fixture(
          %{
            name: "Priced",
            provider: "deepseek",
            model: "deepseek-chat",
            provider_settings: %{"pricing" => %{"input" => "0.27", "output" => "1.1"}}
          },
          scope: scope_of(owner_fixture())
        )

      unpriced = endpoint_fixture(%{name: "Unpriced", provider: "anthropic", model: "claude-x-1"})

      users =
        for {tag, endpoint} <- [claude: claude, manual: manual, unpriced: unpriced] do
          user = user_with(["agent"], Atom.to_string(tag))
          Repo.insert!(%UserSettings{user_uuid: user.uuid, endpoint_uuid: endpoint.uuid})
          {tag, user}
        end

      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#agent-user-#{users[:claude].uuid}-money-off")
      refute has_element?(view, "#agent-user-#{users[:manual].uuid}-money-off")
      assert has_element?(view, "#agent-user-#{users[:unpriced].uuid}-money-off")
    end

    test "a user the assistant is switched off for is marked", %{conn: conn} do
      member = user_with(["agent"], "member")
      Repo.insert!(%UserSettings{user_uuid: member.uuid, enabled: false})

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#agent-user-#{member.uuid}-status[data-off]")
    end
  end

  defmodule NoTranscribe do
    @moduledoc false
  end

  # An endpoint whose model's abilities an admin declared.
  defp capable(flags, attrs) do
    model = Map.get(attrs, :model, "a/model-#{System.unique_integer([:positive])}")

    endpoint_fixture(
      attrs
      |> Map.put(:model, model)
      |> Map.put(:provider_settings, %{"capabilities" => Map.put(flags, "model", model)})
    )
  end

  defp all_round(attrs \\ %{}),
    do: capable(%{"tools" => "yes", "vision" => "yes", "audio_input" => "yes"}, attrs)

  defp allow!(endpoints),
    do: {:ok, _} = Config.put_selectable_endpoints(Enum.map(endpoints, & &1.uuid), [])

  defp switch_off!(endpoint) do
    Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^endpoint.uuid),
      set: [enabled: false]
    )
  end

  describe "with agent.manage: the three models" do
    setup %{conn: conn} do
      admin = manager()
      member = user_with(["agent"], "member")

      %{
        conn: log_in(conn, admin),
        admin: admin,
        member: member,
        chat: all_round(%{name: "Chatty"}),
        pictures: all_round(%{name: "Seer"}),
        speech: all_round(%{name: "Ear"}),
        blind:
          capable(%{"tools" => "yes", "vision" => "no", "audio_input" => "no"}, %{name: "Blind"}),
        plain:
          capable(%{"tools" => "no", "vision" => "yes", "audio_input" => "yes"}, %{name: "Plain"})
      }
    end

    test "the form has a field for each of chat, pictures and speech, each with the default",
         ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", ctx.chat.uuid)
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", ctx.pictures.uuid)
      view = open(ctx.conn, ctx.member)

      for field <- ~w(agent-user-endpoint agent-user-vision-endpoint agent-user-speech-endpoint) do
        assert has_element?(view, "##{field}")
        assert has_element?(view, "##{field} option[value='']", "Default:")
        assert has_element?(view, "##{field} option[value='#{ctx.chat.uuid}']")
        assert has_element?(view, "##{field} option[value='#{ctx.blind.uuid}']")
      end

      assert has_element?(view, "#agent-user-endpoint option[value='']", "Chatty")
      assert has_element?(view, "#agent-user-vision-endpoint option[value='']", "Seer")
      assert has_element?(view, "#agent-user-speech-endpoint option[value='']", "none set")
    end

    test "each field marks the endpoints that do not fit its task", ctx do
      view = open(ctx.conn, ctx.member)
      _ = render_async(view)

      assert has_element?(
               view,
               "#agent-user-endpoint option[value='#{ctx.plain.uuid}']",
               "no tools"
             )

      refute has_element?(
               view,
               "#agent-user-endpoint option[value='#{ctx.blind.uuid}']",
               "no tools"
             )

      assert has_element?(
               view,
               "#agent-user-vision-endpoint option[value='#{ctx.blind.uuid}']",
               "does not take pictures"
             )

      refute has_element?(
               view,
               "#agent-user-vision-endpoint option[value='#{ctx.pictures.uuid}']",
               "does not take"
             )

      assert has_element?(
               view,
               "#agent-user-speech-endpoint option[value='#{ctx.blind.uuid}']",
               "does not take audio"
             )
    end

    test "an administrator saves each of the three, and Activity names the field", ctx do
      for {field, endpoint} <- [
            endpoint_uuid: ctx.chat,
            vision_endpoint_uuid: ctx.pictures,
            speech_endpoint_uuid: ctx.speech
          ] do
        view = open(ctx.conn, ctx.member)

        view
        |> form("#agent-user-form", user_settings: %{field => endpoint.uuid})
        |> render_submit()

        assert has_element?(view, "#flash-info")
        assert Map.fetch!(Repo.get!(UserSettings, ctx.member.uuid), field) == endpoint.uuid
      end

      row = Repo.get!(UserSettings, ctx.member.uuid)

      assert {row.endpoint_uuid, row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {ctx.chat.uuid, ctx.pictures.uuid, ctx.speech.uuid}

      fields = activity() |> Enum.flat_map(& &1.metadata["fields"]) |> Enum.sort()
      assert fields == ~w(endpoint_uuid speech_endpoint_uuid vision_endpoint_uuid)
    end

    test "the three models are saved in one submit", ctx do
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form",
        user_settings: %{
          endpoint_uuid: ctx.chat.uuid,
          vision_endpoint_uuid: ctx.pictures.uuid,
          speech_endpoint_uuid: ctx.speech.uuid
        }
      )
      |> render_submit()

      row = Repo.get!(UserSettings, ctx.member.uuid)

      assert {row.endpoint_uuid, row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {ctx.chat.uuid, ctx.pictures.uuid, ctx.speech.uuid}
    end

    test "choosing the default clears that field only", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        endpoint_uuid: ctx.chat.uuid,
        vision_endpoint_uuid: ctx.pictures.uuid,
        speech_endpoint_uuid: ctx.speech.uuid
      })

      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{vision_endpoint_uuid: ""})
      |> render_submit()

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.vision_endpoint_uuid == nil
      assert row.endpoint_uuid == ctx.chat.uuid
      assert row.speech_endpoint_uuid == ctx.speech.uuid
    end

    test "a save that changes another field never clears a model", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        vision_endpoint_uuid: ctx.pictures.uuid,
        speech_endpoint_uuid: ctx.speech.uuid
      })

      view = open(ctx.conn, ctx.member)
      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "3"}) |> render_submit()

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 3

      assert {row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {ctx.pictures.uuid, ctx.speech.uuid}

      # A submit that does not carry the model fields at all, as an old form sends it.
      view = open(ctx.conn, ctx.member)
      render_hook(view, "save_user", %{"user_settings" => %{"daily_turn_limit" => "4"}})

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 4

      assert {row.vision_endpoint_uuid, row.speech_endpoint_uuid} ==
               {ctx.pictures.uuid, ctx.speech.uuid}
    end

    test "a model the user chose after the form opened is not written over", ctx do
      allow!([ctx.pictures])
      view = open(ctx.conn, ctx.member)
      {ref, _token} = session_fixture(ctx.member)

      assert {:ok, [:vision_endpoint_uuid]} =
               UserConfig.put_personal_models(
                 ref,
                 %{"vision_endpoint_uuid" => ctx.pictures.uuid},
                 impersonated: false
               )

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "9"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.vision_endpoint_uuid == ctx.pictures.uuid
      assert row.daily_turn_limit == nil
    end

    test "a refusal is shown at its own field, and nothing is saved", ctx do
      cases = [
        {"agent-user-endpoint", :endpoint_uuid, ctx.plain, "does not take tools"},
        {"agent-user-vision-endpoint", :vision_endpoint_uuid, ctx.blind,
         "does not take pictures"},
        {"agent-user-speech-endpoint", :speech_endpoint_uuid, ctx.blind, "does not take audio"}
      ]

      for {dom, field, endpoint, text} <- cases do
        view = open(ctx.conn, ctx.member)

        view
        |> form("#agent-user-form", user_settings: %{field => endpoint.uuid})
        |> render_submit()

        assert has_element?(view, "##{dom}-field p.text-error", text)

        for {other, _, _, _} <- cases, other != dom do
          refute has_element?(view, "##{other}-field p.text-error")
        end

        assert Repo.get(UserSettings, ctx.member.uuid) == nil
      end
    end

    test "a model nobody knows fits is refused at its field", ctx do
      unknown = endpoint_fixture(%{name: "Unknown", model: "a/never-heard-of"})
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{vision_endpoint_uuid: unknown.uuid})
      |> render_submit()

      assert has_element?(
               view,
               "#agent-user-vision-endpoint-field p.text-error",
               "nobody knows whether its model takes pictures"
             )
    end

    test "an endpoint the form did not offer is refused for each field", ctx do
      tts = endpoint_fixture(%{name: "Voice", model: "a/some-tts"})
      view = open(ctx.conn, ctx.member)

      for field <- ~w(endpoint_uuid vision_endpoint_uuid speech_endpoint_uuid),
          value <- [tts.uuid, Ecto.UUID.generate(), "nonsense"] do
        render_hook(view, "save_user", %{"user_settings" => %{field => value}})
        assert Repo.get(UserSettings, ctx.member.uuid) == nil
        assert has_element?(view, "#agent-user-form p.text-error")
      end
    end

    test "an administrator may set a model that is not on the list users choose from", ctx do
      allow!([ctx.chat])
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{vision_endpoint_uuid: ctx.pictures.uuid})
      |> render_submit()

      assert Repo.get!(UserSettings, ctx.member.uuid).vision_endpoint_uuid == ctx.pictures.uuid

      view = open(ctx.conn, ctx.member)
      assert has_element?(view, "#agent-user-vision-endpoint-effective[data-source='own']")
      assert has_element?(view, "#agent-user-vision-endpoint-outside-list")
      refute has_element?(view, "#agent-user-endpoint-outside-list")
    end

    test "says what is in effect: the default, an own model, the default instead of an unusable one",
         ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", ctx.chat.uuid)

      view = open(ctx.conn, ctx.member)

      assert has_element?(view, "#agent-user-endpoint-effective[data-source='default']", "Chatty")

      assert has_element?(
               view,
               "#agent-user-vision-endpoint-effective[data-source='default']",
               "none set"
             )

      refute has_element?(view, "#agent-user-endpoint-outside-list")

      allow!([ctx.pictures, ctx.speech])

      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        vision_endpoint_uuid: ctx.pictures.uuid,
        speech_endpoint_uuid: ctx.speech.uuid
      })

      view = open(ctx.conn, ctx.member)

      assert has_element?(
               view,
               "#agent-user-vision-endpoint-effective[data-source='own']",
               "Seer"
             )

      assert has_element?(view, "#agent-user-speech-endpoint-effective[data-source='own']", "Ear")
      refute has_element?(view, "#agent-user-vision-endpoint-outside-list")

      switch_off!(ctx.pictures)
      view = open(ctx.conn, ctx.member)

      assert has_element?(view, "#agent-user-vision-endpoint-effective[data-source='fallback']")
      assert has_element?(view, "#agent-user-vision-endpoint-effective", "cannot be used")
      assert has_element?(view, "#agent-user-speech-endpoint-effective[data-source='own']")
      # The model the user has stays chosen in the field, so a save does not drop it.
      assert has_element?(
               view,
               "#agent-user-vision-endpoint option[value='#{ctx.pictures.uuid}'][selected]"
             )
    end

    test "the list shows where the chat model comes from, also when the own one fell back", ctx do
      {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", ctx.chat.uuid)
      working = user_with(["agent"], "working")
      broken = user_with(["agent"], "broken")
      plain_user = user_with(["agent"], "plain-user")
      Repo.insert!(%UserSettings{user_uuid: working.uuid, endpoint_uuid: ctx.pictures.uuid})
      Repo.insert!(%UserSettings{user_uuid: broken.uuid, endpoint_uuid: ctx.speech.uuid})
      switch_off!(ctx.speech)

      {:ok, view, _html} = live(ctx.conn, @path)

      assert has_element?(view, "#agent-user-#{working.uuid}-model", "Seer")
      refute has_element?(view, "#agent-user-#{working.uuid}-model", "module default")
      refute has_element?(view, "#agent-user-#{working.uuid}-model-fallback")

      assert has_element?(view, "#agent-user-#{broken.uuid}-model", "Chatty")
      assert has_element?(view, "#agent-user-#{broken.uuid}-model", "module default")
      assert has_element?(view, "#agent-user-#{broken.uuid}-model-fallback")

      assert has_element?(view, "#agent-user-#{plain_user.uuid}-model", "module default")
      refute has_element?(view, "#agent-user-#{plain_user.uuid}-model-fallback")
    end

    test "money not counted is warned of per task, for the model chosen or the default", ctx do
      bare =
        capable(%{"tools" => "yes", "vision" => "yes", "audio_input" => "yes"}, %{
          name: "Bare",
          provider: "deepseek",
          model: "deepseek-chat"
        })

      view = open(ctx.conn, ctx.member)

      for {dom, field} <- [
            {"agent-user-money-off", :endpoint_uuid},
            {"agent-user-vision-endpoint-money-off", :vision_endpoint_uuid},
            {"agent-user-speech-endpoint-money-off", :speech_endpoint_uuid}
          ] do
        refute has_element?(view, "##{dom}")

        view
        |> form("#agent-user-form", user_settings: %{field => bare.uuid})
        |> render_change()

        assert has_element?(view, "##{dom}", "money is not counted")

        view
        |> form("#agent-user-form", user_settings: %{field => ctx.chat.uuid})
        |> render_change()

        refute has_element?(view, "##{dom}")
      end

      # The default of a task counts when nothing own is chosen.
      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", bare.uuid)
      view = open(ctx.conn, ctx.member)
      assert has_element?(view, "#agent-user-vision-endpoint-money-off")
      refute has_element?(view, "#agent-user-speech-endpoint-money-off")
    end

    test "the selects point to what is said under them", ctx do
      view = open(ctx.conn, ctx.member)

      for dom <- ~w(agent-user-endpoint agent-user-vision-endpoint agent-user-speech-endpoint) do
        assert has_element?(view, "select##{dom}[aria-describedby='#{dom}-effective']")
        assert has_element?(view, "##{dom}-effective")
      end
    end

    test "a fallback with no default says that none is set, and why a model fails", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        vision_endpoint_uuid: ctx.pictures.uuid
      })

      switch_off!(ctx.pictures)
      view = open(ctx.conn, ctx.member)

      assert has_element?(
               view,
               "#agent-user-vision-endpoint-effective[data-source='fallback']",
               "no default is set"
             )

      refute has_element?(view, "#agent-user-vision-endpoint-effective", "none set")
      assert has_element?(view, "#agent-user-vision-endpoint-effective", "no longer a chat model")

      {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", ctx.chat.uuid)
      view = open(ctx.conn, ctx.member)

      assert has_element?(view, "#agent-user-vision-endpoint-effective", "Chatty")
      refute has_element?(view, "#agent-user-vision-endpoint-effective", "no default is set")
    end

    test "without a speech-writing AI module the speech field is gone and a crafted value is refused",
         ctx do
      Application.put_env(:phoenix_kit_agent, :speech_ai, __MODULE__.NoTranscribe)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)

      view = open(ctx.conn, ctx.member)
      refute has_element?(view, "#agent-user-speech-endpoint")

      render_hook(view, "save_user", %{
        "user_settings" => %{"speech_endpoint_uuid" => ctx.speech.uuid}
      })

      assert Repo.get(UserSettings, ctx.member.uuid) == nil
      assert has_element?(view, "#flash-error")
    end

    test "the form is laid out to stack on a phone", ctx do
      view = open(ctx.conn, ctx.member)

      assert has_element?(view, "#agent-user-form .grid.grid-cols-1[class*='sm:grid-cols-2']")
      assert has_element?(view, "#agent-user-endpoint-field.min-w-0")
      assert has_element?(view, "#agent-user-vision-endpoint-field.min-w-0")
      refute has_element?(view, "#agent-user-form [class*='w-['][class*='px]']")
    end

    test "agent.manage is checked again for the new fields", ctx do
      view = open(ctx.conn, ctx.member)

      [role] =
        ctx.admin
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent.manage")

      view
      |> form("#agent-user-form", user_settings: %{vision_endpoint_uuid: ctx.pictures.uuid})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Repo.get(UserSettings, ctx.member.uuid) == nil
    end
  end

  describe "what the page does with the result of the save" do
    defp socket_with(editing) do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, editing: editing}
      }
    end

    defp editing_form,
      do: %{params: %{}, errors: %{}, user: %{uuid: Ecto.UUID.generate()}}

    test "a refusal that comes from the save is shown at the field it names" do
      cases = [
        {:model_unfit, [:tools], :endpoint_uuid, "does not take tools"},
        {:model_unverified, [:tools], :endpoint_uuid, "whether its model takes tools"},
        {:model_unfit, [:vision], :vision_endpoint_uuid, "does not take pictures"},
        {:model_unverified, [:vision], :vision_endpoint_uuid, "whether its model takes pictures"},
        {:model_unfit, [:audio_input], :speech_endpoint_uuid, "does not take audio"},
        {:model_unverified, [:audio_input], :speech_endpoint_uuid,
         "whether its model takes audio"}
      ]

      for {reason, needs, field, text} <- cases do
        socket =
          UsersLive.after_update(
            {:error, {reason, needs, field}},
            socket_with(editing_form()),
            editing_form(),
            %{}
          )

        assert [message] = socket.assigns.editing.errors[field]
        assert message =~ text
        assert Map.keys(socket.assigns.editing.errors) == [field]
        assert socket.assigns.flash["error"]
      end
    end
  end

  describe "an Owner's models" do
    test "a manager who is not an Owner cannot set them, not even with a crafted submit", %{
      conn: conn
    } do
      owner = owner_fixture()
      pictures = all_round()
      {:ok, view, _html} = live(log_in(conn, manager()), @path)

      render_hook(view, "configure", %{"user" => owner.uuid})

      render_hook(view, "save_user", %{
        "user_settings" => %{"vision_endpoint_uuid" => pictures.uuid}
      })

      assert Repo.get(UserSettings, owner.uuid) == nil
    end

    test "an Owner sets his models", %{conn: conn} do
      owner = owner_fixture()
      pictures = all_round()
      {:ok, view, _html} = live(log_in(conn, owner), @path)

      view |> element("#agent-user-configure-#{owner.uuid}") |> render_click()

      view
      |> form("#agent-user-form", user_settings: %{vision_endpoint_uuid: pictures.uuid})
      |> render_submit()

      assert Repo.get!(UserSettings, owner.uuid).vision_endpoint_uuid == pictures.uuid
    end
  end

  describe "with agent.manage: the form" do
    setup %{conn: conn} do
      admin = manager()
      member = user_with(["agent"], "member")
      with_tools = declared(%{name: "Fast", model: "a/with-tools"}, "yes")
      no_tools = declared(%{name: "Plain", model: "a/no-tools"}, "no")
      other = endpoint_fixture(%{name: "Other", provider: "deepseek", model: "deepseek-chat"})

      %{
        conn: log_in(conn, admin),
        admin: admin,
        member: member,
        with_tools: with_tools,
        no_tools: no_tools,
        other: other
      }
    end

    defp open(conn, member) do
      {:ok, view, _html} = live(conn, @path)
      view |> element("#agent-user-configure-#{member.uuid}") |> render_click()
      assert has_element?(view, "#agent-user-form")
      view
    end

    test "opens for one user with the settings as they are", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        system_prompt: "Be brief.",
        daily_cost_limit_micro_usd: 500_000,
        daily_turn_limit: 9
      })

      view = open(ctx.conn, ctx.member)

      assert has_element?(
               view,
               "#agent-user-form textarea[name='user_settings[system_prompt]']",
               "Be brief."
             )

      assert has_element?(
               view,
               "#agent-user-form input[name='user_settings[daily_turn_limit]'][value='9']"
             )

      assert has_element?(
               view,
               "#agent-user-form input[name='user_settings[daily_cost_limit_usd]'][value='0.5']"
             )

      assert has_element?(
               view,
               "#agent-user-form input[name='user_settings[monthly_cost_limit_usd]'][value='']"
             )
    end

    test "the form says when the chosen model's money is not counted", ctx do
      view = open(ctx.conn, ctx.member)
      refute has_element?(view, "#agent-user-money-off")

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: ctx.other.uuid})
      |> render_change()

      assert has_element?(view, "#agent-user-money-off", "only the turn limit")

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: ctx.with_tools.uuid})
      |> render_change()

      refute has_element?(view, "#agent-user-money-off")
    end

    test "the form counts money on an Anthropic model with a list price", ctx do
      claude =
        endpoint_fixture(%{name: "Claude", provider: "anthropic", model: "claude-sonnet-5-5"})

      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: ctx.other.uuid})
      |> render_change()

      assert has_element?(view, "#agent-user-money-off")

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: claude.uuid})
      |> render_change()

      refute has_element?(view, "#agent-user-money-off")
    end

    test "the choice is the phoenix_kit_ai endpoints, with the ones without tools marked", ctx do
      view = open(ctx.conn, ctx.member)
      option = fn endpoint -> "#agent-user-endpoint option[value='#{endpoint.uuid}']" end

      assert has_element?(view, option.(ctx.with_tools))
      assert has_element?(view, option.(ctx.no_tools))
      assert has_element?(view, option.(ctx.other))

      # The listing arrives after the form opens.
      _ = render_async(view)

      refute has_element?(view, option.(ctx.with_tools), "no tools")
      assert has_element?(view, option.(ctx.no_tools), "no tools")
      assert has_element?(view, option.(ctx.other), "unknown")
    end

    test "saves, records who in Activity, and shows the new values in the list", ctx do
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form",
        user_settings: %{
          endpoint_uuid: ctx.with_tools.uuid,
          system_prompt: "ADMIN-SECRET-PROMPT",
          daily_cost_limit_usd: "2,5",
          daily_turn_limit: "12",
          notify_on_limit: "true",
          enabled: ""
        }
      )
      |> render_submit()

      assert has_element?(view, "#flash-info")
      refute has_element?(view, "#agent-user-form")

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.endpoint_uuid == ctx.with_tools.uuid
      assert row.system_prompt == "ADMIN-SECRET-PROMPT"
      assert row.daily_cost_limit_micro_usd == 2_500_000
      assert row.daily_turn_limit == 12
      assert row.notify_on_limit
      assert row.updated_by_uuid == ctx.admin.uuid

      assert [entry] = activity()
      assert entry.actor_uuid == ctx.admin.uuid
      assert entry.resource_uuid == ctx.member.uuid
      refute inspect(entry) =~ "ADMIN-SECRET-PROMPT"

      assert has_element?(view, "#agent-user-#{ctx.member.uuid}-model", "Fast")
      assert has_element?(view, "#agent-user-#{ctx.member.uuid}-limits", "2.5")
    end

    test "the prompt for the user never reaches the log", ctx do
      secret = "SecretUserPrompt-#{System.unique_integer([:positive])}"
      view = open(ctx.conn, ctx.member)

      {_, logs} =
        LogProbe.capture(fn ->
          view
          |> form("#agent-user-form", user_settings: %{system_prompt: secret})
          |> render_change()

          view
          |> form("#agent-user-form", user_settings: %{system_prompt: secret})
          |> render_submit()
        end)

      assert Repo.get!(UserSettings, ctx.member.uuid).system_prompt == secret
      for line <- logs, do: refute(line =~ secret, "leaked to the log: " <> line)
    end

    test "switching the user off", ctx do
      view = open(ctx.conn, ctx.member)

      view |> form("#agent-user-form", user_settings: %{enabled: "false"}) |> render_submit()

      assert %UserSettings{enabled: false} = Repo.get!(UserSettings, ctx.member.uuid)
      assert has_element?(view, "#agent-user-#{ctx.member.uuid}-status[data-off]")
    end

    test "blank fields go back to the module default", ctx do
      Repo.insert!(%UserSettings{
        user_uuid: ctx.member.uuid,
        endpoint_uuid: ctx.with_tools.uuid,
        daily_turn_limit: 9
      })

      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: "", daily_turn_limit: ""})
      |> render_submit()

      assert %UserSettings{endpoint_uuid: nil, daily_turn_limit: nil} =
               Repo.get!(UserSettings, ctx.member.uuid)
    end

    test "an invalid value is shown as an error and nothing is saved", ctx do
      view = open(ctx.conn, ctx.member)

      for {field, value} <- [
            daily_turn_limit: "lots",
            daily_turn_limit: "-3",
            daily_cost_limit_usd: "much",
            monthly_cost_limit_usd: "0,0000001",
            max_attachment_mb: "1.5"
          ] do
        view |> form("#agent-user-form", user_settings: %{field => value}) |> render_submit()

        assert has_element?(view, "#agent-user-form p.text-error"), "#{field}=#{value}"
      end

      assert Repo.get(UserSettings, ctx.member.uuid) == nil
      assert activity() == []
    end

    test "the typed text stays in the form after an error", ctx do
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form",
        user_settings: %{system_prompt: "KEEP-THIS", daily_turn_limit: "lots"}
      )
      |> render_submit()

      assert has_element?(view, "#agent-user-form textarea", "KEEP-THIS")
    end

    test "what the form does not offer cannot be written by a forged submit", ctx do
      stranger = user_with(["agent"], "stranger")
      view = open(ctx.conn, ctx.member)

      render_hook(view, "save_user", %{
        "user_settings" => %{
          "daily_turn_limit" => "4",
          "personal_instructions" => "FORGED",
          "busy_turn_ref" => "forged",
          "busy_since" => "2026-01-01T00:00:00Z",
          "updated_by_uuid" => stranger.uuid,
          "notify_user_uuids" => [stranger.uuid],
          "user_uuid" => stranger.uuid
        },
        "user_uuid" => stranger.uuid
      })

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 4
      assert row.personal_instructions == nil
      assert row.busy_turn_ref == nil
      assert row.busy_since == nil
      assert row.updated_by_uuid == ctx.admin.uuid
      assert row.notify_user_uuids == []
      assert Repo.get(UserSettings, stranger.uuid) == nil
    end

    test "a new model the assistant's AI task cannot use is refused, with why", ctx do
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: ctx.no_tools.uuid})
      |> render_submit()

      assert has_element?(view, "#agent-user-form p.text-error", "does not take tools")
      assert Repo.get(UserSettings, ctx.member.uuid) == nil

      view
      |> form("#agent-user-form", user_settings: %{endpoint_uuid: ctx.other.uuid})
      |> render_submit()

      assert has_element?(
               view,
               "#agent-user-form p.text-error",
               "nobody knows whether its model takes tools"
             )

      assert Repo.get(UserSettings, ctx.member.uuid) == nil
    end

    test "the user's model kept as it is is not checked again", ctx do
      Repo.insert!(%UserSettings{user_uuid: ctx.member.uuid, endpoint_uuid: ctx.other.uuid})
      view = open(ctx.conn, ctx.member)

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "3"}) |> render_submit()

      assert has_element?(view, "#flash-info")

      assert %UserSettings{endpoint_uuid: endpoint_uuid, daily_turn_limit: 3} =
               Repo.get!(UserSettings, ctx.member.uuid)

      assert endpoint_uuid == ctx.other.uuid
    end

    test "an endpoint that was not offered is refused", ctx do
      tts = endpoint_fixture(%{name: "Voice", model: "a/some-tts"})
      view = open(ctx.conn, ctx.member)

      render_hook(view, "save_user", %{"user_settings" => %{"endpoint_uuid" => tts.uuid}})
      assert Repo.get(UserSettings, ctx.member.uuid) == nil

      render_hook(view, "save_user", %{
        "user_settings" => %{"endpoint_uuid" => Ecto.UUID.generate()}
      })

      assert Repo.get(UserSettings, ctx.member.uuid) == nil
      assert has_element?(view, "#agent-user-form p.text-error")
    end

    test "a user without the agent permission cannot be opened or saved", ctx do
      stranger = user_with(["dashboard"], "stranger")
      {:ok, view, _html} = live(ctx.conn, @path)

      render_hook(view, "configure", %{"user" => stranger.uuid})
      refute has_element?(view, "#agent-user-form")

      render_hook(view, "save_user", %{"user_settings" => %{"daily_turn_limit" => "1"}})
      assert Repo.get(UserSettings, stranger.uuid) == nil

      render_hook(view, "configure", %{"user" => "nonsense"})
      refute has_element?(view, "#agent-user-form")
    end

    test "events without their fields change nothing and do not crash", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)

      render_hook(view, "save_user", %{})
      render_hook(view, "save_user", %{"user_settings" => %{"daily_turn_limit" => "1"}})
      render_hook(view, "configure", %{})
      render_hook(view, "cancel", %{})

      assert has_element?(view, "#agent-users")
      assert Repo.aggregate(UserSettings, :count) == 0
    end

    test "cancel closes the form", ctx do
      view = open(ctx.conn, ctx.member)

      view |> element("#agent-user-cancel") |> render_click()

      refute has_element?(view, "#agent-user-form")
    end

    test "agent.manage is checked again at every submit", ctx do
      view = open(ctx.conn, ctx.member)

      [role] =
        ctx.admin
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent.manage")

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "1"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Repo.get(UserSettings, ctx.member.uuid) == nil
      assert activity() == []
    end

    test "nor does a revoked right let the form open", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)

      [role] =
        ctx.admin
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent.manage")

      render_hook(view, "configure", %{"user" => ctx.member.uuid})

      refute has_element?(view, "#agent-user-form")
    end
  end

  describe "with agent.manage: what the form is checked against" do
    setup %{conn: conn} do
      admin = manager()
      member = user_with(["agent"], "member")
      endpoint = endpoint_fixture(%{name: "Fast", model: "a/with-tools"})
      %{conn: log_in(conn, admin), admin: admin, member: member, endpoint: endpoint}
    end

    test "a user who lost agent while the form was open is not saved", ctx do
      view = open(ctx.conn, ctx.member)

      [role] =
        ctx.member
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent")

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "1"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#agent-user-form")
      assert Repo.get(UserSettings, ctx.member.uuid) == nil
    end

    test "a save over another admin's change is refused, the change stays", ctx do
      view = open(ctx.conn, ctx.member)

      other_admin = scope_of(manager())

      {:ok, _, _} =
        UserConfig.admin_update(other_admin, ctx.member.uuid, %{"daily_turn_limit" => "5"})

      view
      |> form("#agent-user-form", user_settings: %{system_prompt: "Stale form"})
      |> render_submit()

      assert has_element?(view, "#flash-error")
      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 5
      assert row.system_prompt == nil

      # Opened again, the form shows the change and saves.
      view |> element("#agent-user-configure-#{ctx.member.uuid}") |> render_click()

      view
      |> form("#agent-user-form", user_settings: %{system_prompt: "Fresh form"})
      |> render_submit()

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 5
      assert row.system_prompt == "Fresh form"
    end

    test "whole numbers are read as typed in a decimal field", ctx do
      view = open(ctx.conn, ctx.member)

      view
      |> form("#agent-user-form",
        user_settings: %{daily_turn_limit: "1 000", max_attachments_per_message: "3,0"}
      )
      |> render_submit()

      row = Repo.get!(UserSettings, ctx.member.uuid)
      assert row.daily_turn_limit == 1_000
      assert row.max_attachments_per_message == 3
    end

    test "the page keeps no AI endpoint with its key", ctx do
      view = open(ctx.conn, ctx.member)
      _ = render_async(view)

      state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
      refute state =~ "sk-or-v1-test-key"
      refute state =~ "PhoenixKitAI.Endpoint"
    end

    test "a user given agent after the page opened can be configured", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)
      late = user_with(["agent"], "late")

      render_hook(view, "configure", %{"user" => late.uuid})

      assert has_element?(view, "#agent-user-form")
    end
  end

  describe "with agent.manage: what the user's assistant can use" do
    setup %{conn: conn} do
      :ok = ModuleRegistry.register(Tools)
      on_exit(fn -> ModuleRegistry.unregister(Tools) end)

      # The manager does not hold `dashboard`: the card is the user's, not theirs.
      %{conn: log_in(conn, manager())}
    end

    defp user_tool(name), do: "#agent-user-tools [data-tool='#{name}']"

    defp user_tool_status(view, name, status),
      do: has_element?(view, user_tool(name) <> "[data-status='#{status}']")

    defp user_tool_reason(view, name, reason),
      do: has_element?(view, user_tool(name) <> " [data-reason='#{reason}']")

    test "the form shows the tools by the user's roles, available or closed and why", %{
      conn: conn
    } do
      member = user_with(["agent", "dashboard"], "member")
      view = open(conn, member)

      assert has_element?(view, "#agent-user-tools-note", "by the user's roles")
      assert has_element?(view, "#agent-user-tools-module-agent_test_tools", "Agent test tools")

      assert user_tool_status(view, "agenttest.list_items", "available")

      assert user_tool_status(view, "agenttest.write_item", "closed")
      assert user_tool_reason(view, "agenttest.write_item", "agent_writes_off")
      refute user_tool_reason(view, "agenttest.write_item", "no_permission")

      assert user_tool_status(view, "agenttest.secret_items", "closed")
      assert user_tool_reason(view, "agenttest.secret_items", "no_permission")
    end

    test "a user without the tool's permission: closed to their assistant", %{conn: conn} do
      {:ok, _} = Settings.update_setting("api_session_write_modules", "agent_test_tools")
      member = user_with(["agent"], "member")
      view = open(conn, member)

      assert user_tool_status(view, "agenttest.list_items", "closed")
      assert user_tool_reason(view, "agenttest.list_items", "no_permission")
      assert user_tool_status(view, "agenttest.write_item", "closed")
      assert user_tool_reason(view, "agenttest.write_item", "no_permission")
      refute user_tool_reason(view, "agenttest.write_item", "agent_writes_off")
    end

    test "every role of the user counts, whatever role a session would act as", %{conn: conn} do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")
      member = user_with(["agent"], "member")

      {:ok, second} =
        Roles.create_role(%{name: "AgentTools#{System.unique_integer([:positive])}"})

      {:ok, _} = Permissions.grant_permission(second.uuid, "dashboard")
      {:ok, _} = Roles.assign_role(member, second.name)

      view = open(conn, member)

      assert user_tool_status(view, "agenttest.list_items", "available")
    end

    test "the card closes with the form", %{conn: conn} do
      member = user_with(["agent", "dashboard"], "member")
      view = open(conn, member)

      view |> element("#agent-user-cancel") |> render_click()
      refute has_element?(view, "#agent-user-tools")
    end
  end

  describe "an Owner's settings" do
    test "a manager who is not an Owner can neither open nor save them", %{conn: conn} do
      owner = owner_fixture()
      admin = manager()
      {:ok, view, _html} = live(log_in(conn, admin), @path)

      assert has_element?(view, "#agent-user-#{owner.uuid}")
      refute has_element?(view, "#agent-user-configure-#{owner.uuid}")

      render_hook(view, "configure", %{"user" => owner.uuid})
      refute has_element?(view, "#agent-user-form")
      assert has_element?(view, "#flash-error")
      assert Repo.get(UserSettings, owner.uuid) == nil
    end

    test "an Owner sets them", %{conn: conn} do
      owner = owner_fixture()
      {:ok, view, _html} = live(log_in(conn, owner), @path)

      view |> element("#agent-user-configure-#{owner.uuid}") |> render_click()
      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "4"}) |> render_submit()

      assert %UserSettings{daily_turn_limit: 4} = Repo.get!(UserSettings, owner.uuid)
    end
  end

  describe "the role the session acts as" do
    setup do
      {:ok, _} = Settings.update_setting("role_switcher_enabled", "true")
      :ok
    end

    # A second custom role for `user`, granting `permissions`.
    defp add_role(user, permissions) do
      {:ok, role} = Roles.create_role(%{name: "AgentSecond#{System.unique_integer([:positive])}"})
      for key <- permissions, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
      {:ok, _} = Roles.assign_role(user, role.name)
      role
    end

    test "acting as a role without agent.manage, the page does not open", %{conn: conn} do
      admin = manager()
      plain = add_role(admin, ["agent"])
      {conn, token} = log_in_session(conn, admin)
      act_as(token, plain)

      assert {:error, {:live_redirect, _}} = live(conn, @path)
    end

    test "a switch to a role without agent.manage stops the next submit", %{conn: conn} do
      admin = manager()
      plain = add_role(admin, ["agent"])
      member = user_with(["agent"], "member")
      {conn, token} = log_in_session(conn, admin)

      view = open(conn, member)
      act_as(token, plain)

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "1"}) |> render_submit()

      assert has_element?(view, "#flash-error")
      assert Repo.get(UserSettings, member.uuid) == nil
      assert activity() == []

      view |> element("#agent-user-cancel") |> render_click()
      render_hook(view, "configure", %{"user" => member.uuid})
      refute has_element?(view, "#agent-user-form")
    end

    test "the session's role counts, not the user's default one", %{conn: conn} do
      # The default role (the first one) only uses the assistant.
      admin = user_with(["agent"], "acting")
      managing = add_role(admin, ["agent", "agent.manage"])
      member = user_with(["agent"], "member")
      {conn, token} = log_in_session(conn, admin)
      act_as(token, managing)

      view = open(conn, member)
      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "2"}) |> render_submit()

      assert %UserSettings{daily_turn_limit: 2} = Repo.get!(UserSettings, member.uuid)
    end

    test "a session that was logged out stops the next submit", %{conn: conn} do
      admin = manager()
      member = user_with(["agent"], "member")
      {conn, token} = log_in_session(conn, admin)

      view = open(conn, member)
      :ok = Auth.delete_user_session_token(token)

      view |> form("#agent-user-form", user_settings: %{daily_turn_limit: "1"}) |> render_submit()

      assert Repo.get(UserSettings, member.uuid) == nil
    end
  end

  describe "a user blocked by the AI guard" do
    setup %{conn: conn} do
      {:ok, _} = PhoenixKitAI.enable_system()
      owner = owner_fixture()
      admin = user_with(["agent", "agent.manage"], "manager")
      member = user_with(["agent"], "member")
      %{conn: conn, owner: owner, admin: admin, member: member}
    end

    defp block!(by, user) do
      {:ok, block} =
        PhoenixKitAI.Guard.block(scope_of(by), "agent.chat", user.uuid, "Private chats", nil)

      block
    end

    defp ai_manager(tag) do
      user_with(["agent", "agent.manage", "ai", "ai.manage"], tag)
    end

    test "is marked; the reason only for a viewer with ai.manage", ctx do
      block!(ctx.owner, ctx.member)

      {:ok, view, _html} = live(log_in(ctx.conn, ctx.admin), @path)
      assert has_element?(view, "#agent-user-#{ctx.member.uuid}-blocked")
      refute has_element?(view, "#agent-user-#{ctx.member.uuid}-block-reason")
      refute render(view) =~ "Private chats"

      {:ok, view, _html} = live(log_in(ctx.conn, ai_manager("ai-manager")), @path)
      assert has_element?(view, "#agent-user-#{ctx.member.uuid}-block-reason", "Private chats")

      refute has_element?(view, "#agent-user-#{ctx.admin.uuid}-blocked")
    end

    test "is lifted by a holder of agent.manage", ctx do
      block!(ctx.owner, ctx.member)
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.admin), @path)

      view |> element("#agent-user-lift-#{ctx.member.uuid}") |> render_click()

      assert has_element?(view, "#flash-info")
      refute has_element?(view, "#agent-user-#{ctx.member.uuid}-blocked")
      refute PhoenixKitAI.GuardBlocks.blocked?("agent.chat", ctx.member.uuid)

      assert [%PhoenixKitAI.GuardBlock{lifted_by_uuid: lifted_by}] =
               Repo.all(PhoenixKitAI.GuardBlock)

      assert lifted_by == ctx.admin.uuid
    end

    test "one's own block: no button, and the event is refused", ctx do
      block!(ctx.owner, ctx.admin)
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.admin), @path)

      assert has_element?(view, "#agent-user-#{ctx.admin.uuid}-blocked")
      refute has_element?(view, "#agent-user-lift-#{ctx.admin.uuid}")

      render_hook(view, "lift_block", %{"user" => ctx.admin.uuid})

      assert has_element?(view, "#flash-error")
      assert PhoenixKitAI.GuardBlocks.blocked?("agent.chat", ctx.admin.uuid)
    end

    test "an Owner's block: no button for an Admin, and the event is refused", ctx do
      block!(ctx.owner, ctx.owner)
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.admin), @path)

      refute has_element?(view, "#agent-user-lift-#{ctx.owner.uuid}")
      render_hook(view, "lift_block", %{"user" => ctx.owner.uuid})

      assert has_element?(view, "#flash-error")
      assert PhoenixKitAI.GuardBlocks.blocked?("agent.chat", ctx.owner.uuid)
    end

    test "nothing is lifted once agent.manage is taken away while the page is open", ctx do
      # ai.manage alone would let the guard lift it: the page itself refuses.
      viewer = ai_manager("losing")
      block!(ctx.owner, ctx.member)
      {:ok, view, _html} = live(log_in(ctx.conn, viewer), @path)

      [role] =
        viewer
        |> Roles.get_user_roles()
        |> Enum.reject(&(&1 in ["Owner", "Admin", "User"]))
        |> Enum.map(&Roles.get_role_by_name/1)

      :ok = Permissions.revoke_permission(role.uuid, "agent.manage")

      view |> element("#agent-user-lift-#{ctx.member.uuid}") |> render_click()

      assert has_element?(view, "#flash-error")
      assert PhoenixKitAI.GuardBlocks.blocked?("agent.chat", ctx.member.uuid)
    end

    test "a crafted event without a user, or for one not blocked, changes nothing", ctx do
      {:ok, view, _html} = live(log_in(ctx.conn, ctx.admin), @path)

      render_hook(view, "lift_block", %{})
      render_hook(view, "lift_block", %{"user" => "nonsense"})
      render_hook(view, "lift_block", %{"user" => ctx.member.uuid})

      assert has_element?(view, "#agent-users")
      assert Repo.all(PhoenixKitAI.GuardBlock) == []
    end
  end

  describe "without agent.manage" do
    test "the page does not open for a user who only uses the assistant", %{conn: conn} do
      conn = log_in(conn, user_with(["agent"], "user"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, @path)
      refute to =~ "agent/users"
    end

    test "nobody signed in is sent away", %{conn: conn} do
      assert {:error, {:live_redirect, _}} = live(conn, @path)
    end
  end
end
