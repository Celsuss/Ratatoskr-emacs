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

## L-015 — An instruction the agent cannot obey is answered with a fabrication, not a refusal

`rata-claude-loop-prompt-template` said "Verify your work before finishing (run the
project's tests or build if there are any)". `--permission-mode acceptEdits` made running
anything impossible, and print mode denies silently rather than asking. The model did not
stop, and did not report the contradiction as a blocker. It substituted the nearest
achievable act — reading its own diff — and reported `done`. See
[FAIL-0010](failures/FAIL-0010.md).

The generalisation is about where to put the check, not about models:

- **An instruction is only a guard if the environment permits compliance.** Prompt text
  and permission grants are one mechanism with two halves. Changing either half alone
  produces a system that asks for something it forbids, and the gap is filled by
  plausible-sounding prose rather than by an error.
- **Give the honest answer a name.** With only `done` and `blocked` available, "I did the
  work but could not test it" had no encoding, and it rounded to `done` — the failure was
  partly a vocabulary gap. `unverified` costs one regexp alternative.
- **Prefer inferring the fact over asking for it.** The self-report is advisory; a
  `permission_denials` entry is evidence. The denial exists *because* the agent tried the
  call, so it establishes what the agent wanted to do independently of what it later
  claimed. Where both are available, classify on the evidence and use the self-report only
  for wording.
- **A tolerance list is a claim about completeness, and completeness is what tests miss.**
  `rata-claude-loop-critical-denial-tools` was correct about every tool on it. The defect
  was a tool that was not on it, and `should-not` assertions on the tolerant path
  (`a denied WebFetch is tolerated`) read as coverage while certifying the gap. When a
  list decides pass/fail, test the *categories* it is meant to partition, not the entries.

## L-016 — A doc line copied from another repo describes that repo, and nothing notices

`AGENTS.md` opened its navigation section with "Always consult `repomix-output.xml` first".
No such file has ever existed in this repository: `git rev-list --all --objects | grep -i
repomix` is empty in both checkouts. The paragraph arrived in `607c905` (2026-05-04) as a
paste from a Terraform project that does have one — the original wording still said "if you
make significant changes to the **Terraform files**", and that phrase was later edited out,
removing the last evidence that the text was foreign.

- **Instructions are dependencies.** A doc that names a file, a target or a path is
  asserting that it exists. Every other kind of dependency here is checked; prose was not.
- **The tell is the part that no longer fits.** "Terraform files" in an Emacs config was
  the diagnosis, and tidying it away made the drift *harder* to see. When you find a line
  that does not belong, fix the line — do not launder the wording and leave the claim.
- **Check the mechanical half.** `docs-commands` in `scripts/are-audit.sh` now fails if
  `just <target>` in the docs is not a real target. It has to match code context only
  (backtick, org `=verbatim=`, or start of a line) — `\bjust` matched the English "just
  the" in both docs on the first try.
- A silent stale instruction costs every session that obeys it. This one sent each agent
  looking for a file that was never there, and the honest answer — "the pack does not
  exist here" — was not an option the text allowed.

## L-017 — "Does not support Evil" in a package's readme is a keymap-shadowing report

`jira.el`'s readme answers "Does it work with Evil Mode?" with "Not supported currently".
Read literally that sounds like a missing feature, and the tempting fix is to write the
bindings yourself. It is not a missing feature: `jira-issues-mode` derives from
`tabulated-list-mode` and `jira-detail-mode` from `magit-section-mode`, and evil's normal
state shadows both — the same mechanism that made plain `define-key` dead in the
`*claude-loop*` buffer.

