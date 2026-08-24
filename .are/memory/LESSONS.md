# Lessons

Patterns that generalise beyond the single failure that produced them. Each is written so a
future session can apply it without opening the failure record.

Add a lesson only when it changes what someone would *do*. A lesson that restates a failure
is not a lesson.

---

## L-001 — Keybindings in a deferred `use-package :config` block are dead code

**From:** the `init-org.el` `:init` bug (fixed, `SPEC.md:79`), and the explicit workarounds
in `init-sql.el:87-89` and `init-present.el:25`.

A `:config` block does not run until the package loads. If the binding *is* the entry point
that would cause the package to load, it is never bound, and nothing errors — `which-key`
simply shows nothing under that prefix.

**Apply:** put the leader binding at top level and rely on `:commands`-generated autoloads,
or use `:after general` on a package that is `:demand`ed. Three modules in this repo already
do the former; copy them. Recorded as invariant I2 in
[../knowledge/ARCHITECTURE.md](../knowledge/ARCHITECTURE.md).

## L-002 — A package that warns instead of signalling is invisible to `rata-load-module`

**From:** [FAIL-0002](failures/FAIL-0002.md).

`rata-load-module`'s `condition-case` catches *signals*. A package that calls
`display-warning`, `message` or `lwarn` and carries on produces no signal, so
`rata--failed-modules` stays empty and `rata-test-no-failed-modules` passes while the feature
is broken.

**Apply:** treat warning lines in `just test-ert` / `just batch` output as findings, not
noise. When one turns out to be real, assert the underlying *state* (does this directory
exist? is this variable non-nil?) rather than trying to assert on the warning text.

## L-003 — A green check whose scope is not stated will be over-read

**From:** [FAIL-0003](failures/FAIL-0003.md).

`just compile` prints "All files compiled successfully" while emitting 130 `Cannot load`
lines, because it compiles with no packages on `load-path`. The output is honest; the
summary line is what misleads.

**Apply:** when a check's scope is narrower than its name, say so *at the point the result is
printed* — not only in documentation. `scripts/are-verify.sh` annotates every step for this
reason. And never upgrade a claim when reporting: `compile` PASS means "parses", not
"correct".

## L-004 — Cost and criticality are independent; do not infer either from the other

**From:** [FAIL-0004](failures/FAIL-0004.md).

The claude-loop e2e suite *looks* expensive — it spawns processes and arms timers — so it was
kept out of the gate. Measured, it is the cheapest check in the repo (3.0 s, no packages
needed) and it is the only one covering the only CRITICAL area.

**Apply:** measure before excluding a test on cost grounds, and re-measure when the suite
changes. It is legitimate for the *fast* verification level to cover the *most critical*
area; that is not an inconsistency.

## L-005 — Verify the gate, not just the tests

**From:** [FAIL-0005](failures/FAIL-0005.md).

`core.hooksPath` is per-clone local config that cannot be committed, so a repo shipping
`.githooks/` starts with them **disabled in every checkout, forever**, until someone runs the
install step. With no CI, that meant zero automated checks had ever run on any commit — while
`just test` passed cleanly the whole time.

**Apply:** "the tests pass" and "something runs the tests" are separate claims needing
separate evidence. Check the gate's *installed state*, and report it. Generalises to any
opt-in enforcement: git hooks, editor hooks, CI that only runs on some branches.

## L-006 — When a linter enforces N-1 of an N-step procedure, the unenforced step rots

**From:** [FAIL-0006](failures/FAIL-0006.md).

Adding a module has four documented steps. `scripts/lint.sh` enforced the lexical-binding
header and the `provide` form; nothing enforced "add the `rata-load-module` line". An
unwired module binds nothing, loads nothing, errors nothing — and still passes every check,
including the keybinding tests, which read binding forms *statically* from the file and so
would validate a module that never loads.

**Apply:** when you find a documented multi-step procedure, count which steps have automated
enforcement. The gap is where the rot is. Also: a static check on a file proves nothing about
whether that file is used.

## L-007 — `.gitignore` protects against clutter you predicted, nothing else

