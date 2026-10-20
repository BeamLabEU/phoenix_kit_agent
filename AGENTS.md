# AGENTS.md

Guidance for AI agents working on `phoenix_kit_agent`.

## Overview

AI agent module for PhoenixKit: per-user chats stored in the database, file
attachments, a managed system prompt, and a model-and-tools loop over the
PhoenixKit API registry. It implements the `PhoenixKit.Module` behaviour for
auto-discovery by the host application; it is a library, and the host supplies
endpoint and router (`config/` exists only for tests).

**Status: under development.** In place: module registration and the
enable/disable switch (`PhoenixKitAgent`), the module-owned migration chain and
its tables (`PhoenixKitAgent.Migrations`, `PhoenixKitAgent.Schemas.*`), the
permission keys `agent` / `agent.manage`, the module settings and the
Settings → AI Agent page (`PhoenixKitAgent.Config`,
`PhoenixKitAgent.Web.SettingsLive`), the hidden Storage library
(`PhoenixKitAgent.Library`), the user-deletion cleanup
(`PhoenixKitAgent.UserDeletion`), the chats and messages
(`PhoenixKitAgent.Conversations`: session-bound, owner-only; a client writes
only the user's text and never reads raw tool results) and the read-only turn
loop (`PhoenixKitAgent.Turns` with `Turns.Monitor`, `Runner`, `Locks`, `Tools`),
the per-user settings (`PhoenixKitAgent.UserConfig`: `effective/1` is the one
place a turn reads them — user value, else module default; `admin_update/3`
for an admin with `agent.manage`, which logs field names to Activity;
`put_personal_instructions/3` for the user's own text), the system prompt
(`PhoenixKitAgent.Prompt`, spec §7.1, with the host's `prompt_addendum`), the
endpoint choice (`PhoenixKitAgent.Models`: only `phoenix_kit_ai` endpoints that
chat, marked for tool support), the spending read from the AI journal
(`PhoenixKitAgent.Spend`), Admin → AI Agent → Users
(`PhoenixKitAgent.Web.UsersLive`), the limits and their notices
(`PhoenixKitAgent.Limits`: checked by `Turns.start/6` under the turn's locks;
one notice per limit and period through `phoenix_kit_agent_limit_events`;
notification type `agent_limit` from `notification_types/0`) and Admin → AI
Agent → Spending (`PhoenixKitAgent.Web.SpendingLive`) and the attachments
(`PhoenixKitAgent.Attachments` with `Attachments.Detect`, `Extract`, `Processor`,
`Cmd`, `Bounds`, `Unzip`, `Jpeg`, `Work`) and the chat panel
(`PhoenixKitAgent.Web.Dock`, the module's header widget, with
`Web.Dock.Panel` (markup and hooks), `Web.Dock.Components`, `Web.Dock.Texts`
and `Web.Markdown`).

- **Depends on:** `phoenix_kit` and `phoenix_kit_ai` — for now git pins to the
  `timujinne` forks' `integration/andi-2026-10` branches (the session-actor API,
  hidden Storage libraries and tool calling are not on Hex yet),
  `phoenix_live_view`, and `mdex` (already phoenix_kit's) for the markdown
  of the chat panel.
- **Module key** `"agent"`; settings prefix `agent_`; tables
  `phoenix_kit_agent_*` (marker `pk_agent_schema:<N>` on
  `phoenix_kit_agent_conversations`).
- **Permissions:** `agent` (use the assistant) and `agent.manage` (defaults,
  other users' settings, spending; core auto-grants it to Admin). Do not add an
  `agent.view_all`: it would be auto-granted to Admin too.
- **Admin pages:** every event re-checks the permission against fresh scopes
  (`PhoenixKitAgent.Web.Access`): `agent.manage` for the Users page and the
  Settings page, and `Scope.owner?` — not just the tab's `agent.manage`, which
  an Admin holds — for `agent_capture_ai_content`. A form takes only the fields
  it offers; the user being edited is the one the server opened, never a
  submitted uuid.
- **Money and turns:** money only from the AI journal (`user_uuid` +
  `metadata.source = "agent"`), never from the module's own messages; every
  model call of the module passes `user_uuid:` and `source: "agent"`. Turns
  from the `user` messages with a `turn_ref`. The limit check runs under the
  locks, so the previous turn's spending is in. A turn is never killed
  outright: "Stop" and the deadline ask it to stop between steps
  (`Turns.Monitor.check_stop/0`), and only after `turn_stop_grace_ms` is it
  killed.
- **Attachments:** session-bound like `Conversations` (`impersonated:` in the
  options); only the owner adds, reads, discards or gets the address of a
  file, an Owner/Admin of the site included. Bytes live in the hidden library
  (`PhoenixKitAgent.Library`) and leave only through `Attachments.url/3`
  (`Storage.authorized_url/4` for the session's scope) — never a Media URL.
  The content, not the name, decides the kind (`Attachments.Detect`). Files are
  processed in a task under `PhoenixKitAgent.Attachments.TaskSupervisor`
  (`children/0`), with a deadline and a heap limit; a failure is a code in
  `attachments.error`, never a parser's message. A workbook is read with
  `Attachments.Unzip` (never `:zip.extract` — declared sizes are the uploader's),
  a JPEG for a model goes through `Attachments.Jpeg.strip_metadata/1`, and
  every temporary file or directory is made by `Attachments.Work` (private,
  random, removed by the supervising process, not the worker that may be
  killed). Storage is given a neutral file name (it logs names). Concurrency is
  `Bounds.concurrent_jobs` (and `jobs_per_user`), enforced by the waiting
  queue `Attachments.Slots` (a place is held by the job process, free when it
  ends); workers run under their own supervisor. A picture reaches the model as
  pixels in its own turn (`Attachments.model_parts/3`, used by `Turns.Runner`)
  only for a model known to take images; any other (unknown abilities
  included) gets a description kept in the row, or a `no_vision_model`
  refusal (`Processor.picture_mode/1`). Every extractor that cuts a file ends
  its text with a `[... the … continues: …]` line (`Extract.continues/1`) —
  keep that for a new kind. Children in `children/0` need ids of their own
  (`PhoenixKitAgent.…`): PhoenixKit.Supervisor starts every module's children
  in one list. Writes
  that bind a file name or its text use `log: false`. Tests that need poppler
  or ImageMagick carry `@tag :poppler` / `:imagemagick` and are excluded, with a
  message, where the program is missing.
- **The chat panel** (`Web.Dock`): the widget's session carries only the
  user's uuid and locale (`header_widget_session/1`); the session reference and
  the impersonation flag are read by the panel itself in its **connected**
  mount, never taken from the widget session, params or events, and the static
  render shows nothing of the user. Every event calls `Conversations`, `Turns`,
  `Attachments` or `UserConfig` with them — no Repo query of its own, no
  shortcut through a uuid the browser sent. Model text is rendered only through
  `Web.Markdown` (no `<img>`, no raw HTML, links with domain and
  `rel="noopener noreferrer nofollow"`), a tool call only by its
  `tool_summary`. A refusal is shown through `Web.Dock.Texts`, never as a code.
  The LiveView runs with `log: false` (event parameters are the user's text);
  an exception at a turn's start is caught and logged as its class only. The
  path given to `Attachments.add/4` is LiveView's own upload file
  (`consume_uploaded_entry/3` with `:postpone` until `add/4` is done), and
  `add/4` runs in its task under a guard that logs only the exception's class.
  Browser hooks are runtime colocated hooks (`runtime` attribute), since a
  dependency's extracted hooks would not reach the host's bundle; they live in
  `Web.Dock.Panel` with the elements that use them (a colocated hook is named
  after its module). An element a hook owns is `phx-update="ignore"` (the
  composer's textarea).
- **Prompt input from a browser** (`page:`, `locale:` of `Turns.start/6`) is
  untrusted: `PhoenixKitAgent.Prompt` drops a value with a control character and
  cuts a long one.
- **Boundaries:** nothing about orders, customers or other host domain data
  lives here — the module only knows "tools from the registry". Model calls,
  budget and the request journal stay in `phoenix_kit_ai`.

## Commands

```bash
mix deps.get
mix test                     # needs a local PostgreSQL (test DB phoenix_kit_agent_test)
PK_AGENT_SKIP_DB=1 mix test  # no Postgres: unit tests only (never in CI or before a release)
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer
```

Test database settings come from `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`
(defaults: `localhost`, `postgres`, `postgres`, `phoenix_kit_agent_test`).

`phoenix_kit*` deps resolve from their pin in `mix.exs`. To run against a local
checkout, export `<APP>_PATH` (the dep's app name upper-cased plus `_PATH`, e.g.
`PHOENIX_KIT_PATH=../phoenix_kit`); `pk_dep/3` in `mix.exs` swaps the pin for a
`path:` dep at resolve time. Never commit a hand-edited `path:` tuple.

## Conventions

- `0 tests` is not a pass: a test run that excluded everything proves nothing.
- Do not edit `CHANGELOG.md` or `@version` in `mix.exs` in a pull request.
- Tables are PhoenixKit-style: UUIDv7 primary keys, module-owned migrations.
- Nothing of a chat — the user's text, a model answer, a tool result, a system
  prompt — may reach `Logger` (message, metadata or crash report): log the
  class of a failure only. `test/support/log_probe.ex` checks whole log events
  for it.
