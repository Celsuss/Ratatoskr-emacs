# Beads tasks

`SPC g t` (`M-x rata-beads`) opens the nearest enclosing `.beads` project in
the current window, like Magit status.
Use `C-u SPC g t` to choose a project directory. Each project has its own buffer.
The Beads CLI (`bd`) must be installed; Emacs startup works without it.

The dashboard groups tasks under epic headings, separated by a divider and blank
line. Press `TAB` on a heading to fold or expand its tasks. Each epic's own row
comes first; its tasks follow in priority order, including nested subtasks.
Epics are ordered by their own priority. Tasks without an epic appear under
**Other tasks**. Projects without groups keep the compact flat list.
Grouping follows explicit parent links, never ID prefixes or blocking dependencies.
If a filter excludes a parent, its children stay together under **Parent: ID
(outside this view)**, without adding excluded tasks.

The dashboard shows one row per task, with columns in this
order: **ID, Status, Pri, Type, Title**. Long titles are truncated at the window
edge so tasks always occupy one screen row. The default view contains
non-closed tasks; `f` offers open, ready, closed, and all. Ready uses Beads'
blocker-aware query rather than inferring readiness from task status.

Status colors follow the Gruvbox palette: open is blue, in progress yellow,
blocked red, deferred purple, and closed green. Priority runs from bold red
(`P0`) through orange (`P1`), yellow (`P2`), blue (`P3`), and muted gray (`P4`).
The same colors appear in task details. Customize the `rata-beads-status-*`
and `rata-beads-priority-*` faces to change them. Unknown values stay uncolored.

| Key | Action |
| --- | --- |
| `j` / `k` | Move with Evil |
| `RET` / mouse click | Show task text and details in the right side window |
| `g r` | Refresh (`g` in Emacs state) |
| `f` | Choose dashboard view |
| `TAB` | Fold or expand an epic group |
| `y` | Copy task ID |
| `q` | Close task details; in the dashboard, close both windows |

The detail window shows the description, design, acceptance criteria, notes,
and dependencies. Opening a task focuses its detail window, where text wraps.
Selecting another task updates the same side window, keeping the task list
visible. Related tasks can also be opened with `RET` or a click. Press `q` in
the detail window to return to the list. Press `q` in the dashboard to close
both the dashboard and its task window.

Queries run asynchronously through `bd --readonly --json`. A failed query keeps
the previous display and reports the error in `*Messages*`; the mode line marks
it as failed. Queries time out after `rata-beads-timeout` seconds (default 30).
Refreshing or killing a buffer cancels its pending query. There is no automatic
polling; refresh when agents have changed tasks.

This is an inspection interface: task creation, updates and closing stay in the
CLI. It never reads the database or JSONL exports directly, and leaves database
discovery and redirects to `bd`. Remote TRAMP projects are not supported.
The command interface was checked against Beads 1.3.4.

## Synchronization between machines

Tasks synchronize through the Dolt remote named `origin`, stored on GitHub under
`refs/dolt/data`. Source branches and task history travel separately; JSONL
exports are not used for synchronization.

On a fresh clone, install Beads 1.3.4 (or a compatible version) and Dolt, ensure
GitHub SSH access works, then run `bd bootstrap` and `just install-hooks`.
For an existing database, first configure its Dolt remote to the same task
history; do not initialize a second empty database to replace existing tasks.

The versioned hooks provide:

- Before `git push origin`, `bd sync --remote origin` pulls, checks conflicts,
  and pushes tasks. Failure blocks the code push. Pushes to other remote names
  are left alone. Task publication happens first, so a later code-push failure
  does not roll back task publication.
- After a successful merge (including a fast-forward pull) or rebase,
  `bd dolt pull --remote origin` retrieves tasks. A failure prints an explicit
  recovery command; Git has already updated code and cannot roll that back.
- A recursion guard prevents Dolt's internal Git commands from syncing again.
  Missing Beads or an uninitialized checkout produces an actionable error.

Git has no post-pull hook. An already-up-to-date `git pull` does not invoke the
merge/rebase hooks, even if tasks have changed. Use `just pull` (or
`just pull --rebase`) to always pull both code and tasks, including that case.
It suppresses the task hooks during its code pull and pulls tasks once after
success. A plain `git fetch` does not synchronize tasks. These hooks use the
task remote `origin` even when code is merged from another source.

Run `just test-git-hooks` to exercise hooks without contacting GitHub or using
a real Beads database. Existing pre-commit lint and compilation checks remain.
