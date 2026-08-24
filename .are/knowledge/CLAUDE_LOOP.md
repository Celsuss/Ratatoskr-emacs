# init-claude-loop.el — the only CRITICAL area

Source: `lisp/init-claude-loop.el` (2263 lines), `tests/claude-loop-e2e.el`,
`tests/run-tests.el` §4–7. Confidence: HIGH.

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
| Auto-approves whatever `rata-claude-loop-allowed-tools` lists | `--allowedTools`, `rata-claude-loop--common-args` | commands run unattended; nil by default, and `Bash` (unqualified) here is equivalent to a shell |
| Launches `claude -p` with `--permission-mode acceptEdits` | `rata-claude-loop-extra-args`, `:47` | file edits are auto-approved inside the resolved project root |
| Runs an operator-supplied shell string | `rata-claude-loop--start-verify`, `:1788` — `make-process` with `shell-file-name shell-command-switch command` | arbitrary shell, by design; whatever `rata-claude-loop-verify-command` says |
| Ticks checkboxes in a file and saves it | `rata-claude-loop--mark-task`, `:929` | mutates the operator's task file, calls `save-buffer` and `org-todo` |
| Loops unattended over up to 50 tasks | `rata-claude-loop-max-tasks`, `:393` | unattended spend and unattended edits |
| Spends metered API budget | `rata-claude-loop-task-budget-usd` (per attempt) and `rata-claude-loop-run-budget-usd` `:111` (per run); both nil = unbounded | the only "financial" surface in this repo |
| Writes a journal outside the project | `rata-claude-loop-journal-directory`, `:403` | task text and session ids land under `user-emacs-directory` |

Any change here is `full`-verified and, if it touches the safety guards below, needs
operator approval before it lands. See [../rules/SAFETY_RULES.md](../rules/SAFETY_RULES.md).

## 2. Safety guards that must not be weakened

These are load-bearing. Removing any one converts a bounded tool into an unbounded one.
Each is named with the test that protects it, where one exists.

| Guard | Implementation | Protected by |
|---|---|---|
| **`$HOME` can never become the project root.** A dotfiles repo or stray marker in `$HOME` would otherwise scope the agent to the entire home directory | `rata-claude-loop--project-root`, `:714` — rejects a marker at or above `~` | `rata-test-claude-loop-project-root-refuses-home` |
| **Never tick a box that is not unambiguously the finished task.** Ambiguous or missing → halt | `rata-claude-loop--find-task-line`, `:878` | `rata-test-claude-loop-refuses-ambiguous-task`, `rata-test-claude-loop-relocates-shifted-task`, e2e §4 |
| **Success comes from the `result` event, never the exit code.** `claude -p` exits 0 when it gave up and when every edit was denied | `rata-claude-loop--classify`, `:1299`; `rata-claude-loop--critical-denials`, `:1247` | `rata-test-claude-loop-classify`, e2e §2 |
| **The last stdout line must be flushed at EOF** — the CLI does not newline-terminate it, and it carries the result event | `:pending` flush in `rata-claude-loop--consume`, `:1171` | `rata-test-claude-loop-consume-split-and-unterminated` |
| **Attempts are bounded** and a retry must be told what broke *and* told not to weaken the test | `rata-claude-loop-max-attempts` `:297`; `rata-claude-loop-retry-prompt-template` `:341` | e2e §3 asserts both the failure text and the "not weaken" clause reach the retry prompt |
| **Stale callbacks cannot act.** One integer covers child, stderr pipe, timeout, kill grace and pending step | `:epoch`, `rata-claude-loop--epoch-current-p`, `:520` | e2e §5 (timeout leaves no process behind) |
| **Timeouts kill, with a grace period, and the verdict survives the kill** | `:outcome` is write-once, `rata-claude-loop--set-outcome`, `:525` | e2e §5 |
| **Git interaction is read-only.** `stash create` writes objects but touches neither the working tree nor the stash list | `rata-claude-loop--git-baseline`, `:1354` | none — asserted by code comment and by `--stat`-only usage |
| **Runaway guard** on task count | `rata-claude-loop-max-tasks`, `:393` | none |
| **Run-level spend cap.** `--max-budget-usd` is per invocation, so retries and a long list multiply past it. Checked between tasks only — the task in flight is already paid for | `rata-claude-loop--budget-spent`, `:542`; the guard in `rata-claude-loop--advance` | `rata-test-claude-loop-budget-spent`, e2e §10 |
| **Skipping a failed task still requires marking its box.** Under `rata-claude-loop-on-task-failure` = `skip`, a box that cannot be located unambiguously halts anyway: an open box is handed straight back as the next task | `rata-claude-loop--skip-failed-task`, `:1737` | `rata-test-claude-loop-failure-action`, e2e §9 |
| **A single-task run always halts on failure**, whatever the policy says | `rata-claude-loop--failure-action`, `:1724` | `rata-test-claude-loop-failure-action`, e2e §9 |
| **A denial is evidence, not noise.** A denied edit means nothing was written (`denied`); a denied command means nothing was *run* (`unverified`). Both fail the attempt; only the first was modelled before FAIL-0010 | `rata-claude-loop--verification-denials`, `:1251`, alongside the older `rata-claude-loop--critical-denials` | `rata-test-claude-loop-classify-unverified`, e2e §14 |
| **A task may not report `done` for work it could not execute.** The prompt demands a run rather than a reading, offers `RATA-TASK-STATUS: unverified` as the honest answer, and the classifier infers `unverified` from a denial regardless of what was claimed | `rata-claude-loop-prompt-template` `:150`, `rata-claude-loop--classify` | `rata-test-claude-loop-prompt-demands-verification`, `rata-test-claude-loop-classify-unverified`, e2e §14 |
| **A verify command that already fails stops the run before any task starts**, and its output is not kept as retry feedback | `rata-claude-loop--after-baseline`, `:1857` | e2e §12 |
| **Journalling can never stop a run.** A write failure disables the journal and reports once | `rata-claude-loop--journal`, `:697` | e2e §13 (happy path only) |

