# Changelog

All notable changes to PhoenixKitAgent will be documented in this file.

## Unreleased

### Changed

- The chat panel works under a nonce `Content-Security-Policy`
  (`script-src 'self' 'nonce-…'`, no `'unsafe-inline'`; core's
  `guides/content-security-policy.md`). Its five browser hooks (`.DockState`,
  `.Feed`, `.Composer`, `.Turn`, `.Waiting`) are inline scripts and now carry
  the host's nonce, and the panel, a nested LiveView, restores the nonce in its
  own process so a connected render has it too. Both are feature-detected
  (`PhoenixKitAgent.Web.CSP`): on a core without `PhoenixKitWeb.CSP` nothing
  changes, and a host with a policy still needs `script-src 'unsafe-inline'`
  there. The module renders no inline event handlers and no inline `<style>`.
  `test/phoenix_kit_agent/web/csp_inline_tags_test.exs` fails on a new inline
  tag without the nonce or an inline handler. Inline `style="…"` attributes
  are not covered. (#20)

## 0.4.0 - 2026-11-23

### Upgrade

- Run `mix phoenix_kit.update` in the host application and apply the generated
  migration before serving traffic. Module migration V3 adds nullable picture
  and speech endpoint columns. Existing users inherit the site defaults for
  both until a personal model is set.

### Added

- Administrators can set a user's chat, picture and speech models independently
  and choose which endpoints users may select for themselves. The selection
  list starts empty. Removing an endpoint from the list preserves existing
  assignments.
- **My assistant** in the chat panel shows the models and limits in effect.
  Users can choose an allowed model, return to the default for each task, and
  edit their personal instructions.
- The panel and Telegram use the user's effective models. A usable personal
  picture model describes images even when the chat model supports image input.
  An unavailable personal endpoint falls back to the site default for its task.
- Admin pages identify endpoints whose calls do not report a cost and show
  whether a user's model is personal, inherited or a fallback.

### Fixed

- Stale settings forms preserve newer personal model choices and changes to
  the administrator's selection list. Hidden speech controls preserve stored
  values when transcription is unavailable.
- A rejected choice keeps previously offered options visible without exposing
  the names of unlisted endpoints. The dock shows the refusal even if an
  administrator closes model selection while the form is open.
- The model catalogue includes eligible endpoints beyond the first 500.

## 0.3.0 - 2026-11-15

The assistant in Telegram, voice input, an optional time limit on chats, a
setting for the accepted types of file, and a chat panel that works on a touch
phone and fits into a host's own header.

### Requirements

- **`phoenix_kit >= 3.5.0 and < 4.0.0`** (was `>= 2.64.0`): the chat panel's
  resumable uploads (`UploadManager`, `ResumableUpload`), the linked Telegram
  chat as an actor, and the writes such a chat holds for confirmation.
- **`phoenix_kit_ai ~> 0.27`** (was `~> 0.26`). Voice input needs a
  `phoenix_kit_ai` with `transcribe/3` (0.28 or later); without it, voice is off
  and Settings says so.
- Run `mix phoenix_kit.update` after updating, so the host's crontab gets the
  nightly retention job. There is no new migration of the module's tables.
- To answer Telegram, a host declares `config :phoenix_kit,
  :telegram_updates_reader, {PhoenixKitAgent.Telegram.Reader, :holds?, []}` and
  switches the assistant on in Settings → AI Agent (see the README).

### Added

- **The assistant in Telegram** (`PhoenixKitAgent.Telegram.*`, off by default,
  `agent_telegram_enabled`). A person who linked their Telegram chat to the
  site bot, and whose role has the new opt-in permission `agent.telegram`, writes
  to the bot. The assistant answers there with that person's own rights, model,
  instructions and limits.
  - One reader polls the bot across the cluster. The offset is stored before a
    batch is handed on, so an update is answered at most once.
  - A queue for each chat keeps its messages in order; `/new` starts a new
    conversation and `/help` explains what the bot reads.
  - A requested change is shown as a card with ✅ / ❌ buttons. It is made only
    when the person confirms, and the card is edited to the outcome, also when
    the change was settled on the site.
  - Photos and image documents go into the conversation like a panel upload,
    and an album is one question.
  - Every answer, part and retry is checked against the current link and
    rights before it is sent.
- **Voice input** (`PhoenixKitAgent.Speech`): a speech model
  (`agent_speech_endpoint_uuid`, the AI task `agent.speech`) writes down a
  recording from the panel's microphone into the composer, or a Telegram voice
  message, which is then answered. The limits are checked again right before
  paying, and neither the audio nor the words are logged or kept.
- **An optional time limit on chats** (`agent_retention_days`, Owner only,
  empty by default, which deletes nothing; `PhoenixKitAgent.Retention`,
  `RetentionWorker`). Each night, the chats whose last message is older than
  the period, and the chats users deleted, are deleted for good with their
  messages, attachments and library files. A chat in use is left for the next
  night. Each run ends with a sweep of library files a failed release left
  behind. The page previews what a typed period would delete, and the run is
  recorded in the Activity log (counts only).
- **The accepted types of file** (`agent_attachment_types`, Settings → AI
  Agent): a sublist of png, jpg, webp, heic, pdf, xlsx, csv, txt and md. Empty
  means all of them. The server checks the type by content, also for Telegram
  pictures before they are downloaded.
- **A Storage `file_uuid` in a ready attachment's history line**, and
  `Attachments.file_for_user/2`, so that a host tool can act on the file after
  checking its owner. A confirmed write keeps its `ok` / `failed` counts.
- **The chat panel on a touch phone**: every button is at least 44 × 44 px
  under a coarse pointer, and Enter breaks the line there. A host can show
  the panel's header buttons in its own header (class `pk-agent-compact` on
  `<body>`), and hears `pk-agent:turn` (`start` / `done`) on `window` when the
  panel starts or stops showing a turn.

