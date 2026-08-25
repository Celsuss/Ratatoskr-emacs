# Decisions

Things settled, so a future session does not re-litigate them. Record the reasoning, not
just the outcome. If you overturn one, edit it in place and say when and why — do not add a
contradicting entry below it.

---

## D-001 — ARE is markdown + a path map + three bash scripts. Nothing more.

**2026-08-19, ARE bootstrap.**

No vector store, no embeddings, no index database, no new dependency. The repository is ~5.2k
lines of Elisp across 36 modules; `grep`, `git` and a 60-row table in
[../knowledge/MODULES.md](../knowledge/MODULES.md) retrieve from it faster and more reliably
than anything semantic would, and cost nothing to keep correct.

Revisit only with evidence: if context generation starts missing relevant knowledge, or the
knowledge base outgrows what an agent can navigate by index. Not before.

## D-002 — ARE points at `AGENTS.md`; it does not restate it

**2026-08-19.**

`AGENTS.md` is the authoritative, actively-maintained guide to conventions, module purposes,
`use-package` structure and keybinding patterns. Verified accurate at commit `1d38bd8`: its
module load-order list matches `init.el` line for line, and its `init-claude-loop.el` section
matches the implementation.

Copying it into `.are/knowledge/` would create a second source of truth that drifts. So ARE
knowledge pages add only what `AGENTS.md` lacks: **risk, blast radius, what the tests do and
do not prove, and the invariants a change can silently violate.** When they overlap, the
ARE page links rather than repeats.

Consequence: `AGENTS.md` becoming wrong is a MEDIUM-risk event, and is why it carries an
ARE section pointing back here.

## D-003 — `SPEC.md` is historical intent, not truth

**2026-08-19.**

2408 lines, self-labelled "Draft v8 — 2026-02-24", and demonstrably drifted:

- §2 marks `init-dashboard` as `TODO`; it is implemented, 325 lines.
- §2's module list predates the split of `init-lang` into per-language modules (commit
  `bebc14d`), so it does not mention `init-rust`, `init-go`, `init-python`, `init-cpp`,
  `init-cmake`, `init-terraform`, `init-just`, `init-docker`, `init-markdown`, `init-yaml`,
  `init-ansible`, `init-jupyter`, `init-helm` or `init-pkgbuild` as separate files.
- §3 marks the elpaca lockfile "DONE"; the `just` targets exist but no lockfile is committed
  and none exists on disk.

It is also the single largest token trap in the repository. **Do not read it whole. Do not
treat any status marker in it as current. `grep` it for design rationale only.** `init.el`
and `AGENTS.md` are the truth about what exists.

Not rewritten: bringing 2408 lines back into sync is a real task with no reliability payoff,
and would bury the ARE bootstrap diff. Flagged instead, in
[../INDEX.md](../INDEX.md) §6 and here.

## D-004 — `just test` keeps its exact current meaning; the gate moves instead

**2026-08-19, from [FAIL-0004](failures/FAIL-0004.md).**

`just test` = `lint compile batch test-ert`, unchanged. It is referenced in `README.org`,
`AGENTS.md` and muscle memory; silently widening it would make existing documentation wrong
and surprise the operator.

Instead `.githooks/pre-commit` was pointed at `just are-verify full`, which is a superset.
Same protection, no redefinition of an existing name.

## D-005 — Package versions are not reproducible, and that is accepted

**2026-08-19.**

`elpaca` installs from upstream `HEAD`. `just lock` / `just update` write
`var/elpaca-lock.el`, which `.gitignore:44` (`/var/`) excludes; no lockfile exists on this
machine. So two checkouts will not agree on package versions, and `just clean && just run`
can produce a different configuration from the one that was working.

This is the operator's existing choice, and committing a lockfile is a real trade (pinned
reproducibility vs. staying current on 197 packages) that ARE should not make unilaterally.
Recorded so that "the config broke and nothing in git changed" is diagnosed in seconds rather
than hours: check whether packages moved.

## D-006 — Two `.gitignore` inconsistencies are documented, not fixed

**2026-08-19.**

`.gitignore:23-24` ignores `AGENTS.md` and `CONVENTIONS.md`. `AGENTS.md` is tracked anyway,
so the rule is inert for it — but it means a *new* file named `CONVENTIONS.md` (which
`AGENTS.md` itself tells you to maintain, under "Documentation") would silently never be
committable.

