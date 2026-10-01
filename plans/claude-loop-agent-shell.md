# claude-loop over agent-shell (ACP) — plan

Status: **proposed, awaiting operator approval** (2026-10-01). Nothing is implemented.
Risk tier: **CRITICAL** (`lisp/init-claude-loop.el`). Requires `just are-verify full`,
a new `tests/claude-loop-e2e.el` case, and operator approval per phase.

## 1. Question

Can `rata-claude-loop` drive Claude Code through agent-shell (ACP, via
`claude-agent-acp`) instead of spawning `claude -p --output-format stream-json`?

**Answer: yes.** Everything the loop needs has a public, documented hook in the
installed versions (agent-shell `4aa030e`, claude-agent-acp `0.73.0`):

| Loop needs | headless CLI today | agent-shell / ACP equivalent |
|---|---|---|
| start a session in the project root | `make-process` with `default-directory` | `agent-shell-start :config CONFIG` (programmatic, returns the buffer); cwd from `default-directory` |
| send the task prompt | `-p PROMPT` | `agent-shell-insert :text PROMPT :submit t :no-focus t :shell-buffer BUF` |
| know the attempt ended | process sentinel + `result` event | `turn-complete` event, `:data` has `:stop-reason` (`end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`) and `:usage` |
| the agent's final text (for `RATA-TASK-STATUS:`) | `result.result` | accumulate `agent-message-chunk` `:text-chunk` per turn |
| tool calls / denials | `permission_denials` in `result` | `tool-call-update` events + **`agent-shell-permission-responder-function`**, which sees every permission request and answers it programmatically |
| `--permission-mode acceptEdits` | flag | `agent-shell-anthropic-default-session-mode-id` / `:default-session-mode-id` in the config (`acceptEdits` is an advertised mode) |
| `--allowedTools`, `--max-turns`, `--max-budget-usd`, `--model`, `--append-system-prompt` | flags | `:session-meta` → `_meta.claudeCode.options`, which the adapter **spreads verbatim into the Agent SDK `Options`** (`acp-agent.js:5313`). `allowedTools`, `maxTurns`, `maxBudgetUsd`, `model`, `fallbackModel` pass straight through; `systemPrompt`/`permissionMode`/`cwd` are overridden by the adapter |
| retry by `--resume SESSION` | new process, all flags re-passed | **send another prompt into the same live session** — no resume, no flag re-passing; `agent-shell-resume-session` only for a session whose shell was killed |
| cost | `result.total_cost_usd` | `usage_update` → `:usage :cost-amount`, which is `result.total_cost_usd` from the SDK |
| timeout / stop | kill process with grace | `agent-shell-interrupt` (sends `session/cancel` → `cancelled` stop reason), then `kill-buffer` as the hard kill |
| errors | exit code, stderr | `error` event (`:code`, `:message`), `clean-up` event when the shell dies |

## 2. What this buys, and what it costs

**Gains**

1. **Each task is a real, watchable, takeover-able shell.** The operator can open the
   task's agent-shell mid-run, read it in the normal UI, and — on a failed or blocked task
   — keep typing into the *same* session instead of `claude --resume` in a terminal.
2. **Permission requests stop being silent.** Print mode denies an un-allowed tool
   without asking (the root of FAIL-0010). Over ACP every such request reaches our
   responder, which can deny-and-record (unattended, today's semantics, but now the
   denial is observed the moment it happens rather than read from the `result` event),
   or — new — **hand it to the operator**: the shell's permission dialog opens and the
   `*Agents*` panel (`init-agent-center.el`) already shows it as `needs-input` and counts
   it in the mode line. That is the "ask" policy the CLI could never offer.
3. **Free integration with the `*Agents*` panel**: loop shells are ordinary agent-shell
   buffers, so they appear under their layout with state, and `SPC a i n` jumps to one
   that needs you.
