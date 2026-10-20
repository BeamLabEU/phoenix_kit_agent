defmodule PhoenixKitAgent.Test.Tools do
  @moduledoc """
  A stand-in feature module with admin API tools, for the turn tests: the tools
  a session sees through `PhoenixKit.API.Executor.visible_for/3` and calls
  through `execute_as/5`.

  | Tool | Kind | Scope | Permission |
  |---|---|---|---|
  | `agenttest.list_items` | read | `agenttest.items:read` | `dashboard` |
  | `agenttest.secret_items` | read | `agenttest.secret:read` | `users` |
  | `agenttest.write_item` | write | `agenttest.items:write` | `dashboard` |

  Every handler sends `{:agent_test_tool, name, input, ctx}` to the process in
  `Application.get_env(:phoenix_kit_agent, :test_tool_listener)`.
  `agenttest.write_item` also really writes: the setting `agenttest_written`.
  `agenttest.list_items` with `"size" => n` answers about `n` characters, and
  with `"say" => text` answers `text` as its only item.
  """

  alias PhoenixKit.API.Tool

  @read %{read_only: true, destructive: false, idempotent: true, open_world: false}
  @write %{read_only: false, destructive: false, idempotent: false, open_world: false}

  def module_key, do: "agent_test_tools"
  def module_name, do: "Agent test tools"
  def enabled?, do: true

  def api_tools do
    [
      tool(:list_items, "agenttest.items:read", "dashboard", @read, %{
        "query" => %{"type" => "string"},
        "size" => %{"type" => "integer", "minimum" => 0},
        "say" => %{"type" => "string"}
      }),
      tool(:secret_items, "agenttest.secret:read", "users", @read, %{}),
      tool(:write_item, "agenttest.items:write", "dashboard", @write, %{
        "name" => %{"type" => "string"}
      })
    ]
  end

  def list_items(input, ctx) do
    notify("agenttest.list_items", input, ctx)

    case input do
      %{"size" => size} -> {:ok, %{"items" => [String.duplicate("x", size)]}}
      %{"say" => text} -> {:ok, %{"items" => [text]}}
      _ -> {:ok, %{"items" => ["chair", "table", "lamp"], "query" => input["query"]}}
    end
  end

  def secret_items(input, ctx) do
    notify("agenttest.secret_items", input, ctx)
    {:ok, %{"items" => ["secret"]}}
  end

  def write_item(input, ctx) do
    notify("agenttest.write_item", input, ctx)
    {:ok, _} = PhoenixKit.Settings.update_setting("agenttest_written", "yes")
    {:ok, %{"written" => true}}
  end

  defp notify(name, input, ctx) do
    case Application.get_env(:phoenix_kit_agent, :test_tool_listener) do
      pid when is_pid(pid) -> send(pid, {:agent_test_tool, name, input, ctx})
      _ -> :ok
    end
  end

  defp tool(verb, scope, permission, annotations, properties) do
    Tool.new!(
      name: "agenttest.#{verb}",
      audience: :admin,
      scope: scope,
      permission: permission,
      title: Atom.to_string(verb),
      description: "Test tool #{verb}.",
      input_schema: %{
        "type" => "object",
        "properties" => properties,
        "additionalProperties" => false
      },
      output_schema: %{"type" => "object"},
      handler: {__MODULE__, verb},
      annotations: annotations
    )
  end
end
