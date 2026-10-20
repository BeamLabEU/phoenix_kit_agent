defmodule PhoenixKitAgent.ModelsTest do
  @moduledoc """
  The choice of a model for a user (spec §7.2): only `phoenix_kit_ai` endpoints
  that can chat, each with whether its model is known to take tools. OpenRouter
  publishes that per model; for other providers `phoenix_kit_ai` has no
  capability listing, so the answer is "unknown".
  """

  use PhoenixKitAgent.DataCase, async: false

  alias PhoenixKitAgent.Models

  @stub __MODULE__

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  # The OpenRouter `/models` listing.
  defp listing(models) do
    %{
      "data" =>
        Enum.map(models, fn {id, parameters} ->
          %{
            "id" => id,
            "name" => id,
            "supported_parameters" => parameters,
            "architecture" => %{"modality" => "text->text"}
          }
        end)
    }
  end

  defp serve_models(models, calls \\ 1) do
    test = self()

    Req.Test.expect(
      @stub,
      calls,
      fn conn ->
        send(test, {:models_requested, conn.request_path})
        Req.Test.json(conn, listing(models))
      end
    )
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

  describe "tools_support/1" do
    test "OpenRouter says per model whether it takes tools" do
      with_tools = endpoint_fixture(%{model: "a/with-tools"})
      without = endpoint_fixture(%{model: "a/without-tools"})
      missing = endpoint_fixture(%{model: "a/not-listed"})

      serve_models([
        {"a/with-tools", ["temperature", "tools"]},
        {"a/without-tools", ["temperature"]}
      ])

      assert Models.tools_support([with_tools, without, missing]) == %{
               with_tools.uuid => :supported,
               without.uuid => :unsupported,
               missing.uuid => :unknown
             }
    end

    test "endpoints that share a connection are answered by one request" do
      one = endpoint_fixture(%{model: "a/one", api_key: "sk-or-v1-shared"})
      two = endpoint_fixture(%{model: "a/two", api_key: "sk-or-v1-shared"})

      serve_models([{"a/one", ["tools"]}, {"a/two", []}], 1)

      assert %{} = Models.tools_support([one, two])
      assert_received {:models_requested, "/api/v1/models"}
      refute_received {:models_requested, _}
    end

    test "other providers are unknown, and nothing is asked of them" do
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})

      Req.Test.stub(@stub, fn _conn -> flunk("a provider without a listing was asked") end)

      assert Models.tools_support([deepseek]) == %{deepseek.uuid => :unknown}
    end

    test "a listing that cannot be had leaves the answer unknown" do
      endpoint = endpoint_fixture(%{model: "a/one"})

      Req.Test.expect(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, "{}")
      end)

      assert Models.tools_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "a transport failure leaves the answer unknown" do
      endpoint = endpoint_fixture(%{model: "a/one"})
      Req.Test.expect(@stub, &Req.Test.transport_error(&1, :econnrefused))

      assert Models.tools_support([endpoint]) == %{endpoint.uuid => :unknown}
    end

    test "no endpoints, no request" do
      Req.Test.stub(@stub, fn _conn -> flunk("nothing to ask") end)
      assert Models.tools_support([]) == %{}
    end
  end
end
