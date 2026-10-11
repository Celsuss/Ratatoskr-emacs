# Plan — AI control center (`init-agent-center.el`)

Status: **phases 1–4 done** (written and implemented 2026-09-30; uncommitted).
Each `## Phase N` below is one unit of work, done in interactive Claude Code.
**This file is the progress record:** a phase is closed by appending ` [done]` to its
heading, or ` [blocked: <reason>]` when it needs the operator. The first heading
with neither marker is the next phase. Nothing is committed autonomously
(SAFETY_RULES), so git history is not the progress record — this file is.

## How to run this plan

In interactive Claude Code, in this repo, with one command. Not `rata-claude-loop`
(operator decision). `/goal` starts work immediately; each time Claude tries to stop,
an evaluator model checks the condition and sends it back to work until the condition
holds or the turn cap is reached. So the goal text carries the task, a measurable
condition and a cap, and the rules below are what it points at:

```text
/goal Implement plans/ai-control-center.md phase by phase, following its "Rules for each phase". Done when `grep -E '^## Phase' plans/ai-control-center.md | grep -vcE '\[(done|blocked: .*)\]$'` prints 0, every [done] phase has a line under its heading recording a passing `just are-verify` run at the level it names, and the last message reports PASS/FAIL/NOT TESTED per area. Stop after 10 tries.
```

The condition is a count that the plan file itself proves: phases still open. A
` [blocked: …]` phase counts as closed, on purpose, so a real blocker ends the goal
instead of being pushed through. Cap: four phases, about two stop attempts each, plus
slack.

### Rules for each phase

1. Re-read the "Design" section and the phase. Work on the first `## Phase N`
   heading with no `[done]` / `[blocked: ...]` marker, and only that one.
2. Follow AGENTS.md's ARE rules: run `just are-context "<phase title>"` first and
   open only what it names.
3. Write the tests the phase lists before the code, and see them fail.
4. Run the verification level the phase names (`just are-verify relevant` or
   `full`). Never weaken, skip or delete a test to get it green.
5. When it passes, append ` [done]` to the phase heading and add one line under
   it: date, verify level run, PASS / FAIL / NOT TESTED per area.
6. If the phase needs a decision or action from the operator, or verify still
   fails after two honest fix attempts, append ` [blocked: <one-line reason>]`
   and stop.
7. Do the `.are/SYSTEM.md` §3 self-improvement check, then take the next phase.
8. Never commit, never touch uncommitted changes that predate the run (e.g.
   `lisp/init-claude-loop.el`), never run anything `.are/rules/SAFETY_RULES.md`
   forbids.

## Goal

One side buffer, toggled like org-agenda, that lists every live agent-shell session
across all persp layouts and shows for each one: **which layout/repo it belongs to**
and **whether it is working, waiting for you, or finished** — so you stop visiting
each layout to find out. `RET` on a row takes you to the layout and the shell.
Loosely modelled on Orca's agent sidebar: a list of agents grouped by repo, with a
status badge per agent, and "needs attention" sorted to the top.

Out of scope for this plan: spawning git worktrees per agent, merging, diff review.
Those are Orca features, but they are a different module (see *Later*).

## What agent-shell already gives us (verified in `elpaca/sources/agent-shell` @ 4aa030e)

We do not need to poll or parse buffer text. agent-shell exposes all of this:

| Need | API | Where |
|---|---|---|
| Every live shell | `(agent-shell-buffers)` | `agent-shell.el:1645` |
| Coarse state | `(agent-shell-status :shell-buffer B)` → `busy` / `blocked` (permission pending) / `ready` | `agent-shell.el:1938` |
| Push notifications | `(agent-shell-subscribe-to :shell-buffer B :on-event FN)` (nil `:event` = all events) | `agent-shell.el:5882` |
| Hook for new shells | `agent-shell-mode-hook`, run *after* `agent-shell--state` is set, so subscribing there works | `agent-shell.el:4520` |
| Session title | `(map-nested-elt agent-shell--state '(:session :title))` + `session-title-changed` event | `agent-shell.el:7733` |

