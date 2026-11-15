# Codex review — PR #11

Date: 2026-11-15. Reviewed as part of the unpublished delta since `v0.2.0`,
including merge `73f7aa1` and the subsequent fixes through `c2751e5`.

Rechecked `Attachments.file_for_user/2`, both attachment and conversation
ownership, ready/deleted status filtering, the escaped attachment history
header, and the two non-negative confirmation-result counts. The client and
history retain only the permitted summary, never arbitrary write results.
No additional runtime defect found in these changes.

Fixed malformed documentation placeholders in `Turns.History` that strict
ExDoc generation treated as an unclosed HTML element.

Validation and cross-cutting findings are in the
[release review](../since-v0.2.0/CODEX_REVIEW.md).
