# Codex review — PR #17

Date: 2026-11-15. Reviewed retention/type changes merged in `f290172`
and follow-up fixes through `c2751e5`.

Rechecked the disabled default and invalid-setting behavior, Owner-only edits,
direct period reads, database-clock lock checks, batched deletion, cascade
counts, post-commit file release, locked orphan cleanup and interruption
logging. Rechecked content-type enforcement both at upload and turn start,
Telegram download prechecks, and the panel's matching accept list.

**BUG, HIGH, fixed:** checking only committed user-lock values allowed the
purge to delete a chat while a confirmation click's lock acquisition was
uncommitted. The batch now locks user settings rows with `SKIP LOCKED` and
checks eligibility again before deleting. A two-connection regression test
reproduces the old deletion using the actual lock-acquisition function.

Validation, the race analysis and existing Storage/Oban limits are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md).
