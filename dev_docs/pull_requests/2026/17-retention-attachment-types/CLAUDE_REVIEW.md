# Claude Review — PR #17

- **Reviewer:** Claude Opus 5.5
- **PR title:** Add an optional chat retention and a setting for the accepted attachment types
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-15
- **Merge commit:** `f290172` (merged together with #18; this PR is `5752758...f3dc4f6`)
- **Range reviewed:** `1c94d74`, `616bb9a`, `0b26783`, `f3dc4f6` — `Retention`,
  `RetentionWorker`, `UserDeletion.release_files/1` and `release_orphans/1`, the retention and
  attachment-type parts of `Config` and Settings → AI Agent, `Attachments.add_checked/5`,
  `Detect.types/0`, `Turns.new_attachments/2`, the panel's `@accept_of`. Part of the review of
  everything since v0.2.0.

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: LOW.** Nothing deletes what it must not under normal clocks:
an unset or bad period deletes nothing, the batch SQL cannot spin, and the file release locks the
row. Four edges are fixed below: a node clock ahead of the database could delete a chat under a
running turn (F1); a confirmation click did not protect its chats, though the docs said it did
(F2); a failed run left no record of what it had already deleted for good (F3); Telegram fetched
pictures the type list would refuse (F4).

## Findings

### F1 — BUG, LOW — whether a turn's lock was fresh was judged by the node's clock (fixed)

`due_query/2` computed `stale = DateTime.utc_now() - lock_ttl_s` on the node. `Turns.Locks` stamps
`busy_since` with the database's `now()`, so that "the TTL does not depend on the clocks of the
nodes". A job node whose clock ran more than the TTL (6 minutes by default) ahead of Postgres read
a running turn as stale. It then deleted the chat under the turn, and the turn's next insert failed
on the foreign key after the model call was paid.

**Fix:** the threshold is now SQL: `(now() AT TIME ZONE 'UTC') - ttl * interval '1 second'`
(`busy_since` is `timestamp without time zone`, holding UTC). The `now:` option still places the
period, which tests rely on, but no longer the lock. Test: a run whose `now` is a day ahead
keeps a chat whose lock is fresh. That test fails on the old code.

### F2 — BUG, LOW — a click that confirms a write did not protect its chat (fixed)

The moduledoc said a chat is left while "a click that confirms a write" holds its lock. A click
takes only the **user's** lock (`Locks.acquire_user/4`, `UserSettings.busy_since`), and
`due_query` read only the conversation's. A ✅ pressed on a card older than the period, while the
job ran, could have core carry out the write while the chat was deleted. The notice insert then
failed (`:not_stored`) and the Telegram card was never edited.

**Fix:** a chat is due only while its user's lock is not fresh (`user_uuid not in` the users whose
`busy_since` is within the TTL, by the database's clock). That covers clicks and turns, so a busy
user's chats wait one night. Test: a user lock leaves every chat of that user; once stale, the chat
goes.

### F3 — IMPROVEMENT, LOW — a run that failed partway left no record of permanent deletions (fixed)

`log_run/1` ran only after the loop and the sweep. If a later batch raised, a release raised, or
the sweep raised, the chats already committed and gone had no `agent.retention_purged` entry.

**Fix:** each batch, each release and the sweep run under `recording/2`. On a failure it writes the
summary so far (marked `"interrupted" => true`; counts only) and re-raises to Oban. A job killed
outright by its timeout still records nothing. Test: a sweep that raises after a chat was deleted
leaves an entry with `conversations: 1, interrupted: true`.

### F4 — BUG, LOW — Telegram downloaded pictures the type list refuses (fixed)

`precheck_picture_for_telegram/3` asked about the chat, the size and the vision model, but not
`Config.attachment_types/0`. A site that kept only `pdf` (or only `png`, while every Telegram
photo is a JPEG) had each picture downloaded, up to 10 MB, before `add_checked` refused it. The
bot's help still said it reads pictures.

**Fix:**
- The bridge gives each picture its type: a photo is `jpg`; a document's type comes from its MIME
  type.
- `precheck_picture_for_telegram/4` refuses a type off the list with `:type_not_allowed` before the
  download. With no type, any picture type on the list will do.
- The help and the "text only" refusal drop pictures when the site takes none
  (`Attachments.telegram_picture_types/0`).
- A new sentence, "I understand text and voice messages for now.", is translated in all six
  catalogues.
- Tests: a photo without `jpg` and a png document are not fetched; the help says nothing of
  pictures.

### F5 — IMPROVEMENT, LOW — the file input did not offer `.markdown` (fixed)

`Detect` reads `.markdown` as `md`, but neither `@accept` nor `@accept_of["md"]` listed it. A
browser that sends no MIME type for it (common on Windows) got `:not_accepted` in the browser.
**Fix:** `.markdown` is in both lists; the test checks the `accept` attribute.

### F6 — NITPICK — an orphaned `executing` job blocks the cron (not changed)

`RetentionWorker` is `unique: [period: :infinity, states: […, :executing]]`. A job left
`executing` by a crash keeps the nightly insert out unless the host runs Oban's Lifeline. The
worker's moduledoc and the README say so. A finite period would hide the problem rather than show
it, so this is left as documented.

## What was verified and holds

- **The period:** `nil`, blank, unreadable and outside 1..3650 all read as off. The run reads the
  database (`retention_days_direct/0`), not the cache. Only an Owner can change it, checked on
  every event (`Access.owner?/1`, socket scope and live session scope), and the preview uses the
  same `due_query/2` as the run.
- **The batch:** `FOR UPDATE SKIP LOCKED ORDER BY uuid LIMIT`. Counts, file list and delete share
  one transaction, and every non-empty batch deletes a row, so it cannot spin. Files are released
  after the commit.
- **The release:** it locks the file row across the check and the delete, so a deduplicated upload
  either is seen or fails cleanly. The sweep skips files any foreign key refers to, and files
  younger than a day.
- **Nothing of a chat is logged:** Activity metadata is counts, days and now `interrupted`;
  failures log a class.
- **Attachment types:** no path stores a row except through `add_checked/5`. The check is on
  `Detect`'s `ext` from the content, never the browser's MIME type. `Detect.types/0`,
  `@accept_of`, the Settings boxes and `Dock.Texts.not_supported/0` agree. "Unset or unreadable =
  all" holds for `nil`, `""`, a failed read and unknown names.
