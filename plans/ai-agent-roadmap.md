# Plan — AI agent roadmap (consolidated)

Status: **proposed** (consolidated 2026-10-15).
Replaces four earlier plans, deleted 2026-10-15: `ai-agent-powerhouse.md` (round 1,
labels `A`–`D`), `agent-powerhouse-herdr.md` (round 2, labels `H1`–`H8`), `ai-agent-pillars.md`
(Pillars I–III) and `mcp-servers.md` (MCP client plumbing). Only the first and third were
committed; their longer design notes are still in git history. **This file is the progress record.** Old labels (`B8`,
`H3`, `P3` …) are kept in brackets so commit messages and conversation still resolve.

Done predecessor: `plans/ai-control-center.md` (Phases 1–6, the `*Agents*` panel).

---

## How to run this plan

In interactive Claude Code, in this repo:

```text
/goal Implement plans/ai-agent-roadmap.md phase by phase, following its "Rules for each phase". Done when `grep -E '^## Phase' plans/ai-agent-roadmap.md | grep -vcE '\[(done|blocked: .*)\]$'` prints 0, every [done] phase has a verification line under its heading, and the last message reports PASS/FAIL/NOT TESTED per area. Stop after 15 tries.
```

### Rules for each phase

1. Work on the first `## Phase N` heading with no `[done]` / `[blocked: …]` marker, and
   only that one. Re-read its *Decisions* first: a phase with an open decision is marked
   `[blocked: decision needed — …]` rather than guessed.
2. Write ERT tests in `tests/run-tests.el` first and see them fail. Tests run on synthetic
   events, fixture buffers and temp repos (`GIT_CONFIG_GLOBAL=/dev/null`). Nothing in
   `tests/` starts an agent, contacts an MCP client or LLM, or touches
   `~/workspace/second-brain/` or `~/.authinfo.gpg`.
3. Verify with `just test` (lint, compile, batch, ert, work-agenda). Phases touching
   `init-claude-loop*.el` or ACP plumbing also run `just test-claude-loop` /
   `just test-claude-loop-acp`. (The old plans' `just are-verify` / `are-context` were
   removed in 0f5f077.) Never weaken, skip or delete a test to get green.
4. On pass: append ` [done]` to the heading and one line under it — date, commands run,
   PASS / FAIL / NOT TESTED per area. Live agent / GUI behaviour is NOT TESTED unless the
   operator confirms it.
5. Never commit autonomously.

### Standing conventions (from all three plans, still binding)

- Global leader keys at top level in `(with-eval-after-load 'general …)`, never in a
  deferred `:config` (FAIL-0009). New entry points go into
  `rata-test-keybindings-live-after-init`.
- agent-shell keys live under **`SPC a i s`** (the old plans' `SPC a i c …` keys moved
  there in d5a714d). Panel keys go through `evil-define-key*`.
- agent-shell is never required at load (L-052): `featurep` + `declare-function`, and
  un-autoloaded upstream commands go under `:commands` in `init-llm.el`.
- Callbacks from agent-shell events only record and schedule; work happens in the
  debounced render path (the trampoline discipline).
- **The claude-loop gets none of this.** Nothing here may widen what a loop agent can do;
  anything that registers tools or hooks is checked to be absent from loop shells.
  Touching `init-claude-loop*.el` is CRITICAL and needs approval per change.
