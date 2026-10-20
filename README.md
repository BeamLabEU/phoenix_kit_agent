# PhoenixKitAgent

An AI agent module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit): a
personal assistant inside the application. Every user gets their own chats kept
in the database, can attach files to a message, and talks to a model that works
through prepared tools from the PhoenixKit API registry. The assistant sees and
does no more than the user can in their current session. Model calls, endpoints,
credentials, budget and the request journal come from
[`phoenix_kit_ai`](https://github.com/BeamLabEU/phoenix_kit_ai).

**Status: under development.** So far: the `PhoenixKit.Module` registration
(module key `agent`) and the enable/disable switch, the module's tables (own
migration chain, run by `mix phoenix_kit.update`), the permissions `agent` and
`agent.manage`, the module defaults under Settings → AI Agent, a hidden Storage
library for attachments and the cleanup when a user is deleted. Chats, the
model loop and the chat UI are not implemented yet.

## Installation

```elixir
def deps do
  [
    {:phoenix_kit_agent, "~> 0.1"}
  ]
end
```

The module requires `phoenix_kit_ai` to be enabled (`required_modules/0` is
`["ai"]`) and is switched on in Admin > Modules; it is off by default
(setting `agent_enabled`).

## Development

```bash
mix deps.get
mix test              # needs a local PostgreSQL; see test/test_helper.exs
mix precommit         # compile --warnings-as-errors + format + credo --strict + dialyzer
```

## License

MIT, see [LICENSE](LICENSE).
