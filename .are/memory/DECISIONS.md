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