- Prompts built from context are **inserted, not submitted** (C12's decision), unless a
  phase records an explicit operator decision otherwise.
- External binaries (`uvx`, `ollama`, grammars …) missing → that feature is disabled with
  one warning; startup never breaks.

---

## What is already done

| Old label(s) | Feature | Where | Commit |
|---|---|---|---|
| control-center 1–4 | `*Agents*` panel, states, `SPC a i o` / `SPC a i n`, mode-line counts | `init-agent-center.el` | d887006 |
| A2 / control-center 6 | Activity line under each row | `init-agent-center.el` | 9a22468 |
| B6 | One worktree + layout per task, `SPC a i s w` / `W`, panel `C` / `X` | `init-agent-worktree.el` | 2499049 |
| C12 | Prompt library, `SPC a i s P` | `init-agent-prompts.el` | 881631d |
| Pillars Phase 2 · H4 (branch half) · B7 (partly) | Review hub over `base...HEAD`, directives sent back to the shell, `SPC a i r` / panel `r` | `init-agent-review.el` | 4995882 |
| H1 · A1 · control-center 5 | Answer permission prompts from the panel: `a` allow, `A` always, `d` deny | `init-agent-center.el` | 26cbb3e |
| C11 (partly) | Model / mode / fork / compose under the shell's local leader `,` | `init-llm.el` | 781d3ec |

**Operator decision 2026-10-15 (H1): `A` (allow always) stays in the panel**, although
the herdr plan had proposed leaving it out because upstream persists it as a durable
Claude settings rule. The claude-loop's responder still never sends it. H1's "several pending
requests → answer the oldest, show `?2`" was not part of 26cbb3e; it is not re-planned
unless it shows up in use.

---

## Phase order at a glance

```
1 Context senders & error feedback   (C11 rest, H8, P3-error)    keys, small
2 Event hooks                         (H5)                         needed by 5, 8
3 Stalled state                       (H7, A4)
4 Per-turn diff                       (H4 turn half, B7)
5 Handoff, follow-ups, broadcast      (H6, A5) + {{notes}} (P3)
6 Session history & restore           (H3, B9)
7 Task → agent from org / Jira        (B8, Pillars §9 spec spawning)
8 Second-brain capture                (Pillars P6: dev-log, troubleshooting harvest)
9 MCP plumbing + loop isolation       (mcp-servers.md)   CRITICAL half
10 Emacs as MCP server / orchestration (H2, C10)   design session first
```

---

## Phase 1: Context senders and error feedback

*Merges C11 (rest), H8, and the error-feedback half of Pillars Phase 3.*

| Command | Key |
|---|---|
| `agent-shell-send-screenshot` | `SPC a i s S` |
| `agent-shell-send-clipboard-image` | `SPC a i s i` |
| `agent-shell-insert-shell-command-output` | `SPC a i s !` |
| error at point / last `*compilation*` error → shell | `SPC a i s e` |

- **Check first:** whether `agent-shell-send-dwim` already sends the flycheck error at
  point (`agent-shell-context-sources` includes `error`). Only if it does not, write
  `rata-agent-send-error`: flycheck error at point, else the last error block of
  `*compilation*`, formatted by a pure function with file and line, inserted (not
  submitted) into the project's shell.
- **Check** that `.agent-shell/screenshots/` is kept out of `git status` the way B6 keeps
  worktrees out (`info/exclude`); extend the B6 helper if not.
- Model / mode / fork / compose stay under `,` and are not duplicated.

**Tests.** Pure: the error formatter on a fixture flycheck error and a fixture compilation
buffer. Keys in `rata-test-keybindings-live-after-init`.
**Module.** `init-llm.el` (+ `init-agent-worktree.el` if the exclude helper is reused).

---

## Phase 2: Event hooks

*H5.* Lets user code — and Phases 5 and 8 — react to agents without editing modules.

- `rata-agent-state-change-functions` — `(entry old-state new-state)`, run from the
  debounced render path, once per real transition (not per event); a signalling function
  is caught and reported once, never breaks the render.
- `rata-agent-worktree-created-hook` — `(dir branch base)`.
- `rata-agent-worktree-before-finish-functions` — `(dir branch base)`, run **after** the
  refusal checks and the confirmation, **before** `git worktree remove`, so the branch,
  its log and its diff still exist (Phase 8 needs that). A function returning nil does not
  stop the finish; a signal is reported and the finish continues.
- `rata-agent-worktree-finished-hook` — `(dir branch base)`, after removal.
- A commented example in `local.el.example`: a desktop notification on `needs-input`.
  Off by default (operator decision 2026-09-30 still stands).

**Tests.** Synthetic transitions call the hook once per change; an erroring hook leaves the
render intact; worktree hooks fire in order on a temp repo, `before-finish` while the
branch still exists.
**Module.** `init-agent-center.el`, `init-agent-worktree.el`.

---

## Phase 3: `stalled` state

*H7 (was A4).* A `working` shell with no event for `rata-agent-center-stall-seconds`
(default 180) shows as `stalled`: sorted just below `needs-input`, counted in the mode
line, reached by `SPC a i n` and `]]`. Any event returns it to `working`.

**Design.** Last-event timestamp per entry; one repeating 30 s timer that runs only while
some entry is `working`/`stalled`, re-rendering only when a row crosses the threshold.
`rata-agent-center--next-state` gets a `tick` event with an injected clock.

**Tests.** Pure transitions with an injected clock; timer is cancelled when nothing works.
**Module.** `init-agent-center.el`.

---

## Phase 4: Per-turn diff

*The half of H4 / B7 that the review hub does not cover.* The hub (`r`) shows the whole
branch against its base; this shows **what the agent changed in its last turn**, in any
git checkout, worktree or not.

- On the turn-start event, snapshot the shell's cwd with `git stash create` (a commit
  object; touches no ref, index or working tree; clean tree → `HEAD`), and the list of
  untracked files. Store both on the entry.
