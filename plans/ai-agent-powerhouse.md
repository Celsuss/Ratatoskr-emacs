# Plan — AI agent powerhouse (follow-ups to the `*Agents*` panel)

Status: **proposed, not started** (agreed with the operator 2026-10-05).
Predecessor: `plans/ai-control-center.md` (all four phases done, d887006).

This file is the reference for implementing seven features in later sessions. Each
feature is a self-contained section with its own label (`A2`, `B6`, …), and these
labels are the names used in conversation and in commit messages. They come from the
2026-10-02 survey, whose other items (A1, A3–A5, B7, D13–D15) were not chosen this
round and are listed at the end for reference.

## How to run this plan

- One feature per session, or one phase of a feature. Start each session the ARE way:
  `just are-context "<feature label>: <what>"`, then open only what it names.
- Every feature below says which module it lands in, which tier that module is, and
  which verification depth closes it. A feature that touches `init-claude-loop.el` is
  CRITICAL and needs operator approval. None of the seven here should.
- **Global leader keys go at top level in `(with-eval-after-load 'general …)`**, never
  in a deferred `:config` (FAIL-0009, L-011). Add each new entry point to
  `rata-test-keybindings-live-after-init`.
- **agent-shell is never required at load** (L-052): test with `featurep`, declare with
  `declare-function`, and list un-autoloaded commands under `:commands` in `init-llm.el`,
  because none of agent-shell's senders carry an autoload cookie.
- Tests run on synthetic data. Nothing in `tests/` starts a real agent, contacts an MCP
  client, or touches `~/workspace/second-brain/`. Integrations are reported NOT TESTED.
- Mark a section `[done]` in its heading when it lands, as in `ai-control-center.md`.

## Suggested order

1. **A2** — smallest, and it lives entirely inside `init-agent-center.el`.
2. **C11** — mostly key bindings to upstream commands, cheap, and useful immediately.
3. **B6** — worktree-per-task. B8 depends on it.
4. **B8** — Jira / org → agent. Needs B6.
5. **B9** — session history. Independent, but easier once B6 decides where state lives.
6. **C12** — prompt library. Independent.
7. **C10** — Emacs as an MCP server. The largest and the only one that needs a design
   session and a package decision first (see its *Decisions needed*).

---

## A2 — Activity line under each row [done]

2026-10-08 — implemented in `init-agent-center.el`; verification recorded below the
*Module / tier / depth* line. **Decision taken in-session: a second line, not a
column.** A column would get only what is left after five columns. The two
one-line-per-row assumptions were cheap to keep: the activity line carries the row's
`tabulated-list-id` (so `RET`/`o`/`K`/fold act on it), and `]]`/`[[` skip lines with
the `rata-agent-center-activity` property. A custom `tabulated-list-printer` is safe
only because the panel has no sort key (no incremental update). Shown for every
state but `ready`.

**Goal.** Under each row in `*Agents*`, one dim line saying what the shell is doing
right now: the latest tool call (`Bash: just test`, `Edit: lisp/init-org.el`) or, if
there is none, the start of the latest agent message. It tells you what `working`
actually means without visiting the shell.

**Upstream.** Both events are already on the subscription the panel holds:
`tool-call-update` (`agent-shell.el:2783`, `:3005`) and `agent-message-chunk`
(`:2737`). The plan's original rule stands: **never re-render per chunk**.

**Design.**
- `rata-agent-center--handle-event` stores `:activity` (a short string) on the entry
  for `tool-call-update`, and for `agent-message-chunk` only when no tool call is in
  flight. That is a plist write, with no render.
- The existing 0.2 s debounced render picks the change up. Add a minimum interval for
  activity-only changes (e.g. 1 s, `defcustom rata-agent-center-activity-interval`) so
  a streaming turn does not re-render five times a second.
- Formatting is pure: `rata-agent-center--activity-line (entry width)` takes the first
  line, truncates it to the panel width, and returns nil for states where it adds
  nothing (`ready`, `done` after visit).
- `tabulated-list` has one line per row. Either render the activity as a second line
  through the `tabulated-list-printer`, or as a column. **Decide in-session**: the
  second line reads better but complicates `]]`/`[[` and the fold logic, which assume
  one row per line.
