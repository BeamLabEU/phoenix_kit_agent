# Codex review — PR #16

Date: 2026-11-15. Reviewed speech and picture changes in merge `1687325`
and their follow-ups through `c2751e5`.

Rechecked feature detection, model capabilities, session/limit checks under
the speech lock, paid-call attribution and content-capture settings, panel
deadlines and detached recognition, download bounds, picture-type prechecks,
content detection, album grouping, sequential extraction and unsent cleanup.

**BUG, HIGH, fixed:** a completed recognition sent its transcript to an
unlinked chat before the next turn checked authorization. Recognition now
checks the actor after completion and carries the actor reference through
each outgoing transcript part/retry. The regression test unlinks during
recognition and verifies that neither the transcript nor a user message is
delivered/stored by the bridge.

Validation and shared delivery fixes are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md).