**From:** [FAIL-0007](failures/FAIL-0007.md).

`no-littering` plus a thorough `.gitignore` handle *generated* artifacts completely. A
hand-made stray file — a shell typo, a scratch note, a mistyped redirect — is covered by
neither, and `git add .` will happily commit it.

**Apply:** check `git status --porcelain` for unexpected untracked paths before any commit.
`are-audit` warns about them now.

## L-008 — Anchor a "is X referenced?" grep to line start, or comments count as references

**From:** writing the check in [FAIL-0006](failures/FAIL-0006.md).

A first attempt used `grep -q "rata-load-module 'init-mcp)"` and reported zero orphaned
modules — because it matched the *commented-out* load line. The bug was in the check, and it
made the repository look healthier than it was.

**Apply:** any "is this wired up?" search must exclude comments, in this codebase by
anchoring with `^\(`. More generally: a check that can only ever report "fine" should be
distrusted until you have watched it report "not fine" at least once. Deliberately break the
thing, confirm the check fails, then fix it.

## L-011 — "the binding is well-formed" is not "the key works"

**From:** [FAIL-0009](failures/FAIL-0009.md).

Two tests guarded keybindings in this repo. Both parsed the *source* of every `rata-leader`
form: one rejected anonymous lambdas, one required `(commandp sym t)`. A key bound inside a
deferred `use-package` `:config` passes both and is still undefined in the running editor,
because `:config` does not run until the package loads. The `commandp` test even documented
the autoload tolerance that makes it blind here. Meanwhile the projectile keys worked only
because an unrelated module set `dashboard-projects-backend` to `projectile` and pulled the
package in — the config had no idea its keybindings depended on that.

**Apply:** for anything user-facing, assert the *end state in a live process*, not the
well-formedness of the source that is supposed to produce it. Here that is one line —
`(lookup-key (evil-get-auxiliary-keymap general-override-mode-map 'normal) (kbd "SPC p f"))`
— and `tests/run-tests.el` already runs against a fully initialised Emacs, so the capability
was there all along and unused. Corollary for this codebase: a `rata-leader` call belongs at
top level in `(with-eval-after-load 'general …)`, never in a deferred `:config`, unless the
binding is genuinely `:keymaps`-scoped to a mode whose activation loads the package.

## L-010 — When a target delegates, check the thing that does the work, not the thing that names it

**From:** [FAIL-0008](failures/FAIL-0008.md) §2.

An audit check asserted "every `test-*` target is reachable from a gate" by grepping the
`are-verify` recipe in the `justfile`. That recipe is one line — `./scripts/are-verify.sh
{{level}}` — because it delegates. The steps live in the script, so the check could only ever
fail. Delegation moved the evidence and the check did not follow it.

**Apply:** before writing a check, ask *which file will actually contain the fact I am
asserting* after the next refactor, not which file names the concept. Corollary: `just`
recipes, npm scripts and Makefile targets are usually pointers, not content — assert against
what they point at.

## L-009 — `git check-ignore` skips tracked files, which hides live `.gitignore` traps

**From:** auditing whether ARE's own files were committable.

`git check-ignore AGENTS.md` exits 1 (no match) even though `.gitignore:23` lists
`AGENTS.md`, because git does not report ignore status for already-tracked paths. The rule is
dead for `AGENTS.md` but very much alive for anything new with a matching name — and
`CONVENTIONS.md` and `docs/*` are ignored right now.

**Apply:** always use `git check-ignore -v --no-index <path>` when asking "will this new file
be committable?". `are-audit` does this for everything ARE creates.

## L-012 — A per-unit cap does not bound a loop that runs the unit many times

**From:** adding `rata-claude-loop-run-budget-usd`, 2026-08-20.

`init-claude-loop.el` passed `--max-budget-usd` per `claude -p` invocation and called that
the spend guard. With two attempts per task and a fifty-task runaway limit, an operator who
set it to $2 had authorised $200. Every individual invocation obeyed the cap; the run had no
cap at all. The same shape holds for a per-request timeout in a retry loop, a per-file size
limit in a batch job, and a per-attempt turn limit.

