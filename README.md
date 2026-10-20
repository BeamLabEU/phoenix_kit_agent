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
hidden library and made readable for the model before the turn), and the chat
panel in the admin header (`PhoenixKitAgent.Web.Dock`).

## The chat panel

A user with the `agent` permission gets a button before the notifications bell
in the admin header (the module's header widget, `header_widgets/0`; no panel
while the module is off or the session is impersonated). It opens the list of
their chats — "New chat" on top, then the chats with the newest message first,
20 at a time and "More", each with its time and "Rename" / "Archive" — and the
panel on the right, about 400 px wide (it can be dragged wider), which narrows
the page; on a phone it takes the whole screen. The panel has the feed, the
input with a paper clip for files, "Stop", an indicator of what the assistant
is doing (thinking / calling a tool), and a small form for the user's own
personal instructions. "New chat" empties the panel; the chat is made with its
first message or file, and takes its title from that message (a first message
or file that is refused leaves no chat behind). A long chat opens at its end,
with "Earlier messages" above. Open or closed, the chosen chat and the width are
kept in the browser (`localStorage`) and come back after a navigation, a reload
or a lost connection (a running answer comes back with its indicator and
"Stop"); the text being written is never wiped by an update of the panel.
Notices are shown in the user's language by their code.

What the panel shows of a chat: the user's messages, the model's answers as
markdown without anything that loads by itself — no `<img>` with an outside
address (a picture in an answer is its alt text), no raw HTML, every link
opening in a new tab with `rel="noopener noreferrer nofollow"` and its domain
written beside it (an address whose host is not plain ASCII is written as text,
not linked) — the notices, and each tool call folded to its summary (the
tool, the outcome, how many it found), never what the tool returned. A chat
whose turn was lost with its node (a restart) gets the notice "the answer was
interrupted" when it is opened, and is free again.

The panel works only in the connected mount of a session that is its user's
own and not borrowed: it reads the session reference and the impersonation
flag itself, and passes them with every call, so each one is checked against
the session's scope at that moment; the static render shows nothing of the
user. It does not log events (LiveView would log their parameters, the user's
text), and an exception in an event is caught and logged as its class only (a
crash report would carry the draft). The panel's classes come from the
module's sources (`css_sources/0`), and its browser hooks are runtime colocated
hooks, so the host bundles nothing for it; it needs core's admin layout with
header widgets and the dock column. The hooks are inline scripts without a
nonce: a host with a Content-Security-Policy must allow `script-src
'unsafe-inline'`, or the panel shows but does not remember its state, resize
or send on Enter.
The tools called from the panel get the user's locale and the endpoint's URL as
their request context, and the client address only when the host's LiveView
socket passes `:peer_data` and `:x_headers` in its `connect_info`.

## Attachments

A user adds png/jpg/webp/heic pictures, PDFs, xlsx/csv sheets and txt/md
files to their own chat. The content decides what a file is, not its name or
the type the browser claimed. A file is kept in the module's hidden Storage
library, in a folder named by the user's uuid: it is in no media picker or
browser, not even for a holder of `media.view_all`, and its bytes are reached
only through `PhoenixKitAgent.Attachments.url/3`, an expiring address minted
for the owner's own session. The size and the number of files per message come
from the user's settings (`max_attachment_mb`, `max_attachments_per_message`);
a user also has no more than 20 files waiting for a message in all their chats,
a failed one included, until they discard it. Discarding a file removes its bytes
from Storage unless another attachment uses them, and Storage is given a
neutral name for the file, not the user's. A text, CSV or Markdown file must be
UTF-8: one saved by Excel in a code page or as UTF-16 is refused with its own
reason (`unsupported_encoding`), and bytes that are not UTF-8 inside a file show
as U+FFFD.

Before the turn a task makes each file readable, and the row goes from
`pending` to `ready` (or `failed`, with a code in `error`): a PDF gives its
text; a PDF with no text (a scan) and a picture are shown to a model known to
take images as pixels, shrunk to 1600 px, in the message they came with only;
for any other model the vision model (setting `agent_vision_endpoint_uuid`)
describes them once and the description is kept in the history; a sheet
becomes CSV text, the first rows of each sheet; a text file is read as it is.
All of it is cut to a size (`config :phoenix_kit_agent, attachment_limits:
[…]`, see `PhoenixKitAgent.Attachments.Bounds`), between rows where there are
rows, and the sheets of a workbook share that size, so one large sheet does not
push the others out. A text that holds less than its file ends with a line the
model reads, such as `[... the sheet continues: 1240 of 1300 rows not shown in
full]` or `[... the workbook continues: 2 more sheets not shown: Q3, Q4]`, so it
does not take part of the data for all of it; the attachments of one message
share `agent_history_chars` between them, and one cut to its share there says
so too.

How a picture reaches the model (decided 2026-10-20):

  * A model known to take images (OpenRouter lists what each model takes) is
    sent the pixels in the picture's own turn only; later turns carry a line
    that names the file and the assistant's own earlier answer, not a second
    (paid) description.
  * A model whose abilities are not known (any provider but OpenRouter, or a
    model that declares nothing) is taken for a blind one: the vision model
    describes the picture. With no vision model set, `Attachments.add/4`
    refuses a picture at once (`no_vision_model`), before anything is stored;
    a scan, known to be one only once it is read, fails with the same code.
    Pixels are never sent on a guess, also not when the model changes between
    the upload and the send (the turn then gets a note instead).
  * When the first model call of a turn that carries pictures is refused by
    the provider (`api_error`, `model_error`), the files are taken off the
    message, the notice says so, and they wait to be sent again.

A JPEG for a model has its metadata removed (EXIF with the time and place of a
photo, XMP, IPTC, comments; `Attachments.Jpeg`). A workbook is never opened by
trusting the sizes its zip declares: its parts are inflated by the module
(`Attachments.Unzip`) against one budget, and the file is `too_large` when the
budget is spent. A worker that is killed for its deadline or its heap leaves
nothing in the temporary directory: the copy of the file lives in a private
directory (`Attachments.Work`) that the supervising process removes, and what
is still left after a node crash is swept at start-up and when a new one is
made. At most `concurrent_jobs` files (8) are processed at the same time on a
node, of them at most `jobs_per_user` (3) one user's; the others wait for a
place, in turn, up to `queue_wait_ms` (30 s), with at most `queued_jobs` (64)
waiting on the node, and are refused as `unavailable` after that
(`Attachments.Slots`). The limits are read at each decision. A workbook is
unpacked within `sheet_unzipped_bytes` (40 MB), and a job holds its parts twice,
so the binary memory a busy node may use for workbooks is about
`concurrent_jobs × 2 × 40 MB`. A row that is still `pending` after the wait and
the processing deadline (the node restarted) is read as `failed`/`timeout`.

The `path` of an upload given to `Attachments.add/4` is trusted: it must be the
temporary file of LiveView's own upload, never a value from the client.

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
limit applies, and the admin pages say so. A picture's description is held to
the money limits of the **vision** endpoint it is paid on, not of the chat
endpoint: when the vision endpoint reports no cost, the money limits do not
cover descriptions at all (only the turn limit and the `phoenix_kit_ai` budget
stop them): such an endpoint reports no cost to count.

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
