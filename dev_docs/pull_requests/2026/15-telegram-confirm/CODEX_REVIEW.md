# Codex review — PR #15

Date: 2026-11-15. Reviewed confirmation changes in merge `1687325` and
follow-ups through `c2751e5`.

Rechecked card lookup by confirmation and owning chat, cross-origin refusal,
raw arguments bound to the specific assistant message, current tool rights,
user click locks, duplicate waiting writes, notice transactions, lapsed-card
settlement, preview size limits and outcome edits.

**BUG, HIGH, fixed:** a card preview could be retried after the chat's link
was removed while Telegram asked the sender to wait. Card sends now carry
the actor reference through the bridge's per-attempt authorization check.
A regression test unlinks the chat on a 429 response and verifies that no
second send occurs, the row remains unused, and the write is not executed.

Validation and known asynchronous-edit limits are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md). The previously documented
race between an outcome edit and a concurrent explanatory note remains;
core still prevents a second execution.
