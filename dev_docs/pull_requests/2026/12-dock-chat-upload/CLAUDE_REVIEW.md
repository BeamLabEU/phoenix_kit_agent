# Claude Review — PR #12

- **Reviewer:** Claude Opus 5.5
- **PR title:** Fix the dock chat on live navigation, and move its file input to core's upload manager
- **Author:** Tymofii Shapovalov (`timujinne`)
- **Date reviewed:** 2026-11-12
- **Merge commit:** `711d0a9`
- **Range reviewed:** `711d0a9^1...711d0a9` — `Web.Dock` (upload manager, resumable uploads,
  `bind_entries/1`, `keep_finished_upload/3`), `Web.Dock.Panel` (hooks), `test/js/hooks.test.mjs`

## Overall Assessment

**Verdict: APPROVE with fixes. Risk: LOW.** The upload path takes nothing from the browser and
every callback is guarded. Two edge cases of the resumable flow were fixed (F1, F2).

## Findings

### F1 — BUG, LOW — two entries of one file shared core's assembled file (fixed)

Core names an upload after (owner, name, size, mtime), so the same file picked twice (two picks,
or two tabs — the dock is on every page) maps to one `.part`. The panel postpones that path for
as long as `Attachments.add/4` runs. A second entry registered meanwhile is "done" at once, its
consume postpones the **same** path, and when the first `add/4` ends, `drop_entry/2` releases it
(`File.rm`) under the second `add/4`, which then fails with `file_unreadable` /
`storage_unavailable` for a file that uploaded fine.

**Fix:** `attach_file/4` gives each `add/4` its own hard link (a copy where the directories are on
different file systems) of the assembled file in a private `Attachments.Work` directory
(`own_link/1`), removed when the task ends. A link is O(1) and keeps the inode alive after the
`.part` name goes. A link that cannot be made is a `file_unreadable` refusal through the normal
`attached/3` path. **Not added:** a test — reproducing the race needs two LiveView entries of one
file completing in a specific order. The existing upload tests cover the path through
`own_link/1`.

### F2 — BUG, LOW — a paused upload blocked Send with "Wait until the files are read." (fixed)

The manager's pause keeps the LiveView entry, and the server (which cannot see a pause) counts it
as on its way. So a paused file refused every send with a text that said to wait.

**Fix:** a paused file still blocks (the server cannot tell it from a slow one), and the refusal
now says so: "Wait until the files are uploaded and read; a paused file has to be resumed or
removed first." Translated in all six catalogues; the dock tests assert the new text.

## What was verified and holds

- The file path comes from server-side upload metadata (`part_path(id)`), never from the browser;
  `owner:` is the panel's own `user_uuid`, and uploads are configured only in the connected mount.
- `keep_finished_upload/3` is attached before the manager's hook, so a cancel of a done entry is
  halted first.
- `handle_progress`, `handle_async({:attach, _})` and every event go through `guarded/2`;
  `{:attach, entry.ref}` names are unique per entry.
- Log lines carry stage or refusal atoms only (`reason_class/1`); no name, text or path.
- `bind_entries/1` binds an entry to the chat open when it is first seen; `drop_fresh/2` cannot
  delete a fresh chat another entry is still uploading into.
- The `.Feed`, `.DockState`, `.Composer` and `.Waiting` hooks remove their listeners and timers in
  `destroyed()`; the re-join detection is consistent. `uploads_waiting` from the browser is only
  ever used to refuse a send.
