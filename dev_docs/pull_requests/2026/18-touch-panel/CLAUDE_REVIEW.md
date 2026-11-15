# Claude Review — PR #18

- **Reviewer:** Claude Opus 5.5
- **PR title:** Make the chat panel usable on a touch phone, and give an embedding host a compact
  header and turn events
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-15
- **Merge commit:** `f290172` (merged together with #17; this PR is `23e2ff7`, `a678c3f`,
  `4ea7bc2`)
- **Range reviewed:** `Web.Dock`, `Web.Dock.Panel` (markup and the runtime colocated hooks
  `.DockState`, `.Feed`, `.Composer`, `.Turn`), `test/js/hooks.test.mjs`. Part of the review of
  everything since v0.2.0. The core-floor commit that followed the merge (`835b049`) is covered at
  the end.

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: MEDIUM → LOW after fixes.** One medium bug: Stop now stands
where Send was, so the second click of a double click on Send stopped the turn it had just
started, often after the first model call was paid (F1). The rest are touch and re-join edges.

## Findings

### F1 — BUG, MEDIUM — a double click on "Send" stopped the turn it started (fixed)

LiveView disables the form's buttons during the submit. Its reply then removes Send and inserts
`#pk-agent-stop`, a new element that is enabled. When `Turns.start/6` answers within a
double-click interval, the second click lands on Stop. A double tap on a phone does the same.

**Fix:** the panel keeps when it sent (`turn_sent_at`), and the server lets go of a Stop that comes
within `:stop_after_send_ms` (600 ms) of it. A real Stop a moment later works as before. The test
config sets it to 0, since existing tests click at once. New test: with a long window, a Stop
right after Send leaves the turn running, and a later Stop stops it.

### F2 — BUG, LOW — `.Turn` told the host `done` then `start` for one turn on every re-join (fixed)

On a re-join LiveView patches the fresh mount (no chat, `data-running="false"`) and calls the
hook's `updated()` before `reconnected()`. Only the answer to `restore` brings the chat back. A
network blip during a turn told the host the turn was done, then started again; a host that
re-enables its UI on `done` acted early.

**Fix:**
- `#pk-agent-turn` carries `data-restored`.
- `disconnected()` marks the hook away, and `reconnected()` notes the join's `restored`.
- Patches are ignored until `restored` changes (the answer to `restore`) or 5 s pass.
- The same turn back is then no event.
- Three JS tests: same turn back (silent), turn ended meanwhile (`done` once), and no answer
  (judged on the timer). The first fails on the old hook.

### F3 — BUG, LOW — core's buttons in the composer were under 44 px on touch (fixed)

The spec says every button of the panel is at least 44 px both ways under `pointer-coarse:`.
Core's upload manager (pause, retry, cancel, dismiss; `btn-xs btn-circle`) and the recorder's
start button live inside `#pk-agent-files` and were about 24 px.

**Fix:** `#pk-agent-files` carries `pointer-coarse:[&_button]:min-h-11
pointer-coarse:[&_button]:min-w-11`. The recorder's portaled dialog renders outside the panel and
is core's to size.

### F4 — BUG, LOW — in Safari, Escape did not close a row's actions after a mouse click on "⋯" (fixed)

Safari does not focus a clicked `<button>` (the module's own comment says so for the dropdown
trigger). The focus lands on the focusable `#pk-agent-chat-list`, and LiveView matches a key
binding on the event's target only, so none of the three Escape bindings fired.

**Fix:** the list itself has `phx-keydown`/`phx-key="Escape"`: it hides every row's actions and sets
`aria-expanded="false"` on every "⋯". Tested through the JS ops.

### F5 — BUG, LOW — a cancelled touch left the resize handle's listeners behind (fixed)

This predates the PR but now matters on a touch-first panel. `resize()` removed its listeners only
on `pointerup`. A cancelled touch (an iPad in landscape taking the gesture) left `pointermove`
attached, and each new press added another pair.

**Fix:** it ends on `pointerup`, `pointercancel` or `lostpointercapture`, and writes the width
once. The handle is `touch-none`.

### F6 — IMPROVEMENT — the focus falls to `<body>` when Send replaces a focused Stop (not changed)

The Send → Stop rule moves the focus to the text. The reverse would need to follow the focus
across a Stop that is first disabled (`:stopping`) and then removed, where browsers differ on blur.
The cost is one extra Tab for a keyboard user. Left as is.

## The core floor commit (`835b049`)

Its message says it "drop[s] the feature detection and fallbacks that only existed for older
cores: calls that went through `Code.ensure_loaded?`/`apply` now call core directly". It changed
only `mix.exs`, `AGENTS.md` and `README.md`. The checks are still in the code:
`Config.writes?/0` (`Executor.link_writes?/0`), `Client.can_download?/0`
(`Telegram.download_file/3`) and the panel's `Code.ensure_loaded?(AudioRecorder)`.

Core 3.5.0, the new floor, has all three, and `link_writes?/0` is `true`. So:
- the checks are now always true in production; they are harmless, and each is the seam a test
  uses to stand in for an older core;
- the docs said each check exists "since the core requirement of the module is below the first
  release with it", which is no longer so. AGENTS.md now says so.

`transcribe/3` stays feature-detected, because `phoenix_kit_ai ~> 0.27` admits 0.27, and
`transcribe/3` first shipped in 0.28. AGENTS.md said `~> 0.26`; it now says `~> 0.27`, like
`mix.exs`.

**Follow-up (done, 2026-11-15):** on every supported core a Telegram chat proposes changes, so the
read-only Telegram path (no `allow: :all`, the read-only help text, prompt rule and Settings text)
was reached only in tests. At the owner's request it was removed in the next commit:
`Config.writes?/0`, `Config.core/1` with `:api_modules`, the `:telegram_link_writes` stand-in and
`test/support/fake_core.ex` are gone. The module calls core's `Executor` and `Confirm` directly,
and every Telegram test now runs the way production does.

## What was verified and holds

- The header buttons are rendered twice with distinct ids (`pk-agent-` / `pk-agent-bar-`), and the
  hidden copy is `display: none`. The close button is found by `[data-pk-agent-close]`. The
  compact show and hide rules are exact opposites. The dropdown trigger is a `div` with
  `tabindex="0"`.
- Every `handle_event`, `handle_info`, `handle_async` and upload progress goes through `guarded/2`.
  No Repo query is in the LiveView, and nothing touches the database in the static render. Model
  text goes only through `Web.Markdown`.
- Window listeners and timers of the hooks are removed in `destroyed()`. The "⋯" JS commands are
  sticky over a patch.
- `node --test test/js/hooks.test.mjs`: 29 of 29 pass, 3 of them new.
