# Beads tasks

`SPC g t` (`M-x rata-beads`) opens the nearest enclosing `.beads` project in
the current window, like Magit status.
Use `C-u SPC g t` to choose a project directory. Each project has its own buffer.
The Beads CLI (`bd`) must be installed; Emacs startup works without it.

The dashboard shows one row per task, sorted by priority, with columns in this
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