Not changed: the ignore lines may be deliberate, and editing `.gitignore` during a bootstrap
whose job is to *add* files is how you accidentally commit something. Documented in
[../knowledge/SECRETS_AND_SENSITIVE_DATA.md](../knowledge/SECRETS_AND_SENSITIVE_DATA.md) §4,
and `are-audit` now verifies every ARE-created path is committable.

**Third instance, 2026-08-19 (same day):** the operator asked for the findings summary in
`docs/`, which `.gitignore:53` (`docs/*`) excludes wholesale — so `docs/ARE-FINDINGS.md` is
written but untrackable. Reported in that file as finding 10 with the one-line exception
(`!docs/ARE-FINDINGS.md`) rather than applied, for the same reason as above.

The pattern is now three-for-three, which is what turned it from an observation into a check:
`are-audit`'s `are-files-committable` was extended to scan `docs/` alongside `.are/`,
`.claude/` and `scripts/`. **Before creating any file this repository is meant to keep, run
`git check-ignore -v --no-index <path>`** — and note the `--no-index`, per
[../memory/LESSONS.md](LESSONS.md) L-009.

## D-007 — `.are/generated/CURRENT_CONTEXT.md` is committed, not ignored

**2026-08-19.**

It is small (tens of lines), it is a useful record of what the previous session believed it
was touching, and — per D-006 and L-009 — adding a `.gitignore` rule for it is the kind of
thing that later swallows a file somebody needed. Regenerate with `just are-context` rather
than trusting its timestamp.

## D-008 — Findings about the operator's identity, infrastructure and workflow are reported, never acted on

**2026-08-19.**

Three bootstrap findings were left deliberately unfixed because the fix is a judgement call
that belongs to the operator, not a defect:

- the work email and Snowflake identifiers in `init-sql.el` on a public remote
  ([SECRETS_AND_SENSITIVE_DATA.md](../knowledge/SECRETS_AND_SENSITIVE_DATA.md) §2) — removal
  needs history rewriting and a rotation decision;
- which of the two checkouts is canonical ([FAIL-0001](failures/FAIL-0001.md));
- whether to accept a ~3-minute pre-commit hook ([FAIL-0005](failures/FAIL-0005.md)).

Each is reported with a concrete recommendation and the exact command. ARE's job was to make
them visible and keep them visible, which the audit now does on every run.

## D-009 — `rata-claude-loop-on-task-failure` defaults to `halt`, not `skip`

**2026-08-20.**

`skip` is what makes an unattended overnight run useful: one impossible task in a list of
twenty stops being a reason for the other nineteen not to run. It is still not the default,
because the failure mode of each choice is asymmetric. A wrong `halt` costs waiting time and
is obvious the moment you look. A wrong `skip` spends money and edits files across a whole
list while the reason the first task failed — a bad root, a missing tool, an unusable verify
command — applies to every one of them, and the run reports "3 done, 17 failed" only at the
end.

So: `halt` while you are watching, `skip` set deliberately for a run you will not watch.
`.are/knowledge/CLAUDE_LOOP.md` §4 says this in the operating notes. A single-task run halts
regardless — there is nothing to continue to.

## D-010 — The run budget assumes `total_cost_usd` is per invocation, and this is untested

**2026-08-20.**

`rata-claude-loop--add-cost` sums the `total_cost_usd` of every `result` event to price a task
and a run. That is right if the CLI reports the cost of the invocation and wrong if it reports
a session total, in which case a `--resume` retry double-counts. Nothing in `tests/` can
settle it: every test uses the stub CLI, which reports whatever the stub says.

The error is in the safe direction — an over-count halts a run early rather than overspending
— so the assumption ships, recorded here and in `.are/knowledge/CLAUDE_LOOP.md` §3, rather
than being hidden in a comment. Settle it by reading one real journal file: if a task's
`cost` is roughly the sum of its attempts' individual costs, the assumption holds.

## D-011 — Jira is a second view in Emacs, not a sync into `work_tasks.org`

**2026-08-25.**

The operator keeps work tasks by hand in `~/workspace/second-brain/org-roam/work_tasks.org`
and also has tickets in corporate Jira. The obvious-looking answer — mirror the tickets into
that file, keyed on an issue id — was rejected, and so was `org-jira`, on the operator's
instruction: no custom sync code to own.

`lisp/init-jira.el` therefore adds `jira.el` (MELPA `jira`, upstream
`unmonoqueteclea/jira.el`, v2.21.1) as a *separate* view: a `tabulated-list` of issues under
`SPC J j`, filterable by JQL, with status changes and worklogs. Nothing writes into the roam
tree. `E` in the issues buffer exports what is on screen to Org-mode when a one-off bridge is
wanted, and that stays a deliberate, manual act.