- `defcustom rata-agent-center-show-activity` (default t) turns it off.

**Tests.** Pure: the formatter on tool-call / chunk / empty payloads. Event: a synthetic
burst of 50 chunks produces at most one scheduled render per interval.

**Module / tier / depth.** `init-agent-center.el`, MEDIUM → `just are-verify relevant`.

2026-10-08 — `just are-verify full` (the tree also holds pre-existing CRITICAL changes): lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (33 `rata-test-agent-center-*`, 5 new), work-agenda PASS, claude-loop-acp PASS, batch-startup PASS; activity lines against a live agent and in a GUI frame NOT TESTED.

---

## B6 — One worktree per task (Orca-style parallel agents) [done]

2026-10-08 — implemented as `lisp/init-agent-worktree.el` (no package). **Decisions
taken with the operator:** worktrees under the repository's `.agent-shell/worktrees/`
(upstream's location, ignored through `info/exclude`); base = the branch checked out
where you start it, recorded as `branch.<b>.rataAgentBase`; branches `agent/<slug>`.
**Upstream could not be wrapped:** `agent-shell-new-worktree-shell` takes no name,
branch or base, so the module runs `git worktree add -b` itself. Keys: `SPC a i c w` /
`C` new, `SPC a i c W` / `X` finish. Found while planning: the worktree's transcripts are
ignored files that `git worktree remove` deletes, so finish copies them to the main
checkout first (L-061). Verification is recorded under *Module / tier / depth*.

**Goal.** Several agents edit the same repository at once, each in its own git
worktree, each in its own persp layout. Today every shell in a project shares one
checkout and can overwrite the others' work.

**Upstream.** `agent-shell-new-worktree-shell` (`agent-shell-worktree.el:108`) creates
the worktree at `<project-root>/.agent-shell/worktrees/<random-name>` (e.g.
`adoring-hawking`), asks you to confirm the path, and starts a shell there. Not bound
anywhere today.

**Design.**
- `rata-agent-center-new-worktree-shell` (panel key `C`, plus a leader key, e.g.
  `SPC a i c w`):
  1. Read a task name and turn it into a branch name with a pure function
     `rata-agent-worktree-branch-name`, e.g. `agent/<slug>`.
  2. Create the persp layout named after the branch and switch to it, so the panel's
     layout recording (`agent-shell-mode-hook`) files the shell under it.
  3. Call upstream, or call `git worktree add` directly if upstream cannot be given a
     name/branch non-interactively. **Check this first** — it decides whether this is
     a wrapper or a re-implementation.
- `rata-agent-center-finish-worktree` (panel key, e.g. `X`): kill the shell, close the
  layout, `git worktree remove`. **It refuses if the worktree has uncommitted changes
  or the branch is not merged into its base, and it always asks first.** Branch
  deletion is a separate, explicit confirmation.
- Panel rows in a worktree show the branch (pure: derive it from the shell's cwd).

**Decisions needed.**
- Worktree location: upstream's `.agent-shell/worktrees/` inside the repository (it
  must be gitignored there — check), or a sibling directory outside it.
- Branch naming scheme and base branch (current branch, or the repo's default).

**Safety.** `git worktree remove` and branch deletion are destructive. Never run them
without confirmation, and never in tests against a real repository. Tests use a temp
repository.

**Tests.** Pure: branch-name slugging. Temp-repo integration: create → dirty → finish
refuses; clean + merged → finish removes it.

**Module / tier / depth.** `init-agent-center.el` (or a new `init-agent-worktree.el`
if it grows past ~150 lines), MEDIUM → `relevant`.

2026-10-08 — `just are-verify full` (`init.el` changed): lint PASS, claude-loop-e2e PASS, are-audit PASS, compile PASS, ert PASS (10 new `rata-test-agent-worktree-*`, temp git repos), work-agenda PASS, claude-loop-acp PASS, batch-startup PASS; a real agent starting in a worktree, and the keys in a GUI frame, NOT TESTED.

---

## B8 — Start an agent from a Jira issue or an org TODO

**Goal.** From a Jira list or detail buffer (`, a`), or from an org heading, start a
worktree shell (B6) whose first prompt is the issue's summary and description, and
record the link back.

**Design.**
- **Jira:** `, a` mirrored under the local leader like the other jira.el keys (D-015),
  bound at top level, not in `use-package jira`'s `:config` (FAIL-0016: that block never
  runs). It reads the issue at point through jira.el's existing fetch, builds the
  prompt with a pure `rata-agent-prompt-from-jira (issue)`, and calls the B6 command
  with the issue key as the task name (branch `agent/ABC-123-<slug>`).
- **Org:** `SPC o a` (or `, a` in org-mode) on a heading does the same with the heading
  title and body. A heading with a `:JIRA:` property can fetch the Jira description too.
- **Write-back:** set `:AGENT_SESSION:` (the session id) and `:AGENT_BRANCH:` on the
  org heading. For a Jira issue, write them on the matching `work_tasks.org` heading if
  the import (D-019) already created one, and otherwise write nothing.
- **D-019 holds:** nothing is sent to Jira, no new heading is created by this command,
  and an existing heading only gains properties. If that is ever widened, it needs a
  new decision record.
- The session id is only known once the shell reports it. Write the property from the
  first event that carries it, through the panel's subscription, not by polling.

**Decisions needed.** Whether the first prompt is sent automatically or left in the
prompt for you to edit and submit. Auto-send is convenient, but it spends money on
every keypress.

**Tests.** Pure: prompt building from fixture issues and fixture org entries. Org:
property write-back in a temp buffer. Nothing touches `~/workspace/second-brain/`.

**Module / tier / depth.** `init-jira.el`, `init-org.el` and the B6 module. MEDIUM →
`relevant`. Read `rata-test-jira-buffers-keep-evil-and-mirror-keys` before adding the
key.

---

## B9 — Session history

**Goal.** Find and reopen past agent sessions: search old transcripts, resume a session
by picking it rather than pasting a session id, and see recently closed shells in the
panel.

**Upstream.**
- `agent-shell-resume-session (session-id)` (`agent-shell.el:1512`) prompts for an agent
  and resumes it.
- `agent-shell-open-transcript` (`:10198`) opens the current shell's transcript only.
- Transcripts live in `<project>/.agent-shell/transcripts/`
  (`agent-shell--default-transcript-file-path`, `:9993`).
- `agent-shell-session-strategy` / `agent-shell-session-choices-function` (`:854`, `:870`)
  control upstream's own session picker.

**Design.**
- `rata-agent-history` (`SPC a i h`): a consult source over transcripts from known
  projects (projectile's list), with annotations for project, date and first prompt
  line. `RET` opens the transcript. An embark action resumes the session if the id can
  be recovered from the transcript. **Check that the transcript records the session id;**
  if it does not, record it ourselves (see below).
- Recently closed: when the panel sees `clean-up`, keep a capped list (e.g. last 10) of
  `(title layout project session-id transcript closed-at)`. Show it as a folded
  "Recently closed" group at the bottom of `*Agents*`, with `RET` to resume and `o` to
  open the transcript. Persist it via savehist so it survives a restart.

**Tests.** Pure: transcript header parsing and the capped list. Panel: a synthetic
`clean-up` moves an entry into the closed group.

**Module / tier / depth.** `init-agent-center.el`, MEDIUM → `relevant`.

---

## C10 — Emacs as an MCP server for Claude

**Goal.** Agents can ask Emacs what you can see: flycheck/LSP diagnostics for a file or
project, xref definitions and references, the list of open project buffers, and maybe
the region. **Read-only.** The agent never edits through Emacs, and never evaluates
elisp.

**Current state.** `lisp/init-mcp.el` is commented out in `init.el` ("experimental").
Its keys are in a deferred `:config`, so they would be dead even if it were enabled
(FAIL-0009). It is to be replaced, not repaired.

**Decisions needed (design session first).**
- **Package:** claude-code-ide.el (ships an MCP server plus an IDE integration, but may
  assume it owns the Claude session, which would clash with agent-shell), or
  mcp-server-lib (a library: we register only the tools we want). Read both before
  choosing. The leaning is mcp-server-lib, for the explicit tool list.
- **Transport and reach:** how `claude-agent-acp` / `claude` discover the server (MCP
  config in `~/.claude.json`, per-project `.mcp.json`, or passed through ACP session
  options). Whatever reaches the loop's agents must not widen the claude-loop's
  permissions (SAFETY_RULES).
- **Tool list:** start with `diagnostics(file|project)`, `xref-definitions(symbol)`,
  `xref-references(symbol)`, `project-buffers()`. Each one is a pure formatter over Emacs
  state, so it is testable in batch.

**Policy.** No tool that writes a buffer, runs a command, or evaluates code. A
test asserts the registered tool list equals an allowlist, so adding a tool is a
deliberate diff.

**Tests.** The tool functions on fixture buffers with synthetic flycheck errors.
Allowlist equality. The MCP transport and any real client are NOT TESTED.

**Module / tier / depth.** A new `init-mcp.el` that replaces the old one. HIGH, because
it exposes Emacs state to an external process → `just are-verify full`. Record the
package choice as a decision (D-0xx).

---

## C11 — Bind the unused context senders

**Goal.** Put agent-shell's existing but unbound commands under `SPC a i c`.

| Command | Proposed key | Note |
|---|---|---|
| `agent-shell-send-screenshot` | `SPC a i c S` | saves to `.agent-shell/screenshots/` — gitignore check |
| `agent-shell-send-clipboard-image` | `SPC a i c i` | |
| flycheck error at point | `SPC a i c e` | `agent-shell-context-sources` already includes `error`; check whether `send-dwim` covers it before writing a wrapper |
| `agent-shell-prompt-compose` | ~~`SPC a i c p`~~ taken by pi; pick another | compose buffer for long prompts |
| `agent-shell-set-session-model` | `SPC a i c m` | |
| `agent-shell-set-session-mode` | `SPC a i c M` | |
| `agent-shell-fork` | `SPC a i c k` | fork the conversation into a new shell |
| `agent-shell-resume-session` | (B9 covers it) | |

Keys are suggestions; check `SPC a i c` for collisions first. Every command goes into
`:commands` in `use-package agent-shell` (none are autoloaded upstream), and a curated
few go into `rata-test-keybindings-live-after-init`.

**Module / tier / depth.** `init-llm.el`, MEDIUM → `relevant`.

---

## C12 — Prompt library [done]

2026-10-08 — built as `lisp/init-agent-prompts.el`, key `SPC a i c P` (not `SPC a i P`: agent-shell keys live under `aic`), storage `prompts/*.md` + `rata-agent-prompt-extra-directory`. Verification recorded in the session report; live insertion into a real shell NOT TESTED.

**Goal.** Reusable prompts ("review this diff", "write tests for this function",
"explain this error"), picked with consult and sent to the current shell, with the
relevant context filled in.

**Design.**
- **Storage — decide in-session:** a directory of prompt files under the repository
  (e.g. `prompts/*.md`, versioned and reviewable), yasnippets in the agent-shell mode
  (cheap, but insert-only), or org-roam notes tagged `:prompt:` (they live in
  `second-brain`, which is off-limits autonomously, so the operator would write them).
  The leaning is versioned files in the repo with a per-machine extra directory.
- Placeholders such as `{{region}}`, `{{file}}`, `{{diff}}` and `{{error}}` are expanded
  by one pure function `rata-agent-prompt-expand (template context)`, where context is an
  alist collected from the source buffer.
- `rata-agent-prompt` (`SPC a i P`): pick a prompt with consult, expand it from the
  buffer you came from, and insert it into the current or a chosen shell. **Insert, not
  submit,** so you can edit it first (the same spend argument as B8).

**Tests.** Pure: expansion with missing and present context, and an unknown placeholder
(left visible, not silently dropped).

**Module / tier / depth.** `init-llm.el`, or a new `init-agent-prompts.el`. MEDIUM →
`relevant`.

---

## Not chosen this round (from the 2026-10-02 survey)

A1 answer permissions from the panel · A3 cost/context columns · A4 `stalled` state ·
A5 queue a follow-up prompt · B7 per-turn diff review · D13 claude-loop Phase 3 (CRITICAL) ·
D14 trim the `SPC a i` menu · D15 layout badges. B7 combines naturally with B6 once
worktrees exist.