4. **Retries get simpler**: no `--resume`, no `rata-claude-loop--common-args`
   re-passing problem, no variadic `--allowedTools` parse hazard.

**Costs / risks**

1. **Dependency on a large, fast-moving package** (agent-shell is 10k lines; FAIL-0019
   was already a vintage skew between checkouts). The loop today depends on nothing but
   the `claude` binary. → Keep the CLI backend as the default and the fallback; the ACP
   backend is opt-in.
2. **The success signal is weaker.** `stream-json`'s `result` has `subtype`
   (`error_max_turns`, `error_during_execution`, `error_max_budget_usd`…), `is_error`,
   `permission_denials`. ACP gives a `stopReason` and an `error` event. The classifier
   (§2 "success comes from the result event") must be rebuilt on a normalised attempt
   record, and every exit-0-but-failed case the CLI suite tests needs an ACP analogue.
3. **Cost is probably cumulative per session.** `total_cost_usd` is the SDK `query()`
   running total, and an ACP session keeps one `query()` alive across turns — so retries
   in the same session would double-count if added naively. The backend must record the
   *delta* since the turn started. This needs measuring on a real throwaway task (Phase 0).
4. **`agent-shell-permission-responder-function` is one global variable**, called with
   the tool call but **not the shell buffer**. A loop that sets it must not change the
   behaviour of the operator's interactive shells. → A single dispatcher that answers only
   for tool-call ids/buffers the loop owns and returns nil (fall back to the UI) for
   everything else; which buffer is current at call time is to be confirmed in Phase 0.
5. **The e2e suite runs under `emacs -Q` with no packages.** An ACP backend test needs
   agent-shell, shell-maker and acp on `load-path` and a stub ACP agent. upstream's
   `mock-acp` is a Swift binary cycling fixed patterns — not usable. → write our own
   small stub ACP server (scripted JSON-RPC over stdio), in the same spirit as the
   existing `fake-claude` stub.
6. **Interactive config leaks in.** `agent-shell-start` honours the operator's agent-shell
   customisations (session restore strategy, viewport preference, welcome text, idle
   timers). The backend must build its own config (copy of
   `agent-shell-anthropic-make-claude-code-config` with its own `:session-meta` and mode)
   and bind the few defcustoms that would otherwise prompt (session selection must be
   "new", never "pick a session").

## 3. Design

### 3.1 A backend seam, not a rewrite

