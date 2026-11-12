# Claude Review — PR #14

- **Reviewer:** Claude Opus 5.5
- **PR title:** Answer linked users in Telegram through the agent
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-12
- **Merge commit:** `1687325` (stacked: #13–#16 merged together; this PR is `dfa7060...4437bc0`)
- **Range reviewed:** `dfa7060...4437bc0` — `Telegram.{Reader, Bridge, ChatQueue, Client, Format,
  Limiter, Status, Supervisor, Texts, Turn}`, the Settings switch, the bridge's entry points in
  `Conversations`

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: HIGH → LOW after fixes.** One exception at the wrong moment
left the bot with no reader at all until a restart (F1, reproduced, fixed). A failed read of the
offset could answer a batch twice (F2, fixed).

## Findings

### F1 — BUG, HIGH — after one exception the reader kept the bot's global name and nobody read the bot (fixed)

`step/1` rescues with the state it was **given**. `acquire_and_poll/1` registers
`{Reader, connection}` and then polls. If anything in that step raised — `get_updates`,
`Linking.handle_updates` (a pool timeout), the offset write — the rescue returned the old state
(`registered?: false`) while the process still held the name. From then on:
- `register_name/3` answered `:no` (taken, by this same process), so the reader went `standby`
  every 30 s;
- `holds?/1` stayed true, so core's own `Linking.poll/1` read nothing either (Profile → Telegram
  linking broke too);
- switching off did not help (`unregister/1` only acted on `registered?: true`);
- Settings showed "reading".

**Fix:** `failed/2` lets go of every `{Reader, _}` name this process holds
(`:global.registered_names/0`, only those whose holder is `self()`) and sets `registered?: false`.
`unregister/1` and `release/2` now let go of a name only when this process holds it
(`drop_name/1`), so a reader with a stale flag cannot remove another node's name. Test
(`reader_test.exs`): the first `get_updates` raises; the name is free afterwards, the next cycle
reads and holds it, and switching off lets it go. It fails on the old code.

### F2 — BUG, MEDIUM — a failed read of the stored offset made the next poll go without one (fixed)

`Config.telegram_offset/1` reads through `Settings.get_settings_direct/1`, which returns `%{}` on
any error, so a failed read was `nil` and the poll was sent with no `offset:`. Telegram forgets
updates only below the offset of the last call, so it sent the last batch again; `store_offset`
found it stored already and the batch was dispatched again — duplicate turns, double spending, a
second card for one write.

**Fix:** the reader keeps the last id it took (`taken`), polls from the later of that and the
stored offset, and drops updates at or below `taken` before `Linking.handle_updates/3`. It is
reset when the bot changes. Test: after a batch, the setting is deleted (what a failed read
gives); the next poll still asks for `offset: 11`, and the batch given again is not answered.
Fails on the old code. **Not changed:** a freshly started reader whose very first read fails still
has no `taken`. That needs a settings reader that tells "absent" from "failed", which core does
not offer; the window (a restart plus a failed read plus the old batch) is small.

### F3 — BUG, LOW — a message coming as an idle queue stopped could be answered "busy" (fixed)

`Registry.lookup/2` can return the pid of a queue that has just exited (the registry cleans up
asynchronously). The single retry of `enqueue/4` could see the same dead pid and answer `:busy`.

**Fix:** `process/1` treats a registered pid that is not alive as no queue and starts one (the
registry gives a dead holder's key to the new process). **Not added:** a test — the window is a
scheduler race.

### F4 — IMPROVEMENT, LOW — Settings said the bot "only reads" where it proposes changes (fixed)

The description on Settings → AI Agent was unconditional, but since PR #15 a chat proposes changes
with buttons wherever `Config.writes?/0`. It now follows `writes?/0` like the help text: a second
sentence ("A change is shown as a card with two buttons, and is made only when the person
confirms it."), translated in all six catalogues, with a test for each mode.

## What was verified and holds

- **The offset** is stored before the batch goes on (also through `Linking`'s `confirm:`); `:busy`
  leaves it; a batch whose offset cannot be stored is not dispatched.
- **`holds?/1`** is only `:global.whereis_name/1`; `random_notify_name` and
  `{:global_name_conflict, _}` handle a netsplit; the name is checked before each poll and before
  the batch.
- **Nothing kept or logged:** Reader and ChatQueue are `:sensitive` with a redacting
  `format_status`; failures log a class and the `update_id`; no token is held.
- **ChatQueue:** 3 waiting, 20 queues (`max_children`), 60 s idle stop, Registry keys are tuples
  (no atoms).
- **`Format.chunks`** counts UTF-16 units correctly and never splits a surrogate pair or a
  grapheme; one message a second, one retry on a 429.
- **What reaches the agent:** private chats where the sender is the chat; not edited, not older
  than 600 s; `/start <payload>` ignored; forwarded messages refused. 👍 only when sent and no
  write tool was denied.