Events that matter (documented at `agent-shell.el:5890-5935`):
`init-started` … `init-finished`, `prompt-ready`, `input-submitted`,
`permission-request`, `permission-response`, `tool-call-update`, `turn-complete`
(carries `:stop-reason`, `:usage`), `session-title-changed`, `error`, `clean-up`
(buffer being killed), `idle`. `agent-message-chunk` fires per streamed chunk — do
**not** re-render on it.

`agent-shell-status` alone cannot tell "finished and you haven't looked" from "idle
since yesterday", nor show an error. That is the one thing the event stream adds, and
it is why the design keeps its own small state per shell rather than only calling
`agent-shell-status` at render time.

persp-mode: `persp-add-buffer-on-after-change-major-mode` is nil (the default, not
overridden in `init-persp.el`), so a shell buffer is **not** reliably a member of the
layout it was opened in. The layout is therefore *recorded* when the shell starts
(current persp name in `agent-shell-mode-hook`), with `persp--buffer-in-persps` as a
fallback for shells opened before the module loaded.

## Design

### States (the model)

| State | Entered on | Meaning shown to you | Sort |
|---|---|---|---|
| `needs-input` | `permission-request`, or status `blocked` | waiting on a permission answer | 1 |
| `error` | `error` event | last request failed | 2 |
| `done` | `turn-complete` while the shell is not the selected window's buffer | finished, not yet looked at | 3 |
| `working` | `input-submitted`, `permission-response`, `tool-call-update`, or status `busy` | agent busy | 4 |
| `starting` | `init-started` … before `prompt-ready` | handshaking | 5 |
| `ready` | `prompt-ready`, or `done` once you visit the buffer | idle, seen | 6 |

- One **pure** function owns every transition:
  `(rata-agent-center--next-state STATE EVENT VISIBLE-P)` → new state. Tests hit it
  directly with synthetic event alists; nothing in `tests/` starts an agent.
- `done` → `ready` happens on `window-selection-change-functions` /
  `buffer-list-update-hook` when the shell becomes the selected buffer — the
  "unread" marker, like a mail client.
- Reconciliation: at render time, if the recorded state disagrees with
  `agent-shell-status` in a way events can't explain (e.g. recorded `working` but
  status `ready` and no `turn-complete` seen), trust `agent-shell-status`. Events
  are the fast path, `agent-shell-status` is the truth.

### Registry

A hash table keyed by shell buffer → plist:
`:buffer :layout :project :agent :title :state :since :last-stop-reason :cost`.
`:project` is `(project-root (project-current))` of the shell's `default-directory`,
abbreviated; `:agent` is the config's `:buffer-name` ("Claude", "Pi").
Entries are dropped on `clean-up` and by a `buffer-live-p` sweep at render time.
`agent-shell-subscribe-to` returns a token; keep it in the entry so the module can
be unloaded cleanly (`rata-agent-center-disable` unsubscribes everything).

Subscriber callbacks only update the entry and schedule a render — same discipline
as claude-loop's trampoline: never render, `save-buffer` or run hooks inside an
agent-shell event callback. agent-shell already demotes a subscriber error to a
`message`, which would hide bugs; wrap the callback body so an error is recorded on
the entry and shown as `error` in the list instead.

### The buffer `*Agents*`