`rata-claude-loop-backend` — `cli` (default, today's code path unchanged) or
`agent-shell`. The state machine, trampoline, epoch, checkbox marking, verify, baseline,
budget, journal and failure policy are backend-independent and stay as they are.

The seam is three operations and one record:

- `start-attempt (prompt first-p)` — spawn/prompt; arm the timeout.
- `stop-attempt (hard-p)` — interrupt, then kill after `rata-claude-loop-kill-grace`.
- `teardown` — at task end / run end (kill the shell buffer unless kept, see 3.4).
- The backend reports completion by storing a **normalised attempt record** and calling
  the existing `rata-claude-loop--later` → `--after-claude` path:
  `(:ended normal|error|crashed :stop-reason … :subtype … :is-error … :text … :session-id …
  :cost-delta … :denials (…) :exit-code …)`.

`rata-claude-loop--classify` is refactored to read that record instead of `:result` +
exit code. The CLI backend fills it from the `result` event exactly as today (pure
refactor, guarded by the existing tests passing unchanged); the ACP backend fills it from
events. Mapping for ACP:

| ACP signal | normalised |
|---|---|
| `turn-complete`, `end_turn` | `:ended normal`, subtype `success` |
| `max_turn_requests` | subtype `error_max_turns` → kind as today |
| `max_tokens`, `refusal` | `is-error`, kind `error` with the reason named |
| `cancelled` caused by our timeout | the write-once `:outcome` already wins |
| `cancelled` not caused by us | kind `crash` "interrupted" |
| `error` event during the turn | `is-error`, message from the event |
| `clean-up` / shell buffer killed mid-turn | `crashed`, `no-result` |
| responder denied an edit tool | `:denials` → kind `denied` (as today) |
| responder denied a `Bash` | `:denials` → kind `unverified` (as today, FAIL-0010) |

### 3.2 Where the code lives

New file `lisp/init-claude-loop-acp.el`, loaded right after `init-claude-loop` in
`init.el`. It owns the ACP backend and nothing else. **It never requires agent-shell at
load** — like `init-agent-center.el`, it checks `featurep`/`locate-library` at run start
and halts with a clear message if agent-shell or `claude-agent-acp` is missing (L-052:
`fboundp` on an autoload would load it). All agent-shell symbols via `declare-function`.

### 3.3 Permissions — the policy

`rata-claude-loop-acp-permission-policy`:

- `deny` (default; same semantics as the CLI): anything not pre-allowed via
  `allowedTools`/`acceptEdits` is rejected with `reject_once`, recorded as a denial with
  the "allow with: `Bash(…)`" hint the buffer already prints.
- `ask`: leave the dialog to the operator. The task's timeout is **paused** while a
  permission request is open (otherwise a human taking 10 minutes to answer kills the
  task). The `*Agents*` panel surfaces it. Not valid for unattended runs; documented so.

Never `allow` — auto-approving an unlisted tool is exactly the widening
`.are/rules/SAFETY_RULES.md` forbids autonomously. The responder never answers for a
request that is not from a loop-owned shell.

### 3.4 Shell lifecycle

- One shell per **task**; retries are further prompts into the same shell (session).
- The shell is created with `no-focus` and named `Claude loop: <task, truncated>` so the
  agent-center groups it sensibly; the `*claude-loop*` buffer keeps the run summary,
  verify output and a one-line "→ open shell" button per task instead of re-rendering
  every tool call (agent-shell already renders them).
- On task success: kill the shell (configurable `rata-claude-loop-acp-keep-shells`:
  `never` / `failed` (default) / `always`). Kept shells are how the operator takes a
  failed task over by hand; the session id is still journalled.
- `rata-claude-loop-stop` interrupts and kills every loop-owned shell; the epoch bump
  makes any late event handler a no-op (handlers capture the epoch, like sentinels do).
- Event handlers **only record and schedule** through `rata-claude-loop--later` — the
  existing trampoline discipline, and agent-shell demotes a subscriber error to a
  `message`, so a handler that signals would be silently lost.

### 3.5 Config built per run

From the loop's existing defcustoms, so a project's `.dir-locals.el` configures both
backends identically:

```elisp
:default-session-mode-id "acceptEdits"
:session-meta
((claudeCode . ((options . ((allowedTools . ["Bash(just:*)" ...])   ; rata-claude-loop-allowed-tools
                            (maxTurns . 40)                         ; rata-claude-loop-max-turns
                            (maxBudgetUsd . 2.0)                    ; rata-claude-loop-task-budget-usd
                            (model . "..."))))                      ; rata-claude-loop-model
 (systemPrompt . ((append . "..."))))      ; rata-claude-loop-append-system-prompt (Phase 0 Q4)
```

`rata-claude-loop-extra-args` is CLI-only; the ACP backend refuses to start if it holds
anything other than the default `--permission-mode acceptEdits`, rather than silently
dropping it. Pure function `rata-claude-loop-acp--session-meta` builds this and is
unit-tested.

## 4. Phases

Each phase ends at `just are-verify full` green, and stops for operator review.

### Phase 0 — spike, no code in `lisp/` (needs ~1 USD of real API spend, operator-run)
Throwaway repo, a scratch `.el` evaluated by hand, one trivial task. Answer, in writing
in this file:
1. Does `allowedTools` in `_meta.claudeCode.options` actually grant `Bash(just:*)` and
   deny `Bash(rm:*)` — and does a denied tool reach the responder or get denied inside
   the SDK silently? (This decides whether 3.3 `deny` sees denials at all.)
2. Is `:cost-amount` cumulative across two turns in one session? (decides delta logic)
3. Which buffer is current when the responder is called?
4. Does `appendSystemPrompt` survive the adapter's `systemPrompt` override?
5. Which agent-shell defcustoms prompt or focus during `agent-shell-start`
   (session picker, viewport) and need binding?

#### Phase 0 findings (2026-10-01)

From source (agent-shell `4aa030e`, acp.el, claude-agent-acp `0.73.0`), no spend:

- **Q3 — answered.** acp.el runs request handlers inside `with-current-buffer` of the
  client's `:context-buffer` (`acp.el:302`), which `agent-shell-anthropic-make-claude-client`
  sets to the shell buffer. A global responder can therefore dispatch on
  `(current-buffer)` and decline (return nil → normal UI) for any shell the loop does not own.
- **Q4 — answered, plan corrected.** `appendSystemPrompt` in `claudeCode.options` would be
  overridden: the adapter builds `systemPrompt` from **top-level `_meta.systemPrompt`**
  (`acp-agent.js:5188`), accepting `{append: "..."}` and locking the preset. agent-shell
  sends `:session-meta` as the whole `_meta`, so it goes beside `claudeCode`.
- **Q5 — answered.** The public `agent-shell-start` passes `:no-focus nil` (displays the
  buffer), and `agent-shell-session-strategy` defaults to `prompt` (session picker). The
  loop must call the private `agent-shell--start :no-focus t :new-session t
  :session-strategy 'new` — a private-API dependency to pin with a test, the way
  `rata-test-jira-agile-url-passes-through-jira-api` pins jira.el's.
- **Q1 — source says yes, live run must confirm.** A tool not pre-approved by
  `allowedTools`/mode reaches the adapter's `canUseTool`, which sends
  `session/request_permission` to the client (`acp-agent.js:4690`); it does not deny
  inside the SDK. **Safety finding:** the options offered include `allow_always`, a
  *durable* rule the adapter persists into Claude settings. The loop's responder must only
  ever answer `reject_once` (or, under `ask`, leave the choice to the human); never
  pick by position.
- **Q2 — unknowable from source**; needs the live run.
- **Q6 (new)** — cwd comes from `agent-shell-cwd` (`agent-shell-cwd-function`, else
  projectile/project root), not `default-directory` directly. The loop must set it
  buffer-locally or via the function, so the session root is the loop's resolved root
  (and the `$HOME` guard still applies).

Live part: a spike script (kept outside the repo; one temp git repo,
`maxBudgetUsd 0.5`). Claude Code 2.1.286.

**Run 1 (2026-10-01, two turns, $0.29):**
- Startup as designed: no session picker, shell never displayed, cwd = the temp repo,
  mode `acceptEdits`, prompt sent on `prompt-ready`, both turns `end_turn`.
- **Q4 confirmed live:** the `_meta.systemPrompt` append reached the model (marker in both
  replies).
- **Q2 answered: cost is cumulative per session.** Readings 0.278885 → 0.293423; the
  difference (0.0145) is exactly turn 2's own spend (17 output + ~25k cache-read tokens).
  The ACP backend must charge each attempt `cost-at-turn-end − cost-at-turn-start`,
  never the reading itself, or a resumed retry double-counts against the run budget.
- **Q1 not answered — the probe was wrong.** `date` ran with no permission request
  although it is in no allow list: Claude Code auto-approves commands it classifies as
  read-only, before `canUseTool`. Same in `claude -p`.
- **Side finding (applies to the CLI backend too):** the session loads
  `settingSources: user, project, local`, so a loop task's effective grant is
  `allowedTools` ∪ `~/.claude/settings.json` allow list ∪ the target repo's
  `.claude/settings*.json` ∪ Claude Code's built-in read-only set. Not documented in
  `.are/knowledge/CLAUDE_LOOP.md` yet.
- Tool calls go `pending` → `completed` with no `in_progress` in between.

**Run 2 (2026-10-01, one turn, $0.17):**
- **Q1 confirmed live.** `just hello` (in `allowedTools`) ran with no request.
  `python3 -c 'print(6*7)'` reached the responder as a `permission-request` — in the shell
  buffer (Q3 confirmed live) — with `kind "execute"` and `raw-input` carrying the exact
  command. Answered `reject_once`; the tool call went to **`status "failed"`**, the turn
  still ended `end_turn`, and the model reported the refusal honestly. So the ACP backend
  sees denials *as they happen*, with the command string, and the turn's stop reason alone
  would have called it a success — the denial record is what must fail the attempt.
- **Options offered were `allow_once`, `reject_once`, `allow_always`** — no
  `reject_always`, and the reject option's id is `"reject"`, not its kind. The responder
  must select by `:kind`, never by id or position.
- **`acceptEdits` auto-approves `touch`** (and so presumably the other filesystem
  commands Claude Code classes as edits) without a request. Same in `claude -p`.

**Phase 0 closed.** Corrections carried into the phases below: cost is a per-turn delta
(Q2), system prompt goes in top-level `_meta.systemPrompt` (Q4), start through the
private `agent-shell--start` (Q5), cwd set explicitly (Q6), responder answers only
`reject_once` selected by kind and only for loop-owned buffers (Q1/Q3).

### Phase 1 — the seam (CLI backend only; behaviour-preserving refactor)
Normalised attempt record, `classify` reads it, backend dispatch via
`rata-claude-loop-backend` = `cli`. **Every existing test must pass unchanged** — that is
the proof the refactor preserved behaviour. New pure tests for the record.

### Phase 2 — ACP backend, deny policy
`lisp/init-claude-loop-acp.el`: config/meta builder, start/stop/teardown, event→record
mapping, responder dispatcher. New stub ACP agent (`tests/fake-claude-acp`, scripted
JSON-RPC) and a new e2e file `tests/claude-loop-acp-e2e.el` run with agent-shell, acp and
shell-maker on `load-path` from `elpaca/builds/`; scenarios mirroring the CLI suite:
happy path, `max_turn_requests`, error event, shell killed mid-turn, timeout → cancel →
kill, denied edit, denied Bash → unverified, retry in same session, cost delta vs run
budget, stale events after stop. Wire into `scripts/are-verify.sh` (`relevant`, since it
needs packages) and add the path-map rows to `.are/knowledge/MODULES.md`.

### Phase 3 — `ask` policy + operator takeover
Timeout pause while a permission dialog is open; keep-shells policy; "open shell" button
and `rata-claude-loop-open-session` opening the live shell instead of `claude --resume`.
Test: agent-center reports a loop shell with an open request as `needs-input`.

### Phase 4 — docs and memory
`AGENTS.md` claude-loop section, `.are/knowledge/CLAUDE_LOOP.md` (new guard rows, new
NOT-covered list: the real adapter, `allowedTools` semantics), a decision record
(D-0xx: CLI stays default; ACP opt-in; never `allow`), `local.el.example` unaffected.

## 5. Explicitly out of scope

- Removing the CLI backend or changing its default.
- Any auto-`allow` permission policy, or widening `allowedTools` defaults.
- Running tasks in parallel across shells (possible later — agent-shell makes it cheap —
  but it multiplies spend and breaks the single-checklist-cursor model).
- Driving non-Claude ACP agents (Pi etc.) through the loop. The seam would allow it; the
  classifier mapping and `_meta` are Claude-specific.

## 6. Precondition

The working tree has **uncommitted claude-loop work** (heading-task support,
`init-claude-loop.el` +157/−65, tests, docs). Commit or finish that first; Phase 1 is a
refactor of the same file and should start from a clean, green base.
