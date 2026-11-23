# Review since Hex 0.3.0

The reviewed range was `1fa4874..a79b309` on `main`. It includes PR #19, the dependency updates and the follow-up Dialyzer fix.

| Severity | Finding | Fix and regression coverage |
| --- | --- | --- |
| Medium | After a refused personal model save, the dock could disclose the name and model of an unlisted endpoint. It looked up the UUID from the submission to rebuild the select. | The dock restores a rejected choice using the options it previously displayed for that field. Tests cover an unlisted endpoint and previously offered choices that an administrator subsequently removed. |
| Medium | An old personal settings form could clear or replace a model selected in another tab or by an administrator. | The dock sends the original stored values of the submitted fields to the context. The context compares them under the user settings row lock and rejects a stale submission as a whole. A two-tab test checks that both fields survive the conflict correctly. |
| Medium | An old administrator checklist could overwrite a newer list of models users may choose. | Checklist saves serialize the comparison and write across connected nodes and compare against the setting in the database. On a conflict the form reloads the choices and checkmarks. A LiveView test verifies the newer selection survives. |
| Medium | The personal and admin forms accepted a blank speech field even when transcription was unavailable and the control was hidden. | The dock takes only the displayed model fields and checks whether a reset button was available. The admin form checks speech availability before accepting a clear. Tests start with a stored speech model and verify it survives. |
| Low | The administrator's model catalogue stopped after the first 500 enabled endpoints, before filtering for chat support. | One database query loads enabled and explicitly included endpoints. A 501-endpoint regression test verifies the full catalogue is available. |
| Low | If the administrator closed model selection while a personal form was open, the read-only view hid the reason a save failed. | Read-only fields display their errors. A LiveView test closes the list after opening the form and checks the refusal at the affected field. |

The range also changes migration V3, model resolution for chat, pictures and speech, AI task endpoint reporting, cost indicators and translations. The PostgreSQL suite exercises these paths with test providers.

## Verification

`mix precommit` passed, including compilation with warnings as errors, formatting, Gettext extraction, dependency checks, Credo and Dialyzer. The public Hex audit found no retired packages or security advisories.

`mix test --seed 946691` ran 1,533 tests against PostgreSQL with zero failures.
