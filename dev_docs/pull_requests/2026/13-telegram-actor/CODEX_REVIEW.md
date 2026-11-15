# Codex review — PR #13

Date: 2026-11-15. Reviewed the actor changes merged in `1687325`, their
follow-ups, and removal of the obsolete read-only path in `c2751e5`.

Rechecked that a trusted update supplies the actor reference, every context
call verifies the current link and account gate, and Telegram uses the default
role with the opt-in `agent.telegram` permission. Site-only writers remain
closed to a chat reference. Tool execution and confirmation use the real
core executor with `allow: :all` and the appropriate audit channel.

**BUG, HIGH, fixed:** private outgoing text was not checked after a paid call
or between message parts and retries. This crosses the actor/bridge boundary;
the fix and its regression tests are F1 of the
[release review](../since-v0.2.0/CODEX_REVIEW.md).

Also corrected the documented arity of `latest_telegram_conversation/2`.