- **The diagnosis is in the mode's ancestry, not the readme.** `define-derived-mode X
  tabulated-list-mode` (or any mode absent from evil's state lists) plus single-letter keys
  is sufficient to predict the symptom before installing anything.
- **`evil-set-initial-state` is the cheap fix; re-binding is the expensive one.** Upstream
  ships `?`, `l`, `C`, `U`, `E`, `H`, `S` and adds more on a monthly cadence. A hand-written
  `evil-define-key*` table for them is a promise to track someone else's keymap forever.
  Emacs state costs two lines and never drifts; `C-z` is the way out.
- **This is the third distinct shape of the same root cause** (deferred `:config` leader keys
  in FAIL-0009, `define-key` in a `special-mode` child, an upstream package's own keymap).
  When adding any module whose buffer is not an editing buffer, ask which of the three
  applies before assuming the keys work.

## L-018 — A config value that is *nearly* right fails as though the credential were wrong

`rata-jira-base-url` was set with a trailing slash. jira.el builds its auth-source host by
stripping only the scheme — `(replace-regexp-in-string "https://" "" url)`, `jira-api.el:99`
and `:108` — so the host became `host.example.com/`, no `machine` line in `~/.authinfo.gpg`
matched, `jira-api--token` returned nil, and the request went out with an empty credential.
The observable symptom is a 401. Everything a 401 makes you look at — the token, its expiry,
its scopes, whether SSO blocks basic auth — was fine.

- **One character in a URL and a wrong password are indistinguishable at the failure site.**
  Whenever a lookup key is *derived* from user-entered text, the derivation is a place a
  mistake can hide, and the error surfaces one layer away from its cause.
- **Normalise at the boundary rather than documenting the constraint.**
  `(directory-file-name url)` is a builtin, costs one line, and makes the trailing slash
  permanently harmless. A comment in a template asking the operator to be careful does not.
- **Test the derived value, not the input.** `rata-test-jira-base-url-has-no-trailing-slash`
  recomputes the auth host exactly as jira.el does and asserts no slash survives. Asserting
  on `rata-jira-base-url` alone would have passed while the bug was live.
- **First version of that test skipped on every run** — it guarded with
  `skip-unless (boundp 'jira-base-url)`, and the variable does not exist until the deferred
  package loads. It reported "skipped" in a green suite, which reads as coverage. A skip
  condition that is *always* true is a silent hole; if a test needs a feature loaded, load it.

Related: the instance turned out to be Server/Data Center, not Cloud — `/rest/api/3/`
302s there and `/rest/api/2/` 401s. Two anonymous curls settle it, and the answer changes
`jira-api-version` and whether the token is a PAT. Ask the endpoint, not the hostname.

## L-019 — A comment naming a key or a file is a claim, and it drifts silently

Writing the jira.el cheat sheet meant reading the package's actual keymaps, and the header
of `lisp/init-jira.el` disagreed with them: it told the reader to press `E` to export, where
`jira-issues-mode-map` binds `e` (`jira-issues.el:395`) and nothing in the package binds `E`
at all. The same header sent the operator to `custom.el` for `rata-jira-base-url`, which
D-012 reserves for Custom's machine-generated churn — a value hand-written there is
overwritten on the next `M-x customize` save, and `local.el.example` already said `local.el`.

- **Prose about a third-party keymap is unverifiable and therefore rots.** Neither wrong key
  would fail any test, any lint, or any compile. Point at the package's keymap and at a
  cheat sheet that was derived from it (`docs/jira-cheatsheet.org`) rather than restating
  keys inline, and re-derive rather than trusting the comment.
- **A doc bug that contradicts a decision record is mechanically checkable, so check it.**
  `no-custom-el-advice` in `scripts/are-audit.sh` fails any module telling the reader to set
  a value in `custom.el`. That is the half of this that could have been caught for free, and
  now is.
- **`docs/` was entirely gitignored** (`docs/*`, added incidentally in 7e599c1), so a
  hand-written document there never reaches the remote — the audit's own
  `are-files-committable` warning about `docs/ARE-FINDINGS.md` had been saying so. Committed
  documentation now needs an explicit negation in `.gitignore`.

Related: L-017 and L-018 (both from the same module — its cost has been in the seams
between this config and upstream, not in either one).

## L-020 — A doc that restates a checked fact outlives the fact

`scripts/are-audit.sh` has checked `core.hooksPath` since ARE bootstrap and reports it
correctly every session. It was still wrong everywhere it mattered: when the gate was
installed on 2026-08-25, `AGENTS.md`, `.are/INDEX.md`, `TESTING_STRATEGY.md`, the
`FAILURE_INDEX` row and `FAIL-0005` itself all went on asserting it was unset — four of
them in the present tense. An agent read `AGENTS.md`, reported to the operator that the
local gate was off, and then lost two commit attempts to 90 s and 120 s timeouts,
misdiagnosing the hook it had just denied existed as a hung `git grep`.

- **The check was never the weak point; the prose beside it was.** A machine-readable fact
  should be *named* in prose and *reported* by the check — `AGENTS.md` should say "read
  `are-audit`'s `hooks-installed`", not restate today's verdict. A verdict written into a
  tracked file has no expiry and nothing recomputes it.
- **Status lines drift in one direction: toward "still broken".** Every one of these was
  written while the item was open and none was revisited when it closed. Closing an item
  means grepping for its every mention, not editing the record that carries its number.
- **Historical prose is fine; undated present tense is not.** `FAIL-0005`'s symptom block is
  correct as a 2026-08-19 artifact. What misleads is a bare "is unset" in a document read at
  the start of every session. Hence `hooks-docs-current` scopes to exactly those two files.
- **Cost is the tell.** The operator had been told commits were ungated, so a three-minute
  commit looked like a hang rather than the gate working.

Related: [L-005](#l-005--verify-the-gate-not-just-the-tests) (verify the gate, not the
tests — this is its second half: having verified it, keep what you tell people in sync),
L-016 and L-019 (both the same shape — unverifiable prose asserting a checkable fact).

## L-021 — The trailing `elpaca-wait` in init.el is load-bearing for batch/headless runs

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

## L-022 — Declare a package *after* any dependency that carries a custom elpaca recipe

**From:** the jump-keybindings session, 2026-08-24, adding `consult-lsp` (which depends on
`lsp-mode`) to `init-completion.el`. `init-completion` loads *before* `init-dev.el`, where
`lsp-mode` is declared with an explicit recipe (`:files (:defaults "clients/*.*")`). The
`are-verify relevant` ERT step died with an elpaca *build* error — not a test failure —
`Elpaca build error: (elpaca lsp-mode ...) "dependent consult-lsp in past queue"`.

Cause: elpaca resolves a package's dependencies when it first *sees* the package. Declaring
`consult-lsp` first pulled `lsp-mode` into an earlier queue with elpaca's *default* recipe;
the later explicit recipe in `init-dev.el` then conflicted with the already-queued default.
The fix was purely ordering: declare `consult-lsp` in `init-dev.el` immediately after the
`lsp-mode` `use-package`, so the explicit recipe is registered before anything depends on it.
`:after (consult lsp-mode)` controls *load* order, not *queue/recipe* order — it does not help.

A second, separate symptom on the same run: the very first gate run after adding the package
failed `rata-test-keybindings-all-commandp` on `consult-lsp-symbols`, because elpaca was
still fetching/activating the freshly-added package when ERT loaded (cf. L-014). Re-running
after the build completed passed. Distinguish "not yet installed" (transient, one clean
re-run fixes it) from "recipe conflict" (deterministic, needs the reorder above).

**Apply:** when a new `:ensure` package depends on another package that has a non-default
recipe elsewhere in the config, place the new declaration *after* that dependency's
`use-package`, in load order — not in whichever module feels topical. An elpaca *build*
error naming a "dependent … in past queue" is this, not a code bug.

---

## L-023 — A block agenda's tag filter belongs in the command's global slot, and a `:name`-only super-agenda group names nothing

**From:** the work-agenda session, 2026-08-26, giving the `"w"` command a dated `agenda`
block so deadlines appear under day headers instead of in a flat "Due Soon" bucket
(`lisp/init-org.el`).

Three things in `org-agenda-custom-commands` fail *silently* — the view still opens, it is
just wrong — and all three were found only by rendering the agenda and reading the output:

1. **`org-agenda-tag-filter-preset` must sit in the entry's 4th element**, the general
   settings slot shared by every block. Its own docstring (`org-agenda.el:3834`) says that
   defining it for one block of a block agenda "will not work reliably". `org-agenda-run-series`
   `eval`s the general props once (`org-agenda.el:3347`) and binds them across all blocks.
2. **A super-agenda group carrying only `:name` and `:order` selects nothing.** The
   `(:name "Other Projects & Tasks" :order 99)` that had been in this config since it was
   written was inert: the leftovers fell into org-super-agenda's own catch-all, printed as
   `org-super-agenda-unmatched-name` — "Other items". `:anything t` is what claims them under
   the intended name. `"p"` and `"d"` still have inert copies of this shape.
3. **Groups are applied in list order, `:order` only sorts the output.** A `:discard` placed
   before a group swallows that group's items. Here `(:discard (:scheduled t :deadline t))`
   had to come *after* "Due later", or deadlines beyond the calendar's horizon appeared in
   neither block. Selectors *inside* one group are OR'ed, not AND'ed
   (`org-super-agenda.el:1222`); AND needs the explicit `:and` selector.

Two facts worth not re-deriving: block *and* general settings are `eval`ed at agenda-build
time (`org-agenda.el:3347,3371`), so a backquoted value form recomputes on every `g`. And a
deadline's prewarning is only ever shown on **today's** line, never repeated across the span
(`org-agenda-get-deadlines`, the `((not today?) (throw :skip nil))` branch) — so a long span
does not multiply prewarnings, and `org-deadline-warning-days 0` in a block removes just the
one echo under today.

**Apply:** treat any change to `org-agenda-custom-commands` as untested until the agenda has
been *rendered*. `just test-work-agenda` (`tests/work-agenda-render.el`) does that headlessly
over fixtures in `temporary-file-directory`. Two traps in writing such a test: `--batch`
implies `-q`, so it must load `init.el` itself; and `org-agenda` here is advised to append
every org-roam `:hastodo:` file (`rata-org-agenda-files-advice`), so `rata-org-roam-agenda-files`
has to be stubbed or the operator's real second-brain tree enters the assertions.

## L-024 — A child frame is not a window: no `display-buffer` rule places it, and lsp-ui measures against the frame

**From:** the lsp-ui-doc session, 2026-08-26. The hover documentation popup appeared in the
top-left corner of the *frame*, over whichever window happened to be there, rather than in
the window holding point (`lisp/init-dev.el`).

Two things to not re-derive:

1. **`shackle-rules` and `display-buffer-alist` have no say over a child frame.** They are
   consulted by `display-buffer`, and a child frame never goes through it. Every popup in
   this config that "ignores shackle" — lsp-ui-doc, corfu, flycheck-posframe, evil-owl — is
   a child frame positioned by its own package. Searching `init-system.el` for the cause of
   a misplaced popup is wasted time; find the package that owns the frame.
2. **`lsp-ui-doc` positions horizontally against the whole Emacs frame in every mode.**
   `lsp-ui-doc-alignment 'window` reaches only the `top`/`bottom` positions, and even then
   only the `right` side: `lsp-ui-doc-side 'left` is a literal `10`-pixel x in
   `lsp-ui-doc--move-frame`, and `at-point` puts x at the symbol's own column. With the
   defaults (`position 'top`, `alignment 'frame`, `max-width 150`) the popup's x is
   `(max (- (frame-pixel-width) width char-w) 10)` — a popup as wide as the frame hits the
   `10` floor, which is why "top-right by default" presents as top-left.

**Apply:** "put this popup where point is" is an advice, not a setting. Take `at-point` for
the vertical placement (it is already window-relative and dodges the current line), and
override x with an `:around` on `lsp-ui-doc--mv-at-point` reading
`(nth 2 (window-edges nil t nil t))` — the same frame-relative pixel measurement upstream
takes for its own START-X, so the two agree about the coordinate space.
`rata-lsp-ui-doc--align-right` in `lisp/init-dev.el` is the worked example, and
`rata-test-lsp-ui-doc-aligns-to-window-right` in `tests/run-tests.el` is the executable form
of this lesson: it stubs `window-edges`/`frame-pixel-width` and fails for any implementation
that measures against the frame. Verification is genuinely split here — placement arithmetic
is testable headlessly, the child frame itself is in the `gui` NOT TESTED bucket, so the
visual result still has to be looked at.

## L-025 — A data file that code filters on is code, and its every failure mode is silent

**From:** the feeds.org retagging session, 2026-08-26. `feeds.org` gained three tag axes
(content type, topic, cadence) and a per-feed slug on all 94 entries; `init-elfeed.el` was
rewritten to generate its filter commands and keys from `rata-elfeed-views`.

Three things to not re-derive:

1. **`feeds.org` was classified LOW / `fast` while the code reading it was MEDIUM.** Twelve
   of its tags are string literals in `init-elfeed.el`, so a rename in the "data" file
   breaks the "code" file — and the break is *invisible*: elfeed answers a filter that
   matches nothing with an empty entry list, which looks exactly like having read
   everything. The root `:elfeed:` tag is worse. It has no reference anywhere in this
   repo's Elisp — it matches `elfeed-org`'s default `rmh-elfeed-org-tree-id`, which is
   never set here — so grep finds nothing to protect it, and removing it hides all 94
   feeds with no error at all. `feeds.org` is now MEDIUM / `relevant`.
2. **Org tags are `[[:alnum:]_@#%]` only, and they fail closed on the whole group.** A
   hyphen does not produce a malformed tag; it stops the trailing `:a:b:` being read as a
   tag group at all, so the feed silently inherits only its section's tags. This is why the
   existing tag is `tech_radar`. Tags are also interned symbols and case-sensitive: the
   pre-existing `:Ntietz:` could never be matched by typing `+ntietz`.
3. **The `f`-prefix filter keys were invisible to the test suite.** They go through
   `general-define-key`, and `rata-test--walk-form` (`tests/run-tests.el:82`) only descends
   into `rata-leader` forms. So the 14 keys had no `commandp` coverage of any kind — the
   FAIL-0009 blind spot, one keymap over.

**Apply:** when code filters on strings living in a data file, the contract needs an
executable check, not a comment — parse the data file in a test and assert every string the
code names actually occurs. `rata-test-elfeed-view-tags-exist-in-feeds-org`,
`rata-test-elfeed-root-tag-present`, `rata-test-elfeed-views-well-formed` and
`rata-test-feeds-org-tag-conventions` in `tests/run-tests.el` are the worked example; each
was confirmed to fail against a deliberately mutated `feeds.org` before being kept, because
a contract test that cannot go red is worse than no test. The second half of the lesson is
structural: `rata-elfeed-views` had already drifted into dead code duplicated by hand into
13 defuns and 13 keybindings. Generating the commands and keys from the one list removes the
drift, and generating the *commands* at module top level while binding the *keys* in
`use-package`'s `:config` is what keeps them testable — a mode-scoped keymap genuinely needs
`:config`, a command does not, and putting both there would have reproduced FAIL-0009.

## L-026 — Config-derived state is a third copy, and a config-vs-code test cannot see it

**From:** [`FAIL-0011`](failures/FAIL-0011.md), 2026-08-26 — the session immediately after
the one that produced L-025. `feeds.org` was correct, `rata-elfeed-views` was correct, all
four `rata-test-elfeed-*` tests were green, and 22 of 36 elfeed views returned an empty
list.

**Mechanism.** Elfeed applies a feed's tags to an entry **once, at fetch time**
(`elfeed.el:312,337`), then stores them on the entry in `elfeed-db/index`. `elfeed-feeds` —
which elfeed-org rebuilds from `feeds.org` on every `M-x elfeed` — therefore only governs
entries that have not arrived yet. Editing the tag vocabulary is not retroactive, and 8833
existing entries kept the old symbols. The views that still worked were exactly the ones
whose tag predated the change; that pattern is what made it look like a filter-string bug
rather than a database one.

**The generalisation, which is the part worth keeping.** L-025 said: when code filters on
strings in a data file, assert in a test that every string the code names occurs in the
file. That is necessary and it is not sufficient. If anything *materialises* that config
into persistent state — a database row, a cache, a generated file, an index — then there is
a **third** copy, it was written under an older version of the config, and no test that
compares the two source files can see it. The failure mode is silent by construction: the
stale copy is internally consistent, it just answers an older question.

**Apply.**

1. When you change a vocabulary that persisted state was written from, ship the **backfill
   in the same change** as the vocabulary. Look for it upstream first — elfeed already had
   `elfeed-apply-autotags-now` and it had simply never been wired in here; the fix was two
   calls, not a tagging engine.
2. Prefer running the backfill automatically over documenting that it must be run. Measure
   the cost before deciding: this one is 0.02 s to retag 8833 entries and 0.11 s to
   serialise a 3.5 MB index, so `elfeed-search-mode-hook` needs no once-per-session guard.
   A manual entry point (`SPC a r t`) stays useful for the case of editing `feeds.org` in a
   running Emacs.
3. Test the **wiring**, not the state. `rata-test-elfeed-retag-wired` asserts the command
   exists, is on the hook, is reachable from its key, and that both upstream functions it
   calls still exist. The suite cannot assert against the operator's database — it can
   assert that something applies the contract to it.
4. When a filter can return "no matches" and "nothing matched because the data predates
   your query" identically, that ambiguity is the bug's hiding place. Reach for the actual
   store early: one histogram of `elfeed-entry-tags` over the live index named the cause
   outright, after reasoning about filter strings had produced nothing.

**Diagnostic worth keeping** — read the operator's real database without loading the config
or touching the network:

```sh
emacs -Q --batch -L elpaca/builds/elfeed --eval '(progn
  (require (quote elfeed-db))
  (setq elfeed-db-directory "/home/jens/.config/emacs/elfeed-db")
  (elfeed-db-load)
  (let ((h (make-hash-table :test (quote eq))))
    (with-elfeed-db-visit (e f)
      (dolist (tg (elfeed-entry-tags e)) (puthash tg (1+ (gethash tg h 0)) h)))
    (maphash (lambda (k v) (princ (format "%6d  %s\n" v k))) h)))'
```
