defmodule PhoenixKitAgent.ModelsTest do
  @moduledoc """
  The choice of a model for a user (spec §7.2): only `phoenix_kit_ai` endpoints
  that can chat, each with whether its model is known to take tools or
  images — what `PhoenixKitAI.Capabilities` knows (a catalogue, or what an
  admin declared on the endpoint), never asked of the provider here.
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Models

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
end
