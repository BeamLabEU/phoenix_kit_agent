# Claude Review — PR #15

- **Reviewer:** Claude Opus 5.5
- **PR title:** Confirm changes from Telegram with ✅ / ❌ cards
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-12
- **Merge commit:** `1687325` (stacked: #13–#16 merged together; this PR is `4437bc0...e231bc5`)
- **Range reviewed:** `4437bc0...e231bc5` — `Telegram.{Card, Cards, Press}`, `Confirmations`
  (`precheck/2`, `confirm_press/3`, `reject_press/3`), `Conversations` (card places,
  `notice_added`), `Bridge` (callback queries), `Turn`, `Prompt`, `Config.writes?/0`

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: LOW.** The trust boundary of a press holds end to end, and
double execution is impossible (the user's lock plus core's single-use row). Two small fixes.

## Findings

### F1 — BUG, LOW — the new card of a `changed` outcome could go to a chat no longer the owner's (fixed)

`Cards.settled/1` builds the reference from the stored card place and never asked whether that
chat is still linked to the card's owner. If the user unlinked, or the chat was relinked to
someone else, and the change was then confirmed on the site with moved data (`changed`),
`replacement/3` sent a new message to that chat: a generic "cannot be confirmed here" text in the
old owner's language. No data leaked, but a stranger got a bot message about someone else's change.

**Fix:** `replacement/3` sends only while `Linking.linked_user(connection, chat_id)` is still the
conversation's user; otherwise the change waits on the site. The edit of the existing message to
its outcome headline is kept (it only replaces the bot's own earlier text). Test
(`confirm_test.exs`): links dropped, site confirm → `changed`, no card and no message sent. Fails
on the old code.

### F2 — IMPROVEMENT, LOW — Confirm was offered while rows the site shows were hidden (fixed)

`Card` promises "a card whose preview does not fit whole is never offered for ✅", but rows past
the card's row budget were only counted into "…and N more" while both buttons stayed. A 25-row
bulk update with long values showed about 15 rows yet offered Confirm.

**Fix:** a card that leaves out rows the site would show (`hidden > view.hidden`) counts as not
fitting: the summary, "Confirm it on the site", and ❌ alone. Rows core itself leaves out (also
"…and N more" on the site) keep both buttons. The old test asserted only length and the "more"
line; it is split into the two cases, each asserting the buttons.

### F3 — NITPICK — a "press again" note can land after the outcome edit (not changed)

On a double tap, press 2 gets `:click_running`, re-reads the card as open and edits in the "⏳
press again" note, while press 1's outcome edit runs in another task; Telegram may apply them in
either order. The card can show "press again" with buttons after the change was made. It heals on
the next press (a toast and the outcome edit), and nothing runs twice. Ordering the two edits
would need them to share a lock; left as is.

## What was verified and holds

- **Who may press:** strict callback data (`c:`/`x:` + a 36-char lowercase uuid); the actor only
  from `Linking.actor_ref/2`; private chats where the sender is the chat; groups, inline messages
  and strangers get an empty answer, an unlinked chat a toast once.
- **Which card:** `press_card` needs the card's message, a conversation owned by the reference's
  user (link, account gate, `agent.telegram`, not deleted) and the same chat; core checks the
  row's origin (`:foreign` / `other_origin`).
- **`Config.writes?/0`** off → presses ignored, and re-checked in `confirm_press/reject_press`.
- **Outcome edits** run after commit, only with writes and the switch on, for the bot the card
  went through, in a task under `ReplySupervisor`.
- **`telegram_cards`** is written under `SELECT … FOR UPDATE`, capped at 50.
- **Text to Telegram:** plain text, ≤ 4000 UTF-16 units, technical part cut at 1500 chars; toasts
  are fixed gettext strings; no preview or argument reaches `answerCallbackQuery` or the log.
- **Rate limit:** 10 a minute per chat, counted before any database read.
