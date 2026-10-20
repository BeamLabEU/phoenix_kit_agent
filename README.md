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
(`PhoenixKitAgent.Prompt`), Admin → AI Agent → Users, where an admin with
`agent.manage` sees every user's model, limits and spending and sets them, the
spending and turn limits (`PhoenixKitAgent.Limits` — checked before each turn,
with a notice in the chat and notifications to the user and the watchers) and
Admin → AI Agent → Spending, what everyone spent today and this month, and the
attachments (`PhoenixKitAgent.Attachments` — files added to a chat, kept in the
hidden library and made readable for the model before the turn). Not built
yet: the chat panel (Dock).

## Attachments

A user adds png/jpg/webp/heic pictures, PDFs, xlsx/csv sheets and txt/md
files to their own chat. The content decides what a file is, not its name or
the type the browser claimed. A file is kept in the module's hidden Storage
library, in a folder named by the user's uuid: it is in no media picker or
browser, not even for a holder of `media.view_all`, and its bytes are reached
only through `PhoenixKitAgent.Attachments.url/3`, an expiring address minted
for the owner's own session. The size and the number of files per message come
from the user's settings (`max_attachment_mb`, `max_attachments_per_message`).

Before the turn a task makes each file readable, and the row goes from
`pending` to `ready` (or `failed`, with a code in `error`): a PDF gives its
text; a PDF with no text (a scan) and a picture are shown to a model that takes
images as pixels, shrunk to 1600 px, in the message they came with only; for a
model that does not, the vision model (setting `agent_vision_endpoint_uuid`)
describes them once and the description is kept in the history; a sheet
becomes CSV text, the first rows of each sheet; a text file is read as it is.
All of it is cut to a size (`config :phoenix_kit_agent, attachment_limits:
[…]`, see `PhoenixKitAgent.Attachments.Bounds`) and the row says when it was
cut.

PDF processing needs poppler (`pdfinfo`, `pdftotext`, `pdftoppm`) and pictures
need ImageMagick (`convert`, `identify`) on the host; without them such a file
fails with `pdf_tools_missing` / `image_tools_missing`, nothing else breaks.

## Limits

Per user, the user's own value else the module default (Settings → AI Agent):
money per day and per month and turns per day. Money is what the AI request
journal of `phoenix_kit_ai` recorded for the user's assistant calls
(`metadata.source = "agent"`, attachment descriptions included), in
micro-dollars (`$1 = 1_000_000`); a turn is one message the user sent. The day
and the month are those of the site time zone. Money counts only on an endpoint
that reports what a call cost (today OpenRouter); on another only the turn
limit applies, and the admin pages say so.

The limits are checked when a turn starts; a turn that started under them runs
to its end. A limit used up refuses the turn with a notice in the chat. The
user is told in the app at 80 % of a limit and when it is reached; the
watchers (setting `agent_limit_watchers`, empty meaning every Owner, plus the
user's own `notify_user_uuids`) get a notification of type `agent_limit` when
the user's `notify_on_limit` is on, and whenever the `phoenix_kit_ai` budget
refuses the user's assistant — each at most once per limit and period.

"Stop" and the turn deadline ask the turn to stop between its steps, so a model
call under way finishes and its cost reaches the journal; a turn still running
after the grace period (`config :phoenix_kit_agent, turn_stop_grace_ms:`,
default 30 000) is killed.

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
