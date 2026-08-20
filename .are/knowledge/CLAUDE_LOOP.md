# init-claude-loop.el — the only CRITICAL area

Source: `lisp/init-claude-loop.el` (1573 lines), `tests/claude-loop-e2e.el`,
`tests/run-tests.el` §4–6. Confidence: HIGH.

`AGENTS.md` already documents this module's design conventions in detail (trampoline
control flow, `:epoch` staleness, `result`-event classification, `--resume` retries,
text-matched checkboxes, `evil-define-key*`). **Read that first; it is accurate.** This
page adds only the reliability view: why it is CRITICAL, what its blast radius is, and
what is and is not covered by tests.

---

## 1. Why CRITICAL

It is the one place in this repository that **writes to the operator's other repositories
without a human in the loop**:

| Capability | Where | Consequence |
|---|---|---|
| Launches `claude -p` with `--permission-mode acceptEdits` | `rata-claude-loop-extra-args`, `:47` | file edits are auto-approved inside the resolved project root |
| Runs an operator-supplied shell string | `rata-claude-loop--start-verify`, `:1208-1211` — `make-process` with `shell-file-name shell-command-switch command` | arbitrary shell, by design; whatever `rata-claude-loop-verify-command` says |
| Ticks checkboxes in a file and saves it | `rata-claude-loop--mark-task`, `:602` | mutates the operator's task file, calls `save-buffer` and `org-todo` |
| Loops unattended over up to 50 tasks | `rata-claude-loop-max-tasks`, `:249` | unattended spend and unattended edits |
| Spends metered API budget | `rata-claude-loop-task-budget-usd`, `:73` (nil = unbounded) | the only "financial" surface in this repo |

Any change here is `full`-verified and, if it touches the safety guards below, needs
operator approval before it lands. See [../rules/SAFETY_RULES.md](../rules/SAFETY_RULES.md).

## 2. Safety guards that must not be weakened

These are load-bearing. Removing any one converts a bounded tool into an unbounded one.
Each is named with the test that protects it, where one exists.

| Guard | Implementation | Protected by |
|---|---|---|
| **`$HOME` can never become the project root.** A dotfiles repo or stray marker in `$HOME` would otherwise scope the agent to the entire home directory | `rata-claude-loop--project-root`, `:468` — rejects a marker at or above `~` | `rata-test-claude-loop-project-root-refuses-home` |
| **Never tick a box that is not unambiguously the finished task.** Ambiguous or missing → halt | `rata-claude-loop--find-task-line`, `:551` | `rata-test-claude-loop-refuses-ambiguous-task`, `rata-test-claude-loop-relocates-shifted-task`, e2e §4 |
| **Success comes from the `result` event, never the exit code.** `claude -p` exits 0 when it gave up and when every edit was denied | `rata-claude-loop--classify`, `:887`; `rata-claude-loop--critical-denials`, `:876` | `rata-test-claude-loop-classify`, e2e §2 |
| **The last stdout line must be flushed at EOF** — the CLI does not newline-terminate it, and it carries the result event | `:pending` flush in `rata-claude-loop--consume`, `:813` | `rata-test-claude-loop-consume-split-and-unterminated` |
| **Attempts are bounded** and a retry must be told what broke *and* told not to weaken the test | `rata-claude-loop-max-attempts` `:178`; `rata-claude-loop-retry-prompt-template` `:197` | e2e §3 asserts both the failure text and the "not weaken" clause reach the retry prompt |
| **Stale callbacks cannot act.** One integer covers child, stderr pipe, timeout, kill grace and pending step | `:epoch`, `rata-claude-loop--epoch-current-p`, `:357` | e2e §5 (timeout leaves no process behind) |
| **Timeouts kill, with a grace period, and the verdict survives the kill** | `:outcome` is write-once, `rata-claude-loop--set-outcome`, `:362` | e2e §5 |
| **Git interaction is read-only.** `stash create` writes objects but touches neither the working tree nor the stash list | `rata-claude-loop--git-baseline`, `:933` | none — asserted by code comment and by `--stat`-only usage |
| **Runaway guard** on task count | `rata-claude-loop-max-tasks`, `:249` | none |

## 3. Test coverage — what is and is not proven

**`tests/claude-loop-e2e.el`** drives the real state machine against a stub CLI, under
`emacs -Q` with no packages and no API calls. 3 s. 9 scenario groups: happy path, exit-0
failures, retry-by-resume + exhaustion, wrong-box refusal, timeout, stdout/stderr noise,
duplicate task text, wedge detection. Run: `just test-claude-loop`.

**`tests/run-tests.el`** §4–6 covers the pure functions: scanning, marking, stream
decoding, classification, command construction, truncation.

**NOT covered by any test:**
- The real `claude` CLI. Every test uses a stub; a change to the CLI's `stream-json`
  schema or flag names would pass all tests and fail in use.
- `--permission-mode acceptEdits` actually restricting anything — that is the CLI's
  behaviour, not this module's, and it is never exercised.
- `rata-claude-loop-git-checkpoint 'record` (the `stash create` path).
- The interactive commands (`-start`, `-stop`, `-resume`, `-retry-task`, `-skip`,
  `-open-session`, `-status`) as *interactive* entry points; the e2e suite calls
  `--begin`/`--run-task` directly.
- Anything about `evil` keybindings in `rata-claude-loop-mode-map` — the e2e suite runs
  `-Q`, so `evil` is absent there, and `run-tests.el` checks `rata-leader` bindings but not
  the buffer-local `evil-define-key*` ones.

## 4. Operating it safely

- `rata-claude-loop-verify-command` is arbitrary shell that runs unattended. Set it per
  project, never to something destructive, and never to something that could pass while the
  work is wrong.
- Set `rata-claude-loop-task-budget-usd` before an unattended run. Default `nil` is
  unbounded.
- The loop is detectable when wedged: `rata-claude-loop--wedged-p` (`:343`) and
  `rata-claude-loop-status`. Prefer those to guessing.
- `rata-claude-loop-stop` cancels timers and kills with a grace period; it also bumps the
  epoch, so in-flight callbacks become no-ops.
