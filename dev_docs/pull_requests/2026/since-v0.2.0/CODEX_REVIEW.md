# Codex review — unpublished changes since v0.2.0

Date: 2026-11-15. Baseline: Hex `0.2.0`, tag `v0.2.0` (`d50f278`).
Reviewed: the 60 commits through `c2751e5`, PRs #11–#18, their follow-up fixes,
and the pre-existing uncommitted offset, queue and documentation changes.
This review adds the fixes below. The package version and changelog remain
unchanged; this is preparation for a separate release.

## Findings and fixes

### F1 — BUG, HIGH — private Telegram replies outlived their authorization

The bridge checked the actor before starting a turn, but sent a final model
answer using only the Telegram chat id. Removing the link during the last
model call still delivered the answer. Speech recognition likewise sent its
transcript before the next authorization check. Long answers and retries
continued after a chat was linked to a different account. Confirmation-card
retries had the same delivery gap.

The turn now checks authorization again after waiting for its answer and
after recognition. Private text and cards carry the original actor reference
into the bridge; the bridge checks the current link and rights before every
part and every retry, after any pause. A refused delivery stops the remaining
parts. Fixed replies without account data may still use a chat id.

Regression tests cover unlinking during the final model response, unlinking
during recognition, relinking between answer parts, unlinking before an
answer retry, and unlinking before a confirmation-card retry. The four
initial answer/voice tests all failed before the fix.

### F2 — BUG, HIGH — retention raced an uncommitted confirmation lock

The purge excluded users whose committed lock was fresh. A click acquiring
that lock could still have an uncommitted update: the purge saw the previous
idle value and deleted the conversation. The click could then redeem a
change while its card and outcome history disappeared.

Each batch now locks its selected conversations, locks their existing user
settings rows with `FOR UPDATE SKIP LOCKED`, and checks eligibility again.
Users whose settings row another transaction holds are excluded. A click
starting after those locks waits for the batch, then rereads its card before
redeeming. Turns and retention both acquire conversation rows before settings
rows; retention never waits for a locked row.

The regression test uses a second database connection and the real
`Locks.acquire_user/4` inside an uncommitted transaction. Before the fix it
deleted one conversation; the required outcome is zero, with the conversation
still present and the committed click lock protecting it.

### F3 — BUG, MEDIUM — a failed offset read after a restart could replay a batch

`Settings.get_settings_direct/1` hides database failures as an empty map.
For a reader with no in-memory `taken` offset, that was indistinguishable
from a bot with no stored offset. Polling without an offset can return the
previous, already-dispatched batch and pay for its turns again.

`Config.telegram_offset/1` now uses core's underlying settings query, which
distinguishes absence from failure. A failure reaches the reader's existing
guard, releases its global name and backs off before polling. The memory
fallback still protects a running reader against an accidentally removed
setting. A regression test makes the repository unavailable and verifies
that the offset read fails rather than returning `nil`.

### F4 — IMPROVEMENT, LOW — documentation could not build without warnings

Strict ExDoc generation exposed malformed angle-bracket placeholders and
references to hidden helpers or unresolved aliases. Fixed those references
without making internal helpers public. Corrected the documented arity of
`latest_telegram_conversation`, the photo-job type, and the photo-size
selection comment. Added the missing Telegram setup instructions to the
README and corrected its reconnect-event and retention-lock descriptions.

### F5 — IMPROVEMENT, LOW — integration fixtures used production hashing cost

Every registered test user used bcrypt's production default cost. The suite
spent minutes hashing fixture passwords even though these tests exercise
authorization and agent behavior. Test configuration now sets `log_rounds: 4`,
as bcrypt's own test guidance recommends. Runtime and published-package
configuration are unaffected. The new retention concurrency test also uses
an outer transaction rollback to release sandbox-held locks before its
committed fixtures are cleaned up.

## Existing work retained

The checkout already contained the legacy-offset migration fix and its test:
an offset written before timestamps were introduced is retained and stamped,
without settings history. Dropping it could replay the last batch after an
upgrade of an unpublished version. It also contained cleanup of a monitor
left behind when reclaiming an idle queue timed out. These changes were
reviewed and retained; their original review is in `GROK_REVIEW.md`.

## Review coverage

| PR | Areas rechecked | Additional result |
|---|---|---|
| #11 | Attachment ownership, history headers, confirmed-write counts | No additional runtime defect; documentation fixed |
| #12 | Resumable file ownership, entry-to-chat binding, reconnect hooks | No additional runtime defect |
| #13 | Actor reference, current link, default-role scope, site-only writers | Outgoing authorization gap fixed with #14/#16 |
| #14 | Reader ownership, offsets, queue bounds, reply pacing, retries | F1 and F3; existing offset/monitor fixes retained |
| #15 | Card origins, arguments, click locks, outcomes, retries | Private card retries covered by F1 |
| #16 | Paid speech, deadlines, picture checks, albums and cleanup | Transcript delivery covered by F1 |
| #17 | Opt-in deletion, database clocks, file locks, orphans, type checks | F2 |
| #18 | Touch controls, compact header, turn events, reconnect behavior | README corrected; hook behavior retained |

Each PR directory has a separate `CODEX_REVIEW.md` with its review scope.

## Validation

- Full `mix test`: **1337 tests, 0 failures, no exclusions**, in 113.3 seconds
  (seed `234021`). Run against a fresh, isolated PostgreSQL test database;
  Poppler was unpacked into a temporary directory and placed on `PATH`, so
  the PDF tests ran alongside the ImageMagick and Node hook tests.
- Focused reader and retention regression pass: **36 tests, 0 failures**;
  unrelated retention tests were excluded by the location filter.
- `mix precommit`: passed compilation with warnings as errors, formatting,
  gettext extraction, unused-dependency check, Hex audit, strict Credo and
  Dialyzer. Dialyzer retained its six existing ignored warnings, with no new
  warnings or unnecessary ignores.
- `mix docs --warnings-as-errors`: passed for HTML, Markdown and EPUB.
- `mix hex.build --output /tmp/phoenix_kit_agent_review.tar`: passed. Checked
  that the archive contains the README and no test, config or review files.
  This built a local artifact only; nothing was published or tagged.
- `git diff --check`: passed.

## Remaining limits

- Telegram processing is deliberately at most once: a crash between storing
  the offset and dispatching an update can lose that update. A network call
  already submitted before unlinking cannot be recalled.
- Storage deletes a file's database row before its S3 objects. An S3 failure
  can leave bytes the orphan sweep cannot discover. This needs a core fix.
- The user-deletion hook runs before core commits deletion of the user;
  a later failure can leave that user's attachment files already removed.
- The host must run Oban Lifeline to recover a retention job orphaned in
  `executing`, as already documented.
- Provider and Telegram network calls are stubbed in the integration suite.
  Browser hooks run on the project's fake DOM; this pass is not a real-device
  browser test or a live-bot deployment test.
