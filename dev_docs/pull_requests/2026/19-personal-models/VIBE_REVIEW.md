# PR #19 — A user's own models for chat, pictures and speech; "My assistant" in the chat panel

**Author:** timujinne · **State:** merged 2026-11-23 (`a849f1c`) · **Reviewed:** 2026-11-23

**Verdict:** merged, no findings that needed a fix.

## Checked, fine

- **The user's own write is locked down.** `UserConfig.put_personal_models/3` resolves the
  row from the session (`Conversations.authorize_session/2`) — the target user is never
  caller-named; the row is locked `FOR UPDATE` inside a transaction; only the three model
  columns are written (admin fields and a turn's lock untouched). A new value must pass
  `Models.selection_check/2`: uuid cast, membership in the site's
  `agent_selectable_endpoint_uuids` setting (empty by default = nobody self-selects),
  endpoint exists, is callable, and fits the task (`PhoenixKitAI.Tasks.check_selection/2`);
  speech additionally requires `Config.transcribe?/0`. "Default" (nil/blank) is always
  allowed. Changes are written to the Activity log (`agent.user_settings_updated`) with
  the user as actor, no model values in the log line.
- **The admin path is separate and ranked.** `admin_update/4` requires an `agent.manage`
  scope, refuses to set an Owner's assistant for a non-Owner, supports the stale-form
  guard (`expected:`), and checks task fit itself; `may_configure?/2` exposes the rule to
  the pages. The settings and users LiveViews gate on `agent.manage`; the chat-panel
  "My assistant" region gates on the plain `agent` permission and is read-only while the
  selectable list is empty.
- **`effective/1`** resolves each of chat/vision/speech as own → default → fallback with
  the source named; a deleted/switched-off/credential-less own model falls back instead
  of failing the turn (deliberate change, documented). All readers (chat panel, turn,
  attachment processor, speech, Telegram) go through it.
- **Migration V3** (module's own chain): two nullable `uuid` columns on
  `phoenix_kit_agent_user_settings` with `REFERENCES phoenix_kit_ai_endpoints(uuid) ON
  DELETE SET NULL`, partial indexes (bare names on CREATE, qualified on DROP), additive
  and re-runnable (`IF NOT EXISTS`), prefix-qualified via `Helpers.qualify_table/2`,
  `down` drops index then column. Matches the module's existing V1/V2 style.
- Settings card wording ("defaults for everyone", "a user's own choice replaces it"),
  "money is not counted" tag, switched-off endpoint cannot become a default — as described.

## Verification

- Full `mix precommit` + `mix test` against local core (`PHOENIX_KIT_PATH=../phoenix_kit`)
  run on main after the merge — see the sweep report for the result.
- `mix.lock` refreshed (`mix deps.update --all`) so locked transitive deps satisfy local
  core's requirements; committed as "Update dependencies".

## Notes

- The PR body's "not checked" list (dialyzer, browser pass on the admin pages) is covered
  by the post-merge gate run on main.
