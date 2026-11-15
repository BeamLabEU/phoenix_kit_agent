# Codex review — PR #18

Date: 2026-11-15. Reviewed touch/compact panel changes merged in `f290172`
and follow-ups through `c2751e5`.

Rechecked touch target dimensions, Enter versus Ctrl/Cmd+Enter behavior,
compact-header visibility rules, close selectors, chat actions and Escape,
resize cancellation, the Send/Stop double-click window, and turn identity
across reconnect restoration. The fake-DOM hook tests cover these paths.

No additional runtime defect found. Corrected the README's claim that a
reconnect may repeat `done`/`start` for the same answer: the current hook
waits for restore and preserves the turn identity.

Validation and the real-device testing limit are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md).
