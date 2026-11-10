# Beads tasks

`SPC g t` (`M-x rata-beads`) opens the nearest enclosing `.beads` project.
Use `C-u SPC g t` to choose a project directory. Each project has its own buffer.
The Beads CLI (`bd`) must be installed; Emacs startup works without it.

The dashboard uses Magit's section interface, groups tasks by status, and sorts
each group by priority. Descriptions start folded. The default view contains
non-closed tasks; `f` offers open, ready, closed, and all. Ready uses Beads'
blocker-aware query rather than inferring readiness from task status.

| Key | Action |
| --- | --- |
| `j` / `k` | Move with Evil |
| `TAB` | Fold or expand a section |
| `RET` | Open full task details, including dependencies and dependents |
| `g r` | Refresh (`g` in Emacs state) |
| `f` | Choose dashboard view |
| `y` | Copy task ID |
| `q` | Quit the window |

Queries run asynchronously through `bd --readonly --json`. A failed query keeps
the previous display and reports the error in `*Messages*`; the mode line marks
it as failed. Queries time out after `rata-beads-timeout` seconds (default 30).
Refreshing or killing a buffer cancels its pending query. There is no automatic
polling; refresh when agents have changed tasks.

This is an inspection interface: task creation, updates and closing stay in the
CLI. It never reads the database or JSONL exports directly, and leaves database
discovery and redirects to `bd`. Remote TRAMP projects are not supported.
The command interface was checked against Beads 1.3.4.