### Changed

- **The panel's file input** is core's upload manager, with chunked, resumable
  uploads that a lost connection or a reload continues. A file stays with the
  chat it was added in.
- **The panel on live navigation** stays open and keeps the latest message in
  view; a reader who scrolled up keeps their place over a reconnect.
- A chat's Rename and Archive are behind its "⋯" button, and Escape closes
  them.
- A Stop that comes within 600 ms of Send (the second click of a double click)
  is ignored.
- A stale Settings form saves only the fields the person changed, and is
  refused when one of them changed meanwhile.

### Fixed

- A confirmed write whose click was lost, then refused before core reached the
  row, reads as confirmed, not failed.
- A recognition is not paid for when the panel will have given up waiting for
  it.
- Turn and confirmation locks are judged by the database's clock.

## 0.2.0 - 2026-10-27

### Changed

- **Core pin widened to accept core 3.x** (ceiling `< 4.0.0`; the floor is unchanged).

## 0.1.0 - 2026-10-24

First release. An AI assistant inside a PhoenixKit application: every user
gets their own chats, kept in the database, with a model that works through the
tools of the PhoenixKit API registry. It sees and does no more than the user
can in their current session. Model calls, endpoints, credentials, budget and
the request journal come from `phoenix_kit_ai`.

### Requirements

- `phoenix_kit ~> 2.64` with core migrations run up to V223 (`mix
  phoenix_kit.update`), which records the AI journal's cost in dollars. Before
  V223 every limit check fails, and so does every turn.
- `phoenix_kit_ai ~> 0.26`, enabled (`required_modules/0` is `["ai"]`).
- Optional host tools: poppler (`pdfinfo`, `pdftotext`, `pdftoppm`) for PDFs,
  ImageMagick (`convert`, `identify`) for pictures. Without them those files
  fail with `pdf_tools_missing` / `image_tools_missing` and nothing else
  breaks.
- A host with a Content-Security-Policy must allow `script-src
  'unsafe-inline'`; the panel's runtime hooks are inline scripts without a
  nonce.

### Migrations