- Panel key **`D`** (`d` is now *deny*): `magit-diff-range` from the snapshot to the
  working tree, plus untracked files created since the snapshot listed separately.
- Not a git repo → say so and do nothing.
- Optional: a dim `+12 −3` diffstat in the activity line once the turn ends.

**Tests.** Temp repo: snapshot → edit → range contains exactly the edit; new untracked
file reported; non-repo refused.
**Module.** `init-agent-center.el`.

---

## Phase 5: Handoff, follow-ups, broadcast

*H6 (absorbs A5), plus the `{{notes}}` placeholder from Pillars Phase 3.* You are the
orchestrator; Phase 10 is the automated version.

- New placeholders in the C12 expander: `{{agent-output}}` (the source shell's latest
  agent message), `{{agent-diff}}` (Phase 4's last-turn diff), `{{notes}}` (region, or
  the current Org heading and body, of the buffer you came from).
- Panel `h` → pick a target shell → insert a handoff prompt from `prompts/handoff.md`.
- Panel `f` → read a follow-up → queued until that shell is next `ready`/`done`
  (upstream's prompt queue if it accepts while busy, otherwise ours, drained on the
  Phase 2 transition). Row shows `⏭1`. A shell that dies with a queued item drops it with
  a message.
- Panel `m` marks rows, `B` broadcasts one prompt to all marked shells (inserted;
  `C-u` submits).

**Operator decision 2026-10-15:** a queued follow-up **auto-submits** when the shell
frees up. You typed it and queued it on purpose, which is why this differs from Phase 7's
insert-only rule for generated prompts. The minibuffer prompt for `f` says it will be
sent automatically.
**Tests.** Pure: expansion of the three placeholders; the queue drains exactly once per
transition; dead-shell drop.
**Module.** `init-agent-center.el`, `init-agent-prompts.el`.

---

## Phase 6: Session history and restore

*H3 (supersedes B9).*

1. **Restore after restart:** on `kill-emacs-hook`, record each live shell
   `(project layout title session-id agent)` under `var/`; `SPC a i s o` offers to resume
   them, each in its layout, via `agent-shell-resume-session`. **Check in-session** that
   the agent config can be passed non-interactively.
