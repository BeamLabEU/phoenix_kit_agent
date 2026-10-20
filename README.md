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
library for attachments and the cleanup when a user is deleted; the chats and
their messages (`PhoenixKitAgent.Conversations` — session-bound, owner-only,
with a PubSub topic per chat) and the read-only turn loop
(`PhoenixKitAgent.Turns` — locks, rounds of model and tool calls over the
session's own read tools, stop and deadline), the per-user settings
(`PhoenixKitAgent.UserConfig` — the user's own value, else the module default:
the model, the admin's prompt, the limits, the on/off switch and the personal
instructions), the system prompt put together in the order of priority
(`PhoenixKitAgent.Prompt`) and Admin → AI Agent → Users, where an admin with
`agent.manage` sees every user's model, limits and spending and sets them. Not
built yet: the chat panel (Dock), enforcing the spending and turn limits and
the notices about them, and attachment processing.

## Configuration

```elixir
# Optional: text the host adds to the assistant's system prompt (what an order
# is, the statuses, the language of the answer). `Mod.fun(%{user_uuid:, locale:})`
# when exported with one argument, else `Mod.fun()`; returns a string or nil.
# An exception or a result that is not a string skips the addendum.
config :phoenix_kit_agent, prompt_addendum: {MyApp.Agent, :prompt}
```

The system prompt of a turn is, in this order: the module's prompt (Settings →
AI Agent), the host's addendum, the admin's prompt for the user, the user's
personal instructions (marked as ranking below the rest), and the context of the
session — the user's name, the role the session acts as, the locale, the date
and time in the site time zone and, if the host passes `page:` to
`PhoenixKitAgent.Turns.start/6`, the page path (and an order number, if given).

The Settings page has one switch only an Owner can change,
`agent_capture_ai_content`: when on, the bodies of the assistant's requests are
written to the AI request journal and every holder of the `ai` permission reads
them on `/admin/ai/usage`.

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
