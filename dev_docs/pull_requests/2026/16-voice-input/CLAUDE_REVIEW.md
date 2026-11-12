# Claude Review — PR #16

- **Reviewer:** Claude Opus 5.5
- **PR title:** Take voice and pictures: speech recognition in Telegram and the panel, photos from Telegram
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-12
- **Merge commit:** `1687325` (stacked: #13–#16 merged together; this PR is `e231bc5...e197571`)
- **Range reviewed:** `e231bc5...e197571` — `Speech`, `Attachments` (Telegram pictures),
  `Telegram.{Turn, ChatQueue, Bridge, Client}`, `Config`/`Models` (speech model), `Web.Dock` /
  `Panel` (microphone), `SettingsLive`; plus the hand resolution of `dock.ex` / `panel.ex` against
  PR #12 in `1687325`

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: LOW.** Money is checked, journaled and paid once; bounds are
checked before any download; nothing of a recording, its words or a picture is logged. Two edge
cases left Telegram pictures behind (F1, F2, fixed).

## Merge notes (`1687325`)

- `mix.exs`: `phoenix_kit` back to `>= 3.4.0 and < 4.0.0` (3.4.0 is the first release with both
  the Telegram actor and the `UploadManager` / `ResumableUpload` main had pinned a git ref for).
- The composer has both the upload manager and the microphone; the mount has both sides' assigns.
- Lock: `phoenix_kit_ai` 0.29.1, which has the `:audio_input` need (dialyzer flagged
  `money_counted?(…, [:audio_input])` against 0.27's type) and `transcribe/3`. bandit, ecto,
  phoenix_html, saxy and ssl_verify_fun were updated past security advisories.

## Findings

### F1 — BUG, LOW — pictures stayed when the chat lost its rights during the turn (fixed)

`discard_for_telegram/2` (in the turn's `after`) asked `Conversations.authorize_session/2` first,
so when the turn failed **because** the chat was unlinked, lost `agent.telegram` or was switched
off meanwhile, the discard was refused too. The rows stayed unsent with their bytes in Storage,
counting against the user's unsent bound and showing as stray chips in the panel. The sweep only
looked at the current conversation, so files left before a `/new` were never swept either.

**Fix:**
- `discard_for_telegram/2` acts on the reference's user without re-asking the chat's rights (it
  is the bridge cleaning up after itself, not a privileged act). It removes only a picture the
  bridge added (`filename == "telegram-picture"`) that no message took; anything else is
  `:not_found`.
- `sweep_unsent_for_telegram/3` covers the user's unsent bridge pictures in any of their Telegram
  conversations (`metadata.source = "telegram"`), still only past the wait bound + 5 s, so a
  picture in flight is never touched.

Tests (`photo_test.exs`): discard after the links were dropped removes the bridge picture and
refuses a panel upload; the sweep removes an old picture in an earlier Telegram conversation and
keeps one in a site conversation.

### F2 — IMPROVEMENT, LOW — a panel upload named `telegram-picture` looked like the bridge's (fixed)

The bridge's files are told apart by their stored name, and `clean_name/1` kept a user-supplied
`telegram-picture`, so the sweep could remove a panel upload so named. `Attachments.add/4` (the
panel's entry point) now stores such a file as `telegram-picture (1)`. Test in
`attachments_test.exs`.

## What was verified and holds

- **Money:** `Speech.transcribe/4` checks voice on, the AI module, the session or link (with
  `agent.telegram`), the endpoint, the limits (`use: :speech`) and the size, then asks all of them
  again under the per-user `:global` lock with the deadline; one call with `user_uuid`,
  `source: "agent"`, `task: "agent.speech"`, `capture_request_content: false`, `cache: false`.
  Telegram picture descriptions go through the unchanged `Processor` path.
- **Bounds before download:** voice checks limits, 120 s and 10 MB first; photos the 10 MB bound
  and `precheck_picture_for_telegram/3`. Core's `download_file/3` caps the body as well.
- **Content decides:** a "photo" that is a PDF is `:unsupported_type` (`only_kind/2`).
- **Albums:** siblings held outside the 3 waiting places (≤ 9); `take_siblings` clears them; a
  refused album is answered once; `max_attachments_per_message` and the "left out" line hold.
- **Panel:** the clip goes through `guarded/2`; a second `start_async(:speech)` after a timeout
  replaces the first (LiveView drops the stale result); the paid call runs in an `async_nolink`
  task so a closed tab cannot cut it short; the recorder renders only where
  `Code.ensure_loaded?` finds it.
- **Settings:** a forged speech endpoint is refused without `transcribe/3`; otherwise only an
  offered one, checked with `check_selection("agent.speech")` when new.