2. **History:** `SPC a i s h` — consult over transcripts in known projects
   (`<project>/.agent-shell/transcripts/` and the copies B6's finish makes), annotated
   with project, date, first prompt; embark action "resume" when the session id is known.
   **Check** whether transcripts record the session id; if not, record it ourselves.
3. **Recently closed:** a folded group at the bottom of `*Agents*` (last 10, savehist);
   `RET` resumes, `o` opens the transcript.

Docs note: running Emacs as a daemon is the real "detach".
**Tests.** Pure: record/restore serialisation, transcript header parsing, the capped list.
Panel: a synthetic `clean-up` moves a row into "Recently closed".
**Module.** `init-agent-center.el`, or `init-agent-history.el` past ~200 lines.

---

## Phase 7: Task → agent from org or Jira

*B8 merged with Pillars §9 "spec-driven spawning". Both start a B6 worktree shell whose
first prompt is built from a task; they differ only in where the task comes from.*

### Which repository a task belongs to

The task files carry no repository today: the area files (`emacs_tweak_tasks.org`,
`dotfiles_tweak_tasks.org`, `homelab_tasks.org`, …) are flat `** TODO` lists with only
`:CREATED:`, project notes have `*** TODO`s under a project heading, and Jira issues have
a key. **Operator decision 2026-10-15:** most area files map to one repository, while
`work_tasks.org` holds tasks for several. Hence one inherited org property, `REPO`,
written once at the broadest level that is true, resolved most-specific first:

1. `:REPO:` on the task heading. Use it for a task that differs from the rest of its file,
   which is the normal case in `work_tasks.org`.
2. `:REPO:` on an ancestor heading: once per project note, under its project heading.
3. `#+PROPERTY: REPO ~/…` at the top of a file: once per area file, so every task in it
   resolves with no per-task work.
4. **Jira only:** the repository last picked for that Jira project key (`ABC` → repo),
   kept in savehist, offered as the default.
5. Otherwise, pick from projectile's known projects (most recent first). After a pick on
   an org heading, offer to write it back as `:REPO:` so the question is asked once per
   task.

`org-entry-get` with inheritance gives steps 1–3 in one call, provided
`org-use-property-inheritance` covers `REPO`; check that in-session. The resolver
`rata-agent-task-repo` is pure over (property value, Jira key, remembered alist) → a repo
or nil. A resolved path that is not a git repository is refused with its name, never
silently replaced by a pick. The operator adds the `#+PROPERTY` lines to the files
under `~/workspace/second-brain/` (off-limits autonomously); the plan only documents them.

### Base branch: the repository's default branch

**Operator decision 2026-10-15:** agent worktrees start from the repository's **default
branch**, not from whatever is checked out. This changes B6 for every entry point, the
manual `SPC a i s w` / panel `C` included:

- `rata-agent-worktree-base` (defcustom): `default` (new default) or `current` (B6's
  behaviour until now). `C-u` on the manual commands uses the other one for that run.
- The default branch is `refs/remotes/origin/HEAD` with `origin/` stripped, then
  `main`, then `master`. It is the **local** branch of that name, because finish checks
  "merged" with `merge-base --is-ancestor` against the recorded base. If none exists,
  the command refuses rather than guessing. No `git fetch`: a local default branch behind
  its remote is reported in the echo area, not updated, because network and ref changes
  are the operator's.
- The base is still recorded as `branch.<b>.rataAgentBase`, so finishing is unchanged.
- **The exception is agent-spawned helpers (Phase 10):** they are based on the lead's
  current branch. So `rata-agent-worktree-create` takes an explicit BASE, and
  `rata-agent-worktree-base` only chooses the default for the interactive commands. Build
  the BASE argument here so Phase 10 only has to pass it.
- Update the B6 entry in `AGENTS.md`, which currently says the base is "the branch
  checked out where you are".

### Starting the agent

- **Org:** `SPC o r a` (check free) / `, a` in org-mode on a heading. The prompt is built
  from the heading title, its body and parent goal/milestone headings. A heading with a
  `:JIRA:` property also pulls the Jira description. Branch `agent/<slug>`, or
  `agent/ABC-123-<slug>` when the heading has `:JIRA:`.
- **Jira:** `, a` in the jira.el list/detail buffers, mirrored under the local leader like
  the other jira.el keys and bound at top level (FAIL-0016). Branch `agent/ABC-123-<slug>`.
  Read `rata-test-jira-buffers-keep-evil-and-mirror-keys` before adding the key. If
  the issue has a `work_tasks.org` heading (`:JIRA:`), the repo lookup starts from that heading.
- Both call `rata-agent-worktree-create` with the resolved repo and branch. It gains an
  optional INITIAL-PROMPT argument: the shell starts asynchronously, so the prompt is
  inserted when the shell first reports ready (through the panel's subscription), not
  right after creation. The function currently returns only the path.
- Pure builders: `rata-agent-prompt-from-org (entry)`, `rata-agent-prompt-from-jira (issue)`.
- **Write-back:** `:AGENT_BRANCH:` and `:AGENT_SESSION:` on the org heading (for Jira, on
  the matching `work_tasks.org` heading only if the D-019 import already created one). The
  session id is written from the first event that carries it, via the panel's
  subscription, not by polling.
- **D-019 holds:** nothing is sent to Jira, no heading is created, an existing heading
  only gains properties (`REPO`, `AGENT_BRANCH`, `AGENT_SESSION`).

**Operator decision 2026-10-15:** the first prompt is **inserted, never submitted**
(consistent with C12). You read or edit it and send it yourself, so starting a task
spends nothing until you do. INITIAL-PROMPT is therefore inserted only; there is no
send option.
**Tests.**
- A stubbed shell receives the prompt as inserted text and no submit call.
- Pure: the repo resolver over each step of the chain; prompt building from fixture
  issues and fixture org entries.
- Inheritance: a temp org file with `#+PROPERTY: REPO`, a heading override and a project
  parent.
- Default-branch detection in temp repos: `origin/HEAD` set, only `main`, only `master`,
  none (refused). A worktree cut while a feature branch is checked out starts from `main`
  and records `main`.
- Property write-back in a temp buffer.
**Module.** `init-agent-worktree.el`, `init-org.el`, `init-jira.el`.

---

## Phase 8: Second-brain capture

*Pillars Phase 6 (§8 dev-log/ADR, §10 troubleshooting harvest).* The first phase that
writes into the org-roam tree, and the first that calls an LLM on its own.

### Dev log on finish

**Operator decision 2026-10-15:** this must not fill the roam tree with notes nobody reads.
So there is **one dev log per repository, short entries, and capture only when asked**.
There is no file per worktree.

- **Asked, default no.** A function on Phase 2's
  `rata-agent-worktree-before-finish-functions` asks `Capture dev log for <branch>?` with
  **no** as the default, so `RET` writes nothing. You say yes only when the task taught
  you something.
- **One place per repository, appended to.** The target is found in this order:
  1. The project's roam note: the note whose `REPO` (Phase 7's property) names this
     repository. Entries go under its `* Dev log` heading, created on first use.
  2. Otherwise a single `devlog-<repo>` roam node, created once with the `:devlog:` filetag.

  Each capture appends one dated subheading, `** 2026-10-15 agent/fix-login`, with
  `:BRANCH:` and `:BASE:` properties. Entries are chronological, so reading the heading
  top to bottom gives the project's history. **Check in-session** how to find a note by
  `REPO`: the roam DB may not index `#+PROPERTY` keywords, so a scan of
  `org-roam-directory` may be needed.
- **Only what git does not already hold.** The LLM is given `git log`/`--stat` over
  `base...branch` and asked for exactly two things: *decisions and why* and *lessons /
  gotchas*. No file list, no commit summary. If it answers that nothing is worth keeping,
  nothing is written and the echo area says so. An LLM failure also writes nothing and
  says so. The commits are on the base branch either way.
- **A real ADR becomes its own note by hand.** Run org-roam's `org-roam-extract-subtree`
  on the entry. Nothing is ever split into a file automatically.

### Troubleshooting harvest

`SPC a i s T` in a shell or dev buffer: the latest error plus the agent's resolution go
into the existing troubleshooting capture template, opened for editing
(`org-roam-capture`). It is only ever started by hand and never saved silently, so it has
no clutter problem.

**Approval.** Writing into `~/workspace/second-brain/` at run time is approved by the
decision above, and happens only on your explicit "yes" at finish or on `SPC a i s T`.
Implementation and tests still never touch that directory.
**Operator decision 2026-10-15: the summary uses the machine's default provider**,
`rata-llm-default-provider` (the first `rata-llm-providers` entry, D-022). At home that
is Ollama, so the code stays on the machine. At work, where there is no Ollama, it is the
work LiteLLM proxy set in `local.el`. No new setting is needed, because the provider list
is already per machine. If the provider is unreachable, that is an LLM failure: nothing
is written and the echo area names the provider.
**Tests.**
- Pure: entry text from a fixture LLM answer; a "nothing worth keeping" answer → no entry.
- Target resolution: a temp roam dir with a `REPO`-matching project note (appends under
  `* Dev log`, creating it once), and without one (creates `devlog-<repo>` once, appends after).
- Declined, default `RET` and LLM failure each leave every file byte-identical.
- `org-roam-directory` bound to a temp dir throughout; the LLM is stubbed.
**Module.** `init-agent-worktree.el` (or a small `init-agent-capture.el`).

---

## Phase 9: MCP plumbing for agent-shell, and loop isolation

*From `plans/mcp-servers.md` (deleted 2026-10-15). It was deferred on 2026-10-12 because
its gptel half only helps gptel, and that half stays parked. What remains is what
Phase 10 needs: one declared list of MCP servers that reaches interactive agent-shell
sessions and **never** reaches claude-loop shells.*

**Why at all, given `~/.claude.json`.** Claude Code already loads its own MCP servers
from `~/.claude.json`, for every session, the loop's included. This list is for servers
that must reach *only* interactive agent-shell sessions (Phase 10's Emacs server, and
optionally an org-roam server). It is also for servers whose arguments come from Emacs
state, such as `org-roam-directory`.

**Design.**
- `rata-mcp-servers` in a new `lisp/init-mcp.el`, a list of plists in the
  `rata-llm-providers` pattern (D-022): `:name`, either `:command`/`:args`/`:env` (stdio)
  or `:url` (+ `:type` http/sse), and `:targets` (for now only `agent-shell`; `gptel` is
  reserved for the parked half).
- Pure functions: `rata-mcp-acp-spec` (entry → `agent-shell-mcp-servers` alist,
  `((name . …) (command . …) (args . …) (env . []))`) and `rata-mcp-server-problems`
  (entry → list of faults). A malformed entry raises a `display-warning` at load naming the entry,
  so `just batch-strict` fails.
- `agent-shell-mcp-servers` set at top level from the agent-shell-targeted entries. Nothing
  is required or spawned at startup; agent-shell starts servers with the session.
- Per-machine servers go in `local.el` with a commented line in `local.el.example`.
  **No tokens in either file.** A server that needs a secret gets an env value that is a
  lambda over `rata-auth-get`; agent-shell evaluates lambdas at session start. **Check
  that in-session.**
- First server, to prove the pipe: `mcp-server-time` via `uvx`. It needs no credentials,
  is read-only and gives an answer you can check easily. **Operator decision
  2026-10-15: `time` is the first server.** Org-roam can follow as a second entry (see
  *Not code* below).
- The old 17-line `init-mcp.el` is **replaced, not repaired**: its keys sit in a dead
  deferred `:config` and bind commands that do not exist. Uncomment its load line in
  `init.el` (right after `init-llm`, before `init-claude-loop`), and drop it from the
  orphan allowlist in `tests/run-tests.el` (~line 157).

**Loop isolation (CRITICAL — needs explicit operator approval for this change).**
Setting the global `agent-shell-mcp-servers` leaks into loop shells. `agent-shell--mcp-servers`
reads the agent config's `:mcp-servers` or falls back to the global. `session/new` runs
after the async handshake, so a `let` around `agent-shell--start` does not cover it.
Fix in `lisp/init-claude-loop-acp.el`: `(setq-local agent-shell-mcp-servers nil)` in the
loop shell, next to the existing `setq-local agent-shell-cwd-function`. That variable has
the same timing problem and gets the same fix. The CLI backend (`claude -p`) is
unaffected, because Emacs never passes it MCP config. **The global must not be set before this
fix lands**, so the isolation is the first half of the phase.

**Tests.**
- `rata-test-mcp-acp-spec` on a stdio and an http fixture.
- `rata-test-mcp-server-problems`: missing name, both `:command` and `:url`, unknown target.
- `rata-test-mcp-loads-without-agent-shell`: the module loads, nothing is spawned.
- A new case in `tests/claude-loop-acp-e2e.el`: with `agent-shell-mcp-servers` globally
  non-nil, the loop's `session/new`, as logged by `tests/fake-claude-acp`, carries an
  empty `mcpServers`. This asserts on the wire, not on a variable.
- Run `just test` and `just test-claude-loop-acp`.

**Manual check (operator, GUI).** `SPC a i s c` → ask Claude "what time is it in Tokyo?"
→ the `time` tool call shows in the shell. A claude-loop run shows no such tool.

**Remaining approval.** The loop-isolation change in `init-claude-loop-acp.el` is
CRITICAL and still needs your explicit go-ahead when the phase starts; agreeing to this
plan does not count as that approval.

---

## Phase 10: Emacs as an MCP server — read tools, then orchestration

*H2 (absorbs C10).* A lead Claude can ask Emacs what you can see, then list, read, wait
for, start and message other agents. Largest item, HIGH tier (exposes Emacs state to an
external process). The decisions below are taken. The phase still opens with a short
design spike: read `mcp-server-lib`'s source to confirm its stdio launcher, and record
what it found under this heading. Its server registers as a `rata-mcp-servers` entry with
`:targets (agent-shell)`, in the Phase 9 module, so loop shells never see it.

**Tool allowlist** (a test asserts equality, so adding one is a visible diff):

| Tool | Kind |
|---|---|
| `diagnostics(file\|project)`, `xref_definitions` / `xref_references(symbol)`, `buffers_project()`, `buffer_tail(name, lines)` | read |
| `agents_list`, `agent_read(id, lines)`, `agent_wait(id, states, timeout_s)` | read |
| `agent_spawn(task, prompt, worktree?)`, `agent_send(id, prompt)` | **spend** |

No tool evaluates elisp, writes a buffer, or answers another agent's permission prompt.
`buffer_tail` refuses buffers outside the project and internal ones.

**Safety.** `rata-agent-api-max-children` (3), `rata-agent-api-spawn-confirm` (t);
helpers start in the default permission mode; children shown nested under their lead.
Loop shells never see the server. Phase 9's isolation and its e2e case cover this; this
phase adds an assertion that the Emacs server is absent from the loop's `session/new`.

**Operator decisions 2026-10-15.**
1. **Transport: MCP via `mcp-server-lib`**, registered through `agent-shell-mcp-servers`
   for interactive shells only. Not a `bin/rata-agent` CLI over `emacsclient`: that needs
   a shell-command permission, which is one `--eval` away from arbitrary Elisp. The
   spike confirms whether the library's stdio launcher reaches Emacs through
   `emacsclient`. **That is expected and fine**: the operator runs Emacs as a server and
   uses `emacsclient` daily, so the socket is already there. If the server is not
   running, the MCP server is unavailable with one warning, and agent-shell still starts.
   The agent is still limited to the registered tools, but any agent with unrestricted
   Bash can reach Emacs regardless. The real boundary is the agent's Bash permission,
   and this transport does not widen it.
2. **Spawn confirmation on** (`rata-agent-api-spawn-confirm` t), with the cap of 3
   concurrent helpers per lead. The setting can be relaxed later.
3. **A lead talks only to its own helpers.** `agent_send` refuses shells the lead did not
   spawn. **Reads are scoped the same way:** `agents_list` and `agent_read`/`agent_wait`
   see only the lead's own helpers. A home lead never reads a work shell, and output from
   an unrelated session is never forwarded.
4. **A helper's worktree is based on the lead's current branch**, not the default branch.
   Phase 7's default-branch rule is for worktrees *you* start. A helper builds on the
   lead's work, and its recorded `rataAgentBase` is the lead's branch, so finishing it
   checks "merged into the lead". Work flows helper → lead → default branch.
   `rata-agent-worktree-create` therefore takes an explicit BASE, and
   `rata-agent-worktree-base` applies only to the interactive commands. A helper starts
   from the lead's last **commit**, so `agent_spawn` with a worktree **refuses while the
   lead's worktree has uncommitted changes**. Its tool result tells the lead to commit
   first, because a silent spawn would hand the helper stale code. A lead that is not in
   a git branch (detached HEAD, or no repository) is refused with the reason.

**Sub-phases** (each closes separately, as `10.1 [done]` lines under this heading):
10.1 read-only tools → 10.2 `agents_list/read/wait` → 10.3 `spawn/send` with caps →
10.4 panel nesting.
**Tests.**
- Each tool is a pure formatter over fixture state.
- Allowlist equality.
- Caps and confirmation, with the spawner stubbed.
- Scoping: a lead's `agents_list`, `agent_read` and `agent_send` refuse or omit a shell it
  did not spawn.
- Helper base, in temp repos: a helper of a lead on `agent/x` is cut from `agent/x` and
  records it as its base, even with `rata-agent-worktree-base` set to `default`. A dirty
  lead worktree is refused with the "commit first" result.
- Loop-shell exclusion.
- Real transport and client: NOT TESTED.

---

## Not code — operator setup

- **org-roam MCP for Claude (Pillars Phase 1).** Claude Code already gets MCP servers from
  `~/.claude.json`, so giving agents read access to the roam DB can be a config entry
  there, with no Elisp. Verify the server package first (name, maintenance, whether it is
  read-only); the pillars plan named `uvx org-roam-mcp` without checking. If it should
  reach only interactive agent-shell sessions, and not the claude-loop or plain `claude`,
  make it a `rata-mcp-servers` entry after Phase 9 instead, with the roam path derived
  from `org-roam-directory`.

## Parked (not scheduled; reasons recorded so they are not re-proposed blindly)

| Item | From | Why parked |
|---|---|---|
| `.ratarules` hierarchical rules | Pillars §4 / Phase 3 | Every agent here is Claude Code (agent-shell, claude-loop), which already reads `CLAUDE.md`/`AGENTS.md` hierarchically. A second rules format would duplicate it. |
| Personas / modes table | Pillars §3 | agent-shell exposes session mode and model under `,` already; Claude Code subagents cover role prompts. Revisit only for gptel. |
| Tree-sitter repo map, `{{repomap}}` | Pillars §2 / Phase 5 | Claude Code explores with grep/read on demand; aider ships its own repo map. Real cost (5 languages of queries), unclear gain. |
| Ambient semantic sidebar | Pillars §6 / Phase 4 | Low gain for the cost (embedding index, async queries, debounce). Khoj is unused and due to be removed, so it would need Ollama embeddings (`nomic-embed-text` via `rata-llm-providers`). Its proposed key `SPC o r s` is taken by `consult-org-roam-search`. |
| Elfeed/HN → literature note | Pillars §7 | Not agent work, and had no phase. Fits `init-elfeed-hn.el` as its own small plan. |
| mcp.el for gptel (`mcp-hub`, `gptel-mcp-connect`, `SPC a i m` keys) | `plans/mcp-servers.md` | Deferred 2026-10-12: the agent work happens in agent-shell, and mcp.el only benefits gptel. If revived, add a `rata-mcp-hub-spec` beside Phase 9's ACP spec, and set `mcp-hub-servers` in `with-eval-after-load 'mcp-hub` (multi-file package, FAIL-0016). ellama and pi-acp were out of scope there too. |
| A3 cost/context columns · D13 claude-loop Phase 3 (CRITICAL) · D14 trim `SPC a i` (after this plan settles the key set) · D15 layout badges · claude-loop runs as panel rows · remote thin client · desktop notifications on by default | survey / herdr | Not chosen. |