The module owns its tables through its own chain (`PhoenixKitAgent.Migrations`,
marker `pk_agent_schema:<N>` on `phoenix_kit_agent_conversations`), run by
`mix phoenix_kit.update`:

- **V1:** `phoenix_kit_agent_conversations`, `_messages`, `_attachments`,
  `_user_settings` and `_limit_events`.
- **V2:** `assistant_message_uuid` and `confirmation_uuid` on messages, for
  confirmed writes.

### Added

- **Module registration** (key `agent`, off by default via `agent_enabled`)
  with the permissions `agent` and `agent.manage`.
- **The chat panel in the admin header** (`PhoenixKitAgent.Web.Dock`, a header
  widget). It lists the user's chats, newest first, with rename and archive,
  and docks a resizable panel with the feed, file attachments, Stop, a
  thinking / calling-a-tool indicator and the user's personal instructions.
  The open chat and width survive navigation, reloads and reconnects. Answers
  render as markdown with no remote images or raw HTML, and links open in a
  new tab with their domain shown. Tool calls appear as a summary only. No
  panel while the module is off or the session is impersonated, and the host
  bundles no JS or CSS for it.
- **The turn loop** (`PhoenixKitAgent.Turns`): rounds of model and tool calls
  over the session's own tools (`Executor.visible_for/3`, `execute_as/5`), with
  per-chat locks, Stop, a turn deadline and grace-period kill, Stop across
  nodes over PubSub, and recovery of turns lost with their node.
- **Writes the user confirms** (`PhoenixKitAgent.Confirmations`). The assistant
  sees a module's write tools only when that module's "Agent may act" box is
  ticked in Settings → API. A write ends the turn with a card showing core's
  preview: Run (re-checked under the clicking session), Cancel the change, or
  Ask again once it expired. One waiting change per answer, one card per
  change. The model reads the outcome as a fixed phrase, never the tool's
  result.
- **Attachments** (`PhoenixKitAgent.Attachments`): png/jpg/webp/heic, PDF,
  xlsx/csv and txt/md, recognised by content. They are kept in a hidden
  Storage library reachable only through expiring owner-session URLs. Before
  the turn, PDFs become text and sheets become CSV. Pictures go to the model
  as pixels when it is known to take images, otherwise the vision model
  (`agent_vision_endpoint_uuid`) describes them. Everything is cut to
  configurable bounds with a visible "continues" line. JPEG metadata is
  stripped, workbooks are unzipped against a byte budget, and processing slots
  are capped per node and per user.
- **Limits** (`PhoenixKitAgent.Limits`): money per day and month and turns per
  day, per user or the module default, counted from the AI journal in the
  site time zone. They are checked before each turn, with a chat notice and
  `agent_limit` notifications at 80 % and 100 % to the user and the watchers
  (`agent_limit_watchers`, default every Owner).
- **The AI task guard:** the `agent.chat` and `agent.attachment` tasks
  (`ai_tasks/0`). Each turn is admitted once, a blocked user or a task over its
  limit gets a notice, off-purpose requests are flagged through a marker that
  is stripped from the stored answer, and models that don't fit the task are
  refused in the settings forms.
- **System prompt** (`PhoenixKitAgent.Prompt`), in this order: the module's
  prompt and its write rule, the host's `prompt_addendum`, the admin's prompt
  for the user, the user's instructions, and the session context (name, role,
  locale, date, page path and the host's `page_context`).
- **Admin pages:** Settings → AI Agent (default and vision models, limits,
  prompt, watchers, and an Owner-only `agent_capture_ai_content` switch),
  AI Agent → Users (each user's model, limits, spending and guard blocks, for
  `agent.manage`) and AI Agent → Spending (today and this month). Every event
  is checked against the browser session's current scope.
- Per-user settings (`PhoenixKitAgent.UserConfig`), and cleanup of a user's
  chats and files when the user is deleted.
- Notices for an AI account out of credit, model errors and limits, in the
  user's language. The interface ships in English, Estonian, Russian,
  Ukrainian, French and German.
