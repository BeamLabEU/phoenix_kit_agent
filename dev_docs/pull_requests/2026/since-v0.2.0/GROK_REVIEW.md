# Grok Review — unpublished work since v0.2.0

- **Reviewer:** Grok
- **Range reviewed:** `v0.2.0` (`d50f278`, changelog dated 2026-10-27) .. `c2751e5` on `main`
  (60 commits, PRs #11–#18 and the review-fix commits after them), plus the uncommitted
  follow-up in this working tree
- **Date reviewed:** 2026-11-15
- **Package version:** `@version` in `mix.exs` is still `"0.2.0"`. `CHANGELOG.md` still ends at
  `## 0.2.0 - 2026-10-27`. Hex was not published from this recheck.

PRs #1–#18 already have a `CLAUDE_REVIEW.md` (some also a `CODEX_REVIEW.md`). This note does not
repeat those reviews. It is the release-prep pass over the whole unpublished delta, and the fixes
that pass found.

## Overall Assessment

**Verdict: the tree is fit to cut a release after these fixes are committed. Risk: MEDIUM → LOW.**
Claude's last two commits (`50729b9`, `c2751e5`) already applied the review findings for #11–#18
and removed the dead read-only Telegram path. One of those findings was wrong, and it is the bug
below: an offset stored before the timestamp was kept was treated as missing, so the first poll
after an upgrade answers the last batch again.

`@version` and `CHANGELOG.md` were left alone. A release is a separate step.

## Findings

### F1 — BUG, HIGH — an offset stored without its time was dropped, so the last batch was answered again (fixed)

`50729b9` started keeping `agent_telegram_offset` as `"<connection uuid>:<update id>:<unix time>"`
and treated a value with no time as stale (`nil`). That is the shape every running bot wrote
between the Telegram reader landing and that commit. Hex `0.2.0` itself has no reader, so this
bites an upgrade of `main`, or a restart onto `50729b9`, not an upgrade from the published package.

Telegram confirms updates only on the next `getUpdates` that passes a higher offset. The normal
state between batches is: the offset is stored, the batch has been answered, and Telegram has not
confirmed it yet. A poll with no offset returns that batch again. The reader then runs the turns
again (spend, replies, confirmation cards).

The claim in the PR #14 review that "every poll confirms the updates before it, so a missing time
is safe" is true only after a later poll has already been sent. It is not true for the value sitting
in the database when the new code first reads it.

**Fix:** `Config.telegram_offset/1` still drops a three-part value older than six days. A two-part
value for this bot is trusted and rewritten with `put_telegram_offset/2` (`history: false`), so the
six-day clock starts at the stamp. The id is returned even when that write fails; the next read
tries the stamp again. The reader moduledoc and `AGENTS.md` say the same. Test: a raw
`"<uuid>:500"` reads as `500`, the stored value gains a current timestamp and no new history line,
and the next poll asks with `offset: 501`.

### F2 — IMPROVEMENT, LOW — reclaiming an idle chat queue leaked its monitor on a timeout (fixed)

`ChatQueue.stopped_idle?/1` monitors the queue it asks to stop. The branch that sees `DOWN` is
fine. The 1 second timeout returned without `Process.demonitor/2`, so the `DOWN` stayed in the
caller's mailbox. The reader ignores stray messages, so this did not crash a turn. The timeout
branch now demonitors with `:flush`, as the "not idle" branch already did.

### F3 — DOC — `AGENTS.md` had drifted from the code (fixed)

- A Telegram photo is chosen among sizes of at most 10 MB by pixel area, with `file_size` only as
  a tie-break (and the smallest when none fits). The doc still said the largest by `file_size`.
  The code change is `903b94e`; the doc now matches it.
- The trusted bridge entry is `latest_telegram_conversation/2` (optional `chat_id`). The doc listed
  `/1`.
- The offset paragraph now describes the stamp in F1, not "a value without its time is let go".

## Rechecked and left as they are

- **Read-only Telegram path** (`c2751e5`). The core floor is `phoenix_kit >= 3.5.0 and < 4.0.0`,
  and `Executor.link_writes?/0` is true on that floor. `Config.writes?/0`, the stand-in core, and
  the read-only prompt rule are gone. Turns and confirmation presses call `PhoenixKit.API.Executor`
  and `Confirm` directly, with `allow: :all, via: "telegram"`. `Speech.transcribe/3` stays
  feature-detected: `phoenix_kit_ai ~> 0.27` still admits 0.27, and `transcribe/3` arrived in 0.28.
- **Retention clocks** (`50729b9`). Due chats and the user lock are judged by the database `now()`,
  not the node clock. A fresh user lock keeps all of that user's chats. A run that deleted chats
  and then failed still records `agent.retention_purged` with `interrupted: true`.
- **Confirmation outcome.** A refusal before redeem, on a row `get_for_user/2` already reads as
  `used`, is `confirmed`. `failed` stays for a handler that failed after the row was spent.
- **Speech deadline.** The panel passes `deadline:`; `not_abandoned(nil)` is `:ok`, so a caller
  that does not set one still pays. The dock's pay-by leaves a full provider timeout inside the
  two-minute wait. Not changed.
- **Stop within 600 ms of Send** is ignored (double-click). The test config keeps the window at 0.
- **A batch that arrives after the switch goes off** during the long poll is not stored and not
  dispatched, and the global name is released. The previous batch was already confirmed by the poll
  that returned this one.
- **429 retry** only when the wait in `"Too Many Requests: retry after N"` is within the bound.
- **Album overflow.** When the task supervisor is full, one "busy" is sent and further siblings of
  that batch are not answered again. That matches the documented "busy once".
- **`Reader.taken/1` with `taken` set and `taken_at` nil.** `init/1` and `take/2` always set both.
  A hot upgrade of an older process state could raise once; the reader's failure path drops the
  global name and the next step reads. Left as a speculative upgrade crash, not patched.
- **Six-day expiry** of a timestamped offset, and of the in-memory `taken` id, stays. The two clocks
  are the same node's `os_time` / `monotonic_time`. A six-day skew is not the retention bug.

## Gate

With this follow-up in the working tree, on 2026-11-15:

- `mix test`: **1323 tests, 0 failures**. Seven tests tagged `:poppler` were excluded because
  poppler is not installed here; the suite prints that exclusion.
- `mix precommit`: passed (format, `compile --warnings-as-errors`, gettext up to date, unused
  deps, `hex.audit`, credo --strict, dialyzer). Dialyzer reported 6 ignored warnings and 0 new
  ones.
