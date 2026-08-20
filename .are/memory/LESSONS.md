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
