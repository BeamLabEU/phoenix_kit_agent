# Claude Review — PR #13

- **Reviewer:** Claude Opus 5.5
- **PR title:** Accept a linked Telegram chat as an actor of the agent
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-12
- **Merge commit:** `1687325` (stacked: #13–#16 merged together; this PR is `d50f278...dfa7060`)
- **Range reviewed:** `d50f278...dfa7060` — the `{:telegram_link, …}` reference in
  `Conversations`, `Confirmations`, `Attachments`, `Turns`, `Runner`, `Prompt`, `UserConfig`;
  checked against `HEAD` for the code later PRs built on it

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: MEDIUM → LOW after fixes.** The gate in `Conversations` is
sound. The bridge built on its trusted `create_conversation_for/2` (PR #14) made a conversation
before asking that gate (F1, fixed).

## Findings

### F1 — BUG, MEDIUM — `/new` and a first message made a conversation with no permission check (fixed)

`Telegram.Turn.new_conversation/5` and `converse/6` called `create_conversation_for/2` (a trusted
entry point that checks nothing) before `Conversations.authorize_session/2`. A linked user
without `agent.telegram` (it is `opt_in`, so most linked users) who sent `/new` got a new active
conversation row each time **and** "Started a new conversation."; a plain message left a row and
then a refusal. With `agent` held, the empty chats showed in their panel. `photo/6` already
authorized first.

**Fix:** both now call `Conversations.authorize_session(ref, impersonated: false)` before any
conversation is looked up or made, and refuse with the gate's reason
(`Texts.refusal(:forbidden)` → "You may not use the assistant in Telegram."). Test
(`flow_test.exs`): a linked chat without `agent.telegram` sends `/new` and a message, each is
refused with 🤷, and no conversation row exists for that user.

### F2 — IMPROVEMENT, LOW — switching Telegram off did not stop jobs already queued (fixed)

Only the reader read `agent_telegram_enabled`. Up to three waiting jobs per chat still started
paid turns after an admin turned it off.

**Fix:** `Telegram.Turn.run/3` lets a job go unanswered when the switch is off. The flow, photo
and voice test setups now turn the switch on, which is what production requires for a job to
exist at all. A new test covers a message that comes while it is off. **Not changed:** a turn
already running finishes its rounds. Each round re-checks the link and the rights, but not the
channel switch; stopping a paid turn mid-way for a switch is a larger change than its value.

### F3 — IMPROVEMENT, LOW — "the scope is the user's default narrowed role" did not test narrowing (fixed)

It only asserted the user uuid. Narrowing is what the next test proves (`agent.telegram` on a
non-default role does not reach the chat). The test is renamed to what it checks, with a pointer
to that test.

## What was verified and holds

- **The gate** (`Conversations.scope_for/1`): the reference's `user_uuid` is pinned against
  `Linking.linked_user/2` read now (relinked, unlinked, dropped → `:session_gone`);
  `SessionRef.scope_for_user(user, narrow: true)`; `agent.telegram`, then `agent`, the module
  switch and the user's `enabled`; `impersonated: true` refused; a malformed reference never raises.
- **Refused for a chat:** create, rename, archive, delete, `add_message`,
  `put_personal_instructions`; all five site entry points of `Attachments`; `confirm`, `reject`,
  `repeat`, `cards`, `waiting_cards`, `settle_lapsed` (presses have their own path, PR #15).
- **Runner:** a chat gets `[]` tool access without `Config.writes?/0`, otherwise `allow: :all,
  via: "telegram"`; each round re-checks the chat.
- **Locks, limits, guard admission and spending** are keyed by the conversation's user, as for
  the panel; journal rows carry `user_uuid` and `source: "agent"`.
- **Prompt:** `channel: :telegram` replaces the site write rule; the chat passes no `page:`.