- `rata-agent-center-mode`, derived from `tabulated-list-mode`.
- Rows grouped by layout via Emacs 30 `tabulated-list-groups` (same mechanism as
  jira's sprint grouping, D-018). Group heading: `layout — project root`.
- Columns: status badge (nerd-icon + face), agent, session title (truncated),
  time in current state (`3m`, `1h`), last stop reason / cost when known.
- Within a group sort by the state order above; groups sorted by their most urgent row.
- Faces: `rata-agent-center-needs-input` (gruvbox red/orange, bold),
  `-done` (green), `-working` (yellow), `-error` (red), `-ready` (dim). Matches the
  `rata-persp-active-layout` face style in `init-persp.el`.
- Rendering is debounced: events call `rata-agent-center--schedule-render`, which
  arms one 0.2 s timer; the render is a no-op when `*Agents*` is not visible. A 30 s
  repeating timer refreshes the "time in state" column, only while visible.

### Side window (the org-agenda feel)

- `rata-agent-center-toggle` displays `*Agents*` with
  `display-buffer-in-side-window` — `(side . right) (slot . 0) (window-width . 45)
  (dedicated . t) (window-parameters (no-delete-other-windows . t))`. A side window
  survives `C-x 1` / `SPC w m`, which is what makes it feel like a panel rather than a
  buffer. Side and width are `defcustom`s.
- A shackle rule for `*Agents*` would fight this; add none, and add a comment to the
  shackle list in `init-system.el` saying so (as `*claude-loop*` is placed by shackle,
  this is the first side-window buffer in the config).
- **Layout switches are the known risk.** persp-mode restores each layout's saved
  window configuration on switch, which will close or duplicate a side window. Plan:
  a global `rata-agent-center--pinned` flag set by the toggle; on
  `persp-activated-functions` re-display the side window if pinned, and exclude
  `*Agents*` from persp's saved state (`persp-filter-save-buffers-functions`) so it is
  never restored as an ordinary window. Phase 2 must verify this interactively first
  — it is the one piece of the design not provable from source.
- Evil: the mode derives from `tabulated-list-mode`; keys go through
  `evil-define-key*` in `normal` state (memory: evil shadows special-mode keymaps).

### Keys

In `*Agents*` (normal state):

| Key | Action |
|---|---|
| `RET` | switch to the row's layout (`persp-switch`), then show the shell in the main (non-side) window and select it; marks `done` → `ready` |
| `o` | show the shell in the main window, keep focus in `*Agents*` |
| `TAB` / `za` | fold group (tabulated-list-groups) |
| `]]` / `[[` | next / previous row that needs attention (`needs-input`, `error`, `done`) |
| `c` | new agent-shell in the row's layout and project |
| `K` | interrupt the row's shell (`agent-shell-interrupt`, confirms) |
| `g r` | force refresh |
| `q` | close the side window (unpins) |

Global leader, under the existing `SPC a i` AI group, at top level in
`(with-eval-after-load 'general …)` (FAIL-0009):

| Key | Command |
|---|---|
| `SPC a i o` | `rata-agent-center-toggle` ("overview") |
| `SPC a i n` | `rata-agent-center-next-attention` — jump straight to the most urgent shell without opening the panel |

`SPC a i a` is taken (aider prefix); `SPC a i o` and `SPC a i n` were free on 2026-09-30 —
re-check `init-llm.el`, `init-khoj.el`, `init-claude-loop.el` before binding.

### Ambient signal (so you don't need the panel open)

- A `global-mode-string` segment, e.g. `⚠2 ✓1 ●3` (needs-input / done / working),
  hidden when all zero, propertized so a click opens the panel.
- ~~Desktop notifications~~ — dropped by the operator on 2026-09-30. Do not build.

### Module placement

- `lisp/init-agent-center.el`, loaded right after `init-persp` in `init.el` (it uses
  persp at runtime and agent-shell only via hooks). No `use-package` — it owns no
  package, same as `init-claude-loop.el`.
- All agent-shell / persp calls are behind `with-eval-after-load` or runtime
  `fboundp` checks; `declare-function` for the rest. Never `require 'agent-shell`
  at load (it would defeat `:commands` deferral and L-028).
- Shells already open when the module loads (or after `SPC q r`) are adopted by
  scanning `(agent-shell-buffers)` once `agent-shell` is loaded.

## Phase 1: State model and registry (no UI) [done]

2026-09-30 — `just are-verify relevant`: lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (10 new `rata-test-agent-center-*`), work-agenda PASS; live agent-shell path NOT TESTED.

- Create `lisp/init-agent-center.el` with header, `provide`, `init.el` entry after
  `init-persp`, and a row in `.are/knowledge/MODULES.md` (area `ui,state`, MEDIUM,
  verify `relevant`).
- Implement the pure `rata-agent-center--next-state` and the state sort order.
- Implement the registry, the `agent-shell-mode-hook` subscriber, layout/project
  capture, `clean-up` removal, adoption of existing shells, and
  `rata-agent-center-disable`.
- Tests in `tests/run-tests.el`: every row of the state table as a transition
  test; registry add/update/remove driven with synthetic event alists on a temp
  buffer (bind the callback directly, no agent-shell process); an erroring
  callback lands in `error` rather than vanishing.
- Verify: `just are-verify relevant`.

## Phase 2: Side-window buffer [done]

2026-09-30 — `just are-verify full`: lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (18 `rata-test-agent-center-*`, incl. layout-switch invariant), work-agenda PASS, batch-startup PASS; GUI-frame layout switch (`SPC l l`) confirmed by the operator by hand the same day (panel stays across switches and lists live agent-shell sessions); live agent-shell path NOT TESTED. persp behaviour recorded as L-053.

- **First**, settle the layout-switch risk with a test, not by eye: an ERT test in
  a fully initialised batch Emacs that creates two persp layouts, opens the panel,
  switches layouts both ways, and asserts exactly one `*Agents*` side window after
  each switch. Write it before the pin/re-display code so it is seen failing first.
  Record what persp-mode actually did in `.are/memory/LESSONS.md`.
- The operator confirms once by hand in a GUI frame afterwards (`SPC l l`); list
  that as NOT TESTED in the report, do not mark the phase blocked on it.
- `rata-agent-center-mode`, grouped `tabulated-list` render, faces, debounced
  render, time-in-state timer, toggle, pin/re-display on layout switch, persp save
  filter.
- `RET` / `o` / `q` / `g r` only.
- Tests: render a fixture registry into the buffer and assert group headings, row
  order and badges (same shape as `rata-test-jira-issues-list-groups-by-sprint`);
  add `SPC a i o` to `rata-test-keybindings-live-after-init`.
- Verify: `just are-verify full` (touches `init.el` load order and window
  behaviour → startup).

## Phase 3: Navigation and actions [done]

2026-09-30 — `just are-verify relevant`: lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (25 `rata-test-agent-center-*`), work-agenda PASS; live agent-shell path (real `c` / `K` against an agent) NOT TESTED. Folding is a folded-layouts set re-applied on every render (tabulated-list has no fold of its own).

- `]]` / `[[`, `c`, `K`, folding, `SPC a i n`.
- `done` → `ready` on visit (window-selection hook).
- Tests: next-attention picks the right buffer from a fixture; visiting clears `done`.
- Verify: `just are-verify relevant`.

## Phase 4: Ambient signal [done]

2026-09-30 — `just are-verify full`: lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (27 `rata-test-agent-center-*`), work-agenda PASS, batch-startup PASS; the segment's appearance in a GUI doom-modeline NOT TESTED (batch `format-mode-line` never evaluates `:eval`, L-054).

- Mode-line segment only (no desktop notifications — operator decision).
- Tests: segment text for fixture counts, empty when zero.
- Update `AGENTS.md` (a `init-agent-center.el` entry under *Key modules*) and
  README.org keybinding tables.
- Verify: `just are-verify full`.

## Later (not planned in detail)

- Answer a permission request from the panel (`a` allow / `A` always / `d` deny)
  without visiting the shell. agent-shell has permission-response internals
  (`agent-shell--send-permission-response`) but no public command taking a buffer;
  needs an upstream look first.
- Show the latest agent message line under each row (from `agent-message-chunk`,
  throttled).
- Orca-style worktree-per-task: `c` offers a new git worktree (agent-shell has
  `agent-shell-worktree.el`) and a layout named after it.
- Include claude-loop runs as rows (it already has its own state machine; read it,
  don't duplicate it).

## Operator decisions (2026-09-30)

1. Panel on the **right**, **45 columns** to start (`defcustom`s, so adjustable).
2. A finished turn shows **`done`** — kept until the shell is visited, then `ready`.
3. **No desktop notifications** for now. The mode-line segment stays.
4. Leader keys **`SPC a i o`** (toggle panel) and **`SPC a i n`** (next attention).

## Verification honesty

Nothing here can be verified against a real agent in `tests/`: agent-shell's mock
ACP server is a Swift binary not built on this host, and the real `claude-agent-acp`
is an integration. Every phase reports the live-agent path as **NOT TESTED** and
asks the operator to exercise it once by hand.