## 3. Test coverage — what is and is not proven

**`tests/claude-loop-e2e.el`** drives the real state machine against a stub CLI, under
`emacs -Q` with no packages and no API calls. ~5 s. 13 scenario groups: happy path,
exit-0 failures, retry-by-resume + exhaustion, wrong-box refusal, timeout, stdout/stderr
noise, duplicate task text, wedge detection, failure containment, run budget, task detail
in the prompt, verify baseline, journalling. Run: `just test-claude-loop`.

**`tests/run-tests.el`** §4–7 covers the pure functions: scanning, marking, stream
decoding, classification, command construction, truncation, task-detail extraction,
budget, failure policy, journal records, summary lines.

**NOT covered by any test:**
- The real `claude` CLI. Every test uses a stub; a change to the CLI's `stream-json`
  schema or flag names would pass all tests and fail in use. In particular **nothing
  verifies that `total_cost_usd` is per invocation rather than cumulative per session**,
  which is the assumption the run budget is built on; if the CLI reports a session total,
  a resumed retry double-counts and the budget halts early (conservative, but wrong).
- `--permission-mode acceptEdits` and `--allowedTools` actually restricting anything —
  that is the CLI's behaviour, not this module's, and it is never exercised. The tests
  assert only that the flags and patterns reach the argv of both the first attempt and
  the resumed retry (`rata-test-claude-loop-allowed-tools-reach-argv`). **Whether a
  given pattern grants what you think it grants is untested here — verify it on a
  throwaway task before an unattended run.**
- Whether `--allowedTools` is genuinely terminated by the next flag. It is variadic, so
  it consumes following non-dash arguments; the ordering in `rata-claude-loop--common-args`
  relies on every element of `rata-claude-loop-extra-args` being a flag or a flag's
  value. The test asserts the ordering, not the CLI's parse.
- `rata-claude-loop-git-checkpoint 'record` (the `stash create` path).
- The interactive commands (`-start`, `-stop`, `-resume`, `-retry-task`, `-skip`,
  `-open-session`, `-status`) as *interactive* entry points; the e2e suite calls
  `--begin`/`--run-task` directly.
- Anything about `evil` keybindings in `rata-claude-loop-mode-map` — the e2e suite runs
  `-Q`, so `evil` is absent there, and `run-tests.el` checks `rata-leader` bindings but not
  the buffer-local `evil-define-key*` ones.

## 4. Operating it safely

- **Set `rata-claude-loop-allowed-tools` per project, or accept that no task can test
  itself.** With it nil the agent cannot run a command, and a task instructed to verify
  its work will report `done` off a reading of its own diff (FAIL-0010). Grant the
  narrowest thing that runs the project's gate — `Bash(just:*)`, `Bash(pytest:*)` — and
  read the `allow with:` line the buffer prints beside a denial rather than guessing.
  Bare `Bash` is a shell, and this loop runs unattended.
- `rata-claude-loop-verify-command` is arbitrary shell that runs unattended. Set it per
  project, never to something destructive, and never to something that could pass while the
  work is wrong.
- Set `rata-claude-loop-task-budget-usd` **and** `rata-claude-loop-run-budget-usd` before
  an unattended run. Both default to `nil`, i.e. unbounded, and the per-attempt cap alone
  bounds nothing at run scale.
- For an unattended run set `rata-claude-loop-on-task-failure` to `skip`, so one
  impossible task degrades the run to a report instead of stopping it. Read the run
  summary at the end of the loop buffer, and `rata-claude-loop-open-journal` (`SPC a i c l
  j`) for the durable record — it holds the session ids to pick a failed task up by hand.
- Leave `rata-claude-loop-verify-baseline` on. It costs one verify run and is what keeps a
  pre-existing red suite from failing every task in the list.
- The loop is detectable when wedged: `rata-claude-loop--wedged-p` (`:506`) and
  `rata-claude-loop-status`. Prefer those to guessing.
- `rata-claude-loop-stop` cancels timers and kills with a grace period; it also bumps the
  epoch, so in-flight callbacks become no-ops.
