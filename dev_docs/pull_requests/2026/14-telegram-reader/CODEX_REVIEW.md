# Codex review — PR #14

Date: 2026-11-15. Reviewed reader/bridge changes in merge `1687325` and
follow-ups through `c2751e5`, plus the existing uncommitted fixes.

Rechecked global reader ownership and release on failure, persisted and
in-memory offsets, stale-offset expiry, switch changes during polling,
update filtering, bounded queues, idle reclamation, reply pacing and retries.

- **BUG, HIGH, fixed:** private answers continued after unlinking/relinking,
  including between chunks and on retry (F1 of the release review).
- **BUG, MEDIUM, fixed:** core's convenience settings reader hides database
  errors as absence. Offset reads now propagate failure to the reader's
  backoff handler before it polls, including immediately after a restart (F3).
- Retained the pre-existing fix that stamps legacy offsets without dropping
  them, and the fix that demonitors an idle-reclamation timeout.
- Corrected the photo job's type and pixel-area selection comment.

Validation, regression evidence and delivery limits are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md).
