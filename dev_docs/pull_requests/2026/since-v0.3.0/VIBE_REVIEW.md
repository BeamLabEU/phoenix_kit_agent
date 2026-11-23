# Everything since the last Hex release (v0.3.0) — review, fixes, improvements

**Scope:** `1fa4874..HEAD` — PR #19 (a user's own models for chat, pictures and
speech; "My assistant" in the chat panel), merged `a849f1c`, plus the three
follow-ups on main: `aaee9ef` (lock refresh), `7feaab8` (dialyzer
`contract_with_opaque` fix on `Models.usable_uuids/1`), `e5d73dc`
(`phoenix_kit_ai` 0.29.1 → 0.31.0 in `mix.lock`). PR #19 itself already carries a
review (`../19-personal-models/VIBE_REVIEW.md`); this doc reviews the whole
range again, end to end, including what landed after that review.

**Verdict:** no defects found; nothing needed fixing. Gate green on the reviewed
tree (see Verification).

## What was checked, and found fine

- **Migration V3** (`Migrations`, `Schemas.UserSettings`): two nullable `uuid`
  columns with inline `REFERENCES phoenix_kit_ai_endpoints(uuid) ON DELETE SET
  NULL`, so a re-run adds no second link; partial indexes named exactly as the
  changesets' `foreign_key_constraint` names expect (default Postgres FK naming,
  under the 63-byte identifier limit); `down/1` drops index then column. The
  marker moves to `pk_agent_schema:3` only in the V3 statements.
- **The user's write** (`UserConfig.put_personal_models/3`): site-only
  (`Conversations.on_the_site`), session-authorized, row of the session's user
  (never a caller-named uuid), `insert ... on_conflict: :nothing` then
  `FOR UPDATE`; only the three model columns cast
  (`personal_models_changeset/2`), so admin fields and a live turn lock are
  untouched; a new value must pass `Models.selection_check/2` (on the selectable
  list, callable, fits the task), speech additionally gated on
  `Config.transcribe?/0`; blank clears to the default and is always allowed; the
  first refusal rolls the whole transaction back. Refusal shape
  `{field, reason}` is what the dock matches.
- **The admin's write** (`admin_update/4`): `agent.manage` re-checked, Owner
  rules and `expected:` staleness unchanged; the model check is now per field
  against the field's AI task (`agent.chat` / `agent.attachment` / `agent.speech`)
  and returns `{reason, needs, field}`, which `UsersLive.after_update/4` shows at
  that field. A kept value is not re-checked, so an outside-list model an admin
  set can be carried back by the form without failing.
- **Resolution** (`effective/1`, `model/2`, `resolve/4`): own → default →
  fallback (own deleted/switched-off/credential-less, judged by
  `Models.usable_uuids/1`), `outside_list?` only on a usable own model. Every
  reader goes through it — `Turns`, `Processor.picture_mode/1` (an own usable
  vision model always describes the user's pictures), `Speech.transcribe/4`,
  the dock's microphone, the AI tasks' `endpoints`
  (`UserConfig.endpoint_uuids/1` per task). The remaining direct `Config.*`
  reads are site-level only (Settings page, Telegram help/status), as intended.
- **`Models.callable?/1`** mirrors the AI module's own request-path credential
  ladder (`endpoint_credential_status/1` in `phoenix_kit_ai`: integration_uuid,
  then provider, then the legacy `api_key`; lookups through
  `PhoenixKitAI.Cache.credentials/2`, so a turn pays the same answer a call
  would get). `Endpoint.kind/1 == :chat` matches the module's existing notion
  (`list_endpoints/1` filters the same way).
- **`Config`**: `selectable_endpoint_uuids/0` reads a damaged setting as `[]`;
  `canonical_uuid/1` accepts only 36-char uuids (no raw 16-byte form);
  `put_selectable_endpoints/2` takes only existing chat endpoints, dedupes;
  `put_*_endpoint` refuse a switched-off endpoint unless it is the one already
  set (`:switched_off`), and the Settings page says so at the field.
- **Pages**: Settings `save_models` takes only the three fields it offers,
  refuses a non-offered value (distinguishing "switched off"), keeps the stale
  guard; `save_selectable` takes only checkboxes the page rendered (hidden empty
  input included). Users → Configure offers "Default: <name>" plus every
  chatting endpoint per task with per-task fit marks, shows what is in effect
  (`models` source, never `own`), marks fallback and outside-list, per-task
  "money is not counted". The dock takes only the three keys as text
  (`save_models`), `use_default` sends one blank field, both refused unless the
  region is open; a refused save keeps the selection and marks every failing
  field (`MyAssistant.refused/3`). The microphone follows the speech model in
  effect, also without a reload.
- **Activity log**: the user's own model change is logged as
  `agent.user_settings_updated` with field names and the from/to endpoint
  uuids. Endpoint uuids are identifiers shown in the UI, not credentials — the
  API key lives in the endpoint row and never reaches the log; no chat text or
  prompt is logged. (PR #19's review doc phrases this as "no model values in the
  log line"; the precise behaviour is field names plus endpoint uuids.)
- **Dependency floors** (checked against the actual Hex tarballs, not the local
  checkout): `PhoenixKit.Integrations.get_credentials/2` exists in
  `phoenix_kit` **3.5.0**; `PhoenixKitAI.Cache.credentials/2`,
  `Tasks.check_selection/2`, `Endpoint.kind/1`, `TaskLimits.money_counted?/2`
  all exist in `phoenix_kit_ai` **0.27.0** — so `~> 0.27` / `>= 3.5.0` floors hold
  for every new call. The lock's `phoenix_kit_ai` 0.31.0 (`e5d73dc`) is within
  `~> 0.27`.
- **Gettext**: all new msgids are in the `.pot` and translated in all six
  catalogues (`translations_test` passes in the gate).

## Findings

None. The one issue the range had — dialyzer `contract_with_opaque` on
`Models.usable_uuids/1` returning `MapSet.t/1` — was already fixed on main
(`7feaab8`, plain list + `in`); confirmed by the dialyzer run below.

## Verification (this tree, `HEAD` = e5d73dc)

- `MIX_ENV=dev mix precommit` → exit 0: `format`, `compile
  --force --warnings-as-errors`, `gettext.extract --check-up-to-date`,
  `deps.unlock --check-unused`, `hex.audit`, `credo --strict` (70 checks,
  132 files, no issues), `dialyzer` (0 errors; 6 warnings all covered by
  `.dialyzer_ignore.exs`, 0 unnecessary skips).
- `MIX_ENV=test mix test` → **1528 tests, 0 failures**, exit 0, against local
  PostgreSQL (`phoenix_kit_agent_test`); `node` present, so the `:node` hook
  tests ran as part of the suite.
