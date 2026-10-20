defmodule PhoenixKitAgent.Turns.ToolsTest do
  @moduledoc """
  How tools are shown to the model and what it sends back is taken (spec
  §6.1 b, f; §6.4): MCP names, schemas without control fields, arguments
  without control fields, results cut to the limit.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Tool
  alias PhoenixKitAgent.Turns.Tools

  @control ["dry_run", "confirm_token", "idempotency_key"]

  defp tool(name, annotations, schema \\ nil) do
    Tool.new!(
      name: name,
      audience: :admin,
      scope: "agenttest.items:read",
      permission: "dashboard",
      title: name,
      description: "About #{name}.",
      input_schema:
        schema ||
          %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"],
            "additionalProperties" => false
          },
      handler: {__MODULE__, :none},
      annotations: annotations
    )
  end

  describe "for_model/1" do
    test "a write tool's schema loses the control fields core adds to it" do
      write = tool("agenttest.write_item", %{read_only: false})

      # Core does add them for a write tool — what the model must not see.
      core = Executor.input_schema(write)
      assert Enum.all?(["dry_run", "confirm_token"], &Map.has_key?(core["properties"], &1))

      {[definition], by_name} = Tools.for_model([write])
      parameters = definition["function"]["parameters"]

      for field <- @control do
        refute Map.has_key?(parameters["properties"], field)
        refute field in (parameters["required"] || [])
      end

      assert parameters["properties"]["name"] == %{"type" => "string"}
      assert parameters["required"] == ["name"]
      assert definition["function"]["name"] == "agenttest_write_item"
      assert by_name == %{"agenttest_write_item" => write}
    end

    test "a name a model API cannot take is left out; one MCP name, the first tool" do
      long = tool("agenttest." <> String.duplicate("a", 60), %{read_only: true})
      first = tool("agenttest.a_b", %{read_only: true})
      second = tool("agenttest_a.b", %{read_only: true})

      {definitions, by_name} = Tools.for_model([long, first, second])

      assert Enum.map(definitions, & &1["function"]["name"]) == ["agenttest_a_b"]
      assert by_name == %{"agenttest_a_b" => first}
    end
  end

  describe "arguments/1" do
    test "a JSON object, without control fields" do
      json = Jason.encode!(%{"q" => 1, "dry_run" => false, "confirm_token" => "t"})
      assert Tools.arguments(json) == {:ok, %{"q" => 1}}
      assert Tools.arguments(%{"idempotency_key" => "k", "q" => 2}) == {:ok, %{"q" => 2}}
    end

    test "anything else is :error" do
      for bad <- ["nope", "[1,2]", "3", nil, 42] do
        assert Tools.arguments(bad) == :error
      end
    end
  end

  describe "fit/2" do
    test "a short result is kept as it is" do
      assert Tools.fit(%{"a" => 1}, 500) == %{"a" => 1}
    end

    test "a long one is cut so its own JSON fits the limit, even with quotes to escape" do
      for filler <- ["x", ~s(")] do
        result = %{"items" => [String.duplicate(filler, 3_000)]}
        fitted = Tools.fit(result, 500)

        assert fitted["truncated"] == true
        assert is_binary(fitted["hint"])
        assert String.length(Jason.encode!(fitted)) <= 500
        assert String.starts_with?(Jason.encode!(result), fitted["partial"])
      end
    end
  end
end