**Apply:** when a limit is expressed per unit of work and the code runs that unit in a loop,
either add a limit at the loop's scale or write down why the product of the two is
acceptable. Check the aggregate where the loop decides to continue — `rata-claude-loop--advance`
checks the budget *between* tasks, never mid-task, because the work in flight is already paid
for and abandoning it wastes the spend rather than saving it.

## L-013 — A gate that was never green cannot report that something turned it red

**From:** adding `rata-claude-loop-verify-baseline`, 2026-08-20.

The loop ran its verify command after each task and treated a non-zero exit as that task's
failure. Against a tree whose suite was already failing, every task would have failed, each
would have burned its retries being told to fix a break it inherited, and the retry prompt
would have handed it someone else's stack trace as evidence. The check was measuring a state,
not a change, while being read as a change.

**Apply:** before using a check as evidence *about an action*, establish its value before the
action. If the baseline is red, say so and stop — do not attribute it. The same applies to
any before/after comparison this repo grows: a diffstat against a dirty tree, a lint count
against an unlinted file.

## L-014 — A newly added `use-package :ensure` package is not installed when the next test runs

**From:** adding `flycheck-posframe` to `init-dev.el`, 2026-08-24.

Right after adding the package I ran `just are-verify relevant` and it FAILED two ERT tests
(`rata-test-keybindings-all-commandp`, `rata-test-claude-loop-body-org`). The change touched
neither. The real cause: elpaca had not built the new package yet, so loading `init-dev.el`
during the test errored partway and every leader key defined *after* the new block went
undefined — a downstream cascade that looks like unrelated breakage. `git stash` of the one
file made the suite pass again, which wrongly implicated the change itself rather than the
install state. elpaca's clone is async and `just batch` exits before it finishes; a bare
`just batch` did not complete the clone either, and left a half-cloned `elpaca/sources/<pkg>`
(a `.git` with no checked-out files) that then blocked retries.

**Apply:** after adding any `use-package` with `:ensure` (implicit here via
`use-package-always-ensure t`), install it *before* verifying:
`emacs --init-directory <dir> --batch -l early-init.el -l init.el --eval "(progn (elpaca-wait) (elpaca-process-queues) (elpaca-wait))"`,
then confirm `elpaca/builds/<pkg>` exists. If an earlier interrupted run left a source dir
with only `.git`, `rm -rf elpaca/{sources,builds}/<pkg>` and re-run — this is targeted, not
`just clean`. Only then does a FAIL in the suite mean anything about the change.

## L-015 — The trailing `elpaca-wait` in init.el is load-bearing for batch/headless runs

**From:** the config-audit session, 2026-08-24, removing the final `(elpaca-wait)` at the
end of `init.el` as a startup-perf win (it forced every package to finish loading before
`emacs-startup-hook`, negating the module `:defer`/`:after` deferral).

Removing it outright made `just test-ert` fail `rata-test-keybindings-all-commandp` with a
huge list of "not a command" symbols spanning modules the change never touched
(`init-python`, `init-rust`, `init-sql`, ...). The cause was not the keybinding sweep also
in flight: interactively, elpaca's queue drains on the idle loop via `after-init-hook`, but
in `emacs --batch` there is no idle loop, so nothing gets installed or autoloaded before the
process inspects the environment and exits. The trailing `elpaca-wait` was the only thing
draining the queue in headless mode; without it, every deferred-package command symbol is
unbound at test time.

The fix keeps both properties: `(when noninteractive (elpaca-wait))` — interactive startup
stays deferred (fast), batch/CI still gets a fully-drained queue.

**Apply:** an `elpaca-wait` that looks like pure interactive-startup cost may be the only
synchronisation a batch run has. Before deleting one, ask what drains the queue in `--batch`
(nothing does on its own). Gate on `noninteractive` rather than removing. A green
`are-verify` *before* such a change and a red one *after*, on files the change never touched,
is the signature of a lost batch barrier — not a real regression in those files.