Why not a sync, for the record — because the next session will be tempted again:

- The file is under `~/workspace/second-brain/`, which `rules/SAFETY_RULES.md` puts
  off-limits to autonomous writes. A sync is a program whose whole purpose is to write there.
- Jira and the org file disagree about what a task *is*. The org headings carry quoted notes
  from colleagues, `#+begin_quote` briefs written for the claude-loop, and sub-checklists.
  A mirror either drops that or has to preserve it around an idempotent rewrite.
- `work_tasks.org` is one node in a `hastodo` agenda query with an `org-kanban` block that
  nothing refreshes automatically. A writer would have to keep that block honest too.

Two smaller choices inside the same decision:

- **Credentials are not configured in the module.** `jira-username` and `jira-token` are
  deliberately left unset, which is what makes `jira.el` fall back to `auth-source` — the
  mechanism `init-system.el` already established. `rata-jira-base-url` defaults to nil and is
  set in the gitignored `custom.el`, because the instance hostname is corporate identity on a
  public remote (`knowledge/SECRETS_AND_SENSITIVE_DATA.md` §2). The module loads inert until
  the operator sets it.
- **The Jira buffers get emacs state, not evil bindings.** Upstream says it does not support
  evil (issue #31), and its keymaps live in `tabulated-list-mode` and `magit-section-mode`
  children — the shadowing trap already documented for `*claude-loop*`. Re-binding its dozen
  keys with `evil-define-key*` would be a maintenance liability against a package on a
  monthly release cadence, so `evil-set-initial-state` puts the three modes in emacs state
  and the documented keys work as shipped. `C-z` returns to normal state.

Revisit if the operator starts wanting Jira tickets in the agenda view rather than in their
own buffer. That is the point where a sync earns its cost — and it should be reconsidered as
a *whole* problem then, not bolted on.

## D-012 — `custom.el` is Custom's scratch pad; `local.el` is yours

**2026-08-25.**

D-011 told the operator to hand-write `rata-jira-base-url` into `custom.el`. That was wrong,
and the reason is worth keeping because it is easy to repeat.

`custom.el` was tracked until `ef33237` (2026-03-28), where it was gitignored in the same
commit that ignored `/var/`, `/etc/`, `/elfeed-db/` and `/persp-confs/` — i.e. it was
classified as *generated state*, correctly. Its entire content at that point was
`'(package-selected-packages nil)` and an empty `custom-set-faces`. Custom rewrites the file
whenever anything is saved from `M-x customize`, so anything hand-written there is churn
waiting to be clobbered, and it is ignored precisely because it is disposable.

So the two jobs are now two files, both gitignored:

| File | Written by | Contains |
|---|---|---|
| `custom.el` | Custom, on save | faces, `safe-local-variable-values`, theme trust — do not hand-edit |
| `local.el` | the operator, by hand | per-machine values that must not reach a public remote |

`local.el` is loaded by `init.el` *after* `custom.el` (so a hand-written value wins over a
stale Custom one) and *before* the modules (so their `defvar`s see it — `defvar` and
`defcustom` both leave an already-bound value alone, which is what makes plain `setq` in
`local.el` work).

**The committed template is the point of the design.** `local.el.example` exists so that the
answer to "what does a fresh machine need?" is versioned rather than remembered. The
operator's actual complaint was not that the file was gitignored — it was not knowing what to
recreate. A gitignored file with no committed manifest has that failure mode built in.

Rejected alternatives, briefly:

- **A committed `local.el.gpg`.** Solves syncing outright and is safe on a public remote, but
  startup currently never touches GPG (`~/.authinfo.gpg` is read lazily — see
  `init-irc.el:75`), and it would have to be skipped under `noninteractive` or it hangs
  `just batch`, `test-ert` and CI on a passphrase prompt. A passphrase at every startup to
  avoid copying one file per machine is a bad trade.
- **A committed file keyed on `(system-name)`.** No GPG and no manual step, but it only works
  for values you are willing to publish, which is exactly what these are not.

The same commit moved the six Snowflake `defvar`s out of `lisp/init-sql.el`, which
`.are/knowledge/SECRETS_AND_SENSITIVE_DATA.md` §2 had recommended and recorded as unresolved.
`rata-sql-snowflake-uri` now signals a `user-error` naming the unset parameters instead of
building a URI from nils that would fail much later inside a Leiningen nREPL boot. The git
history still contains the values; erasing that is a separate, HIGH-risk job that has not been
approved.
