defmodule PhoenixKitAgent.ModelsTest do
  @moduledoc """
  The choice of a model for a user (spec §7.2): only `phoenix_kit_ai` endpoints
  that can chat, each with whether its model is known to take tools or
  images — what `PhoenixKitAI.Capabilities` knows (a catalogue, or what an
  admin declared on the endpoint), never asked of the provider here.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAgent.{Config, Models}

  @stub __MODULE__

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  describe "list_endpoints/1" do
    test "enabled endpoints that chat, by name" do
      b = endpoint_fixture(%{name: "B chat", model: "a/chat-b"})
      a = endpoint_fixture(%{name: "A chat", model: "a/chat-a"})
      _off = endpoint_fixture(%{name: "Off", model: "a/off", enabled: false})
      _tts = endpoint_fixture(%{name: "Voice", model: "a/some-tts"})
      _embed = endpoint_fixture(%{name: "Embed", model: "a/text-embedding"})
      _image = endpoint_fixture(%{name: "Image", model: "a/some-image"})

      assert Enum.map(Models.list_endpoints(), & &1.uuid) == [a.uuid, b.uuid]
    end

    test "the endpoint a user has now is listed even when it can no longer be picked" do
      off = endpoint_fixture(%{name: "Off", model: "a/off", enabled: false})
      on = endpoint_fixture(%{name: "On", model: "a/on"})

      assert Enum.map(Models.list_endpoints(include: off.uuid), & &1.uuid) == [off.uuid, on.uuid]
      assert Enum.map(Models.list_endpoints(include: nil), & &1.uuid) == [on.uuid]

      assert Enum.map(Models.list_endpoints(include: Ecto.UUID.generate()), & &1.uuid) == [
               on.uuid
             ]
    end
  end

  # An endpoint whose model's abilities an admin declared (the guard's
  # capabilities, read by `PhoenixKitAI.Capabilities.for_endpoint/1`).
  defp declared(model, flags) do
    endpoint_fixture(%{
      model: model,
      provider_settings: %{"capabilities" => Map.put(flags, "model", model)}
    })
  end

  defp no_network do
    Req.Test.stub(@stub, fn _conn -> flunk("the provider's model list was asked") end)
  end

  describe "image_input_support/1" do
    test "what the AI module knows of the model's images in, and nothing asked of the provider" do
      no_network()
      sees = declared("a/sees", %{"vision" => "yes"})
      blind = declared("a/blind", %{"vision" => "no"})
      unknown = endpoint_fixture(%{model: "a/unknown"})

      assert Models.image_input_support([sees, blind, unknown]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported,
               unknown.uuid => :unknown
             }
    end

    test "a model known for its tools but not for its images is unknown for images, not seeing" do
      tools_only = declared("a/tools-only", %{"tools" => "yes"})

      assert Models.image_input_support([tools_only]) == %{tools_only.uuid => :unknown}
      assert Models.image_input(tools_only.uuid) == :unknown
    end

    test "a declaration made for another model counts for nothing" do
      endpoint =
        endpoint_fixture(%{
          model: "a/now",
          provider_settings: %{"capabilities" => %{"model" => "a/before", "vision" => "yes"}}
        })

      assert Models.image_input_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "image_input/1 reads the endpoint again: a change is seen at once" do
      endpoint = declared("a/eyes", %{"vision" => "no"})
      assert Models.image_input(endpoint.uuid) == :unsupported

      {:ok, _} =
        PhoenixKitAI.update_endpoint(endpoint, %{
          provider_settings: %{"capabilities" => %{"model" => "a/eyes", "vision" => "yes"}}
        })

      assert Models.image_input(endpoint.uuid) == :supported
    end

    test "image_input/1: no endpoint is unknown" do
      assert Models.image_input(nil) == :unknown
      assert Models.image_input(Ecto.UUID.generate()) == :unknown
    end
  end

  describe "tools_support/1" do
    test "what the AI module knows of the model's tools, and nothing asked of the provider" do
      no_network()
      with_tools = declared("a/with-tools", %{"tools" => "yes"})
      without = declared("a/without-tools", %{"tools" => "no"})
      unknown = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      assert Models.tools_support([with_tools, without, unknown]) == %{
               with_tools.uuid => :supported,
               without.uuid => :unsupported,
               unknown.uuid => :unknown
             }

      assert Models.tools_support_of([with_tools.uuid, Ecto.UUID.generate()]) == %{
               with_tools.uuid => :supported
             }
    end

    test "no endpoints, nothing to say" do
      assert Models.tools_support([]) == %{}
    end
  end

  # An Anthropic endpoint with no base URL of its own: a row saved before the
  # registry knew the provider, say. The key it carries is Anthropic's and must
  # reach no other host: the model list was once asked of OpenRouter whenever
  # the URL was blank. Nothing is asked of any provider here: the stub records
  # a request to any host, openrouter.ai or another, and the tests refute it.
  # The blank is `nil` or `""`, both of which a stored row can hold.
  describe "an Anthropic endpoint with a blank base URL" do
    # Shared, so that a request made outside the test process's callers and
    # ancestors (a task started elsewhere) reaches the stub and is recorded.
    setup {Req.Test, :set_req_test_to_shared}

    # Records what is asked of any host and answers an empty list. A flunk
    # would do, but an error in a task that asks is swallowed into "unknown";
    # a message in the mailbox is not.
    defp record_requests do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, {:requested, conn.host, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => [], "has_more" => false})
      end)
    end

    defp anthropic_without_base_url(model, blank, flags \\ nil) do
      attrs = %{provider: "anthropic", model: model, api_key: "sk-ant-key-that-stays-home"}

      attrs =
        if flags,
          do:
            Map.put(attrs, :provider_settings, %{"capabilities" => Map.put(flags, "model", model)}),
          else: attrs

      attrs
      |> endpoint_fixture()
      |> Ecto.Changeset.change(base_url: blank)
      |> Repo.update!()
    end

    test "tools and images are what the AI module knows, and no host is asked" do
      record_requests()

      sees =
        anthropic_without_base_url("claude-sees", nil, %{"tools" => "yes", "vision" => "yes"})

      blind = anthropic_without_base_url("claude-blind", "", %{"tools" => "no", "vision" => "no"})

      assert sees.base_url == nil
      assert blind.base_url == ""

      assert Models.tools_support([sees, blind]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported
             }

      assert Models.image_input_support([sees, blind]) == %{
               sees.uuid => :supported,
               blind.uuid => :unsupported
             }

      assert Models.tools_support_of([sees.uuid]) == %{sees.uuid => :supported}
      assert Models.image_input(sees.uuid) == :supported
      assert Models.image_input(blind.uuid) == :unsupported
      refute_receive {:requested, _host, _authorization}
    end

    test "a model nobody has declared or listed is unknown, and no host is asked" do
      record_requests()

      for blank <- [nil, ""] do
        claude = anthropic_without_base_url("claude-listed-nowhere", blank)

        assert Models.tools_support([claude]) == %{claude.uuid => :unknown}
        assert Models.image_input_support([claude]) == %{claude.uuid => :unknown}
        assert Models.image_input(claude.uuid) == :unknown
      end

      refute_receive {:requested, _host, _authorization}
    end
  end

  describe "usable_uuids/1: what can be called at all" do
    test "an enabled endpoint that chats and has a credential is; others are not" do
      good = endpoint_fixture(%{name: "Good", model: "a/good"})
      off = endpoint_fixture(%{name: "Off", model: "a/off", enabled: false})
      tts = endpoint_fixture(%{name: "Voice", model: "a/some-tts"})
      keyless = endpoint_fixture(%{name: "Keyless", model: "a/keyless", provider: "none-here"})

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^keyless.uuid),
        set: [api_key: "", integration_uuid: nil]
      )

      usable =
        Models.usable_uuids([good.uuid, off.uuid, tts.uuid, keyless.uuid, Ecto.UUID.generate()])

      assert MapSet.to_list(usable) == [good.uuid]
    end

    test "a credential is read through the cache PhoenixKitAI asks, so a change is seen as it sees it" do
      start_supervised!(PhoenixKitAI.Cache)
      key = "cache-probe-#{System.unique_integer([:positive])}"
      keyless = endpoint_fixture(%{name: "Keyless", model: "a/keyless", provider: key})

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^keyless.uuid),
        set: [api_key: "", integration_uuid: nil]
      )

      refute MapSet.member?(Models.usable_uuids([keyless.uuid]), keyless.uuid)

      # The credential appears in the cache PhoenixKitAI reads (as an integration
      # saved elsewhere would after its event) … but only a hit is cached, so a miss
      # is asked again at the source.
      assert {:ok, _} = PhoenixKitAI.Cache.credentials(key, fn -> {:ok, %{"api_key" => "k"}} end)
      assert MapSet.member?(Models.usable_uuids([keyless.uuid]), keyless.uuid)

      PhoenixKitAI.Cache.invalidate_credentials()
      refute MapSet.member?(Models.usable_uuids([keyless.uuid]), keyless.uuid)
    end

    test "nothing asked is nothing read" do
      assert Models.usable_uuids([]) == MapSet.new()
    end
  end

  describe "selection_check/2 and selectable/1: what a user may choose" do
    setup do
      PhoenixKitAI.Guard.reset_caches()
      on_exit(&PhoenixKitAI.Guard.reset_caches/0)
      :ok
    end

    defp listed(endpoints),
      do: {:ok, _} = Config.put_selectable_endpoints(Enum.map(endpoints, & &1.uuid), [])

    test "each task has its AI task" do
      assert Models.task_of(:chat) == "agent.chat"
      assert Models.task_of(:vision) == "agent.attachment"
      assert Models.task_of(:speech) == "agent.speech"
    end

    test "an endpoint outside the list is :not_allowed, for every task" do
      eyes = declared("a/eyes", %{"vision" => "yes", "tools" => "yes", "audio_input" => "yes"})

      for task <- [:chat, :vision, :speech] do
        assert {:error, :not_allowed} = Models.selection_check(task, eyes.uuid)
      end

      assert {:error, :not_allowed} = Models.selection_check(:vision, Ecto.UUID.generate())
      assert {:error, :not_allowed} = Models.selection_check(:vision, "nope")
      assert {:error, :not_allowed} = Models.selection_check(:vision, nil)
      assert Models.selectable(:vision) == []
    end

    test "a listed endpoint passes only for the tasks it fits" do
      eyes = declared("a/eyes", %{"vision" => "yes", "tools" => "no", "audio_input" => "no"})
      listed([eyes])

      assert :ok = Models.selection_check(:vision, eyes.uuid)
      assert {:error, {:model_unfit, [:tools]}} = Models.selection_check(:chat, eyes.uuid)
      assert {:error, {:model_unfit, [:audio_input]}} = Models.selection_check(:speech, eyes.uuid)
    end

    test "a model nobody knows is :model_unverified" do
      unknown = endpoint_fixture(%{model: "a/never-heard-of"})
      listed([unknown])

      assert {:error, {:model_unverified, _unclear}} =
               Models.selection_check(:vision, unknown.uuid)
    end

    test "a listed endpoint that was switched off is :unusable" do
      eyes = declared("a/eyes", %{"vision" => "yes"})
      listed([eyes])

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^eyes.uuid),
        set: [enabled: false]
      )

      assert {:error, :unusable} = Models.selection_check(:vision, eyes.uuid)
    end

    test "the uuid of a deleted endpoint left in the list is :not_allowed and is not offered" do
      gone = declared("a/gone", %{"vision" => "yes"})
      kept = declared("a/kept", %{"vision" => "yes"})
      listed([gone, kept])
      {:ok, _} = PhoenixKitAI.delete_endpoint(gone)

      assert gone.uuid in Config.selectable_endpoint_uuids()
      assert {:error, :not_allowed} = Models.selection_check(:vision, gone.uuid)
      assert :ok = Models.selection_check(:vision, kept.uuid)
      assert Enum.map(Models.selectable(:vision), & &1.uuid) == [kept.uuid]
    end

    test "selectable/1 offers the listed endpoints that fit the task, by name, as summaries" do
      b = declared("a/b", %{"vision" => "yes"}) |> rename("B eyes")
      a = declared("a/a", %{"vision" => "yes"}) |> rename("A eyes")
      blind = declared("a/blind", %{"vision" => "no"}) |> rename("Blind")
      off = declared("a/off", %{"vision" => "yes"}) |> rename("Off")
      outsider = declared("a/outsider", %{"vision" => "yes"}) |> rename("Outsider")

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^off.uuid),
        set: [enabled: false]
      )

      listed([b, a, blind, off])

      offered = Models.selectable(:vision)

      assert Enum.map(offered, & &1.uuid) == [a.uuid, b.uuid]

      assert Enum.all?(
               offered,
               &(Map.keys(&1) |> Enum.sort() ==
                   [:costs, :enabled?, :model, :name, :provider, :reports_cost?, :uuid])
             )

      refute outsider.uuid in Enum.map(offered, & &1.uuid)
    end

    defp rename(endpoint, name) do
      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^endpoint.uuid),
        set: [name: name]
      )

      endpoint
    end
  end

  describe "flag_support/2" do
    test "a flag the capabilities do not carry is unknown, not a crash" do
      caps = %{tools: :yes, vision: :no}

      assert Models.flag_support(caps, :tools) == :supported
      assert Models.flag_support(caps, :vision) == :unsupported
      assert Models.flag_support(caps, :audio_input) == :unknown
      assert Models.flag_support(%{audio_input: :unknown}, :audio_input) == :unknown
    end
  end

  describe "reports_cost?/2" do
    # A manual price on the endpoint: whole micro-dollars per 1M tokens. Setting
    # one needs ai.manage (an Owner).
    defp manual_priced(model) do
      endpoint_fixture(
        %{
          provider: "deepseek",
          model: model,
          provider_settings: %{"pricing" => %{"input" => "0.27", "output" => "1.1"}}
        },
        scope: scope_of(owner_fixture())
      )
    end

    test "OpenRouter reports what a call cost" do
      assert Models.reports_cost?(endpoint_fixture())
    end

    test "an Anthropic model with a list price is counted; one without is not" do
      assert Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
             )

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"})
             )
    end

    test "a manual price on the endpoint is counted; no price is not" do
      assert Models.reports_cost?(manual_priced("deepseek-chat"))

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
             )
    end

    test "a summary carries the answer, never the endpoint's key" do
      priced = manual_priced("deepseek-chat")
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      bare = endpoint_fixture(%{provider: "deepseek", model: "deepseek-reasoner"})

      for endpoint <- [priced, claude, bare] do
        summary = Models.summary(endpoint)
        assert Models.summaries([endpoint.uuid]) == %{endpoint.uuid => summary}
        refute Map.has_key?(summary, :api_key)
        assert Models.reports_cost?(summary) == Models.reports_cost?(endpoint)
      end

      assert Models.summary(priced).reports_cost?
      assert Models.summary(claude).reports_cost?
      refute Models.summary(bare).reports_cost?
    end

    test "a summary says per kind of call whether money is counted, and whether the endpoint is on" do
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})
      bare = endpoint_fixture(%{provider: "deepseek", model: "deepseek-reasoner"})

      assert Models.summary(claude).costs == %{chat: true, vision: true, speech: true}
      assert Models.summary(bare).costs == %{chat: false, vision: false, speech: false}

      for kind <- [:chat, :vision, :speech] do
        assert Models.reports_cost?(Models.summary(claude), kind)
        refute Models.reports_cost?(Models.summary(bare), kind)

        assert Models.reports_cost?(Models.summary(claude), kind) ==
                 Models.reports_cost?(claude, kind)
      end

      assert Models.summary(bare).enabled?

      Repo.update_all(from(e in PhoenixKitAI.Endpoint, where: e.uuid == ^bare.uuid),
        set: [enabled: false]
      )

      refute Models.summaries([bare.uuid])[bare.uuid].enabled?
    end

    test "a picture's description is counted where a chat call on the model would be" do
      claude = endpoint_fixture(%{provider: "anthropic", model: "claude-sonnet-5-5"})

      assert Models.reports_cost?(endpoint_fixture(), :vision)
      assert Models.reports_cost?(claude, :vision)
      assert Models.reports_cost?(manual_priced("deepseek-chat"), :vision)

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "anthropic", model: "claude-unknown-9"}),
               :vision
             )

      refute Models.reports_cost?(
               endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"}),
               :vision
             )
    end

    test "no endpoint is not counted" do
      refute Models.reports_cost?(nil)
      refute Models.reports_cost?(nil, :vision)
    end
  end
end
