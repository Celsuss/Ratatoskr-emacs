# ARE SYSTEM — how to operate ARE in this repository

This file is the operating manual. [INDEX.md](INDEX.md) is the map.

ARE here is deliberately small: markdown knowledge + a path map + three bash scripts
that reuse the existing `just` targets. No new dependency, no database, no embeddings.
The repo is ~5.2k lines of Elisp; anything heavier would cost more than it returns.

---

## 1. The loop

```
task → are-context → risk tier → implement → verify at that tier
     → investigate failures → fix → regression protection
     → update ARE knowledge → improve verification → verify again → report
```

## 2. Every session that changes code

1. **Start from context, not from scanning.**
   ```sh
   just are-context            # writes .are/generated/CURRENT_CONTEXT.md
   ```
   It reads `git status`/`git diff`, maps changed paths through
   [knowledge/MODULES.md](knowledge/MODULES.md), and prints only the areas, risks,
   knowledge pages, failure records and test commands that the change actually touches.

2. **Read only what it names.** Open a knowledge page or failure record when the change
   touches its area — not "to be safe". Do not re-derive the architecture; do not
   re-read `SPEC.md`.

3. **Classify risk** with [rules/RISK_RULES.md](rules/RISK_RULES.md).

4. **Implement.**

5. **Verify at the depth the tier demands** ([rules/VERIFICATION_RULES.md](rules/VERIFICATION_RULES.md)):
   ```sh
   just are-verify fast        # ~4 s,  no packages needed
   just are-verify relevant    # ~2 min
   just are-verify full        # ~3 min
   ```

6. **Report per area: PASS / FAIL / NOT TESTED.** Never infer a PASS from "the code looks
   right". If a command was not run, the area is NOT TESTED and you say so.

## 3. Self-improvement is mandatory on every task, not only on failures

Before closing any meaningful piece of work, answer these seven questions. Apply every
cheap improvement immediately; the system must be harder to break than when you started.

1. Did anything **fail or surprise** you? → new record in [memory/failures/](memory/failures/) + a line in [memory/FAILURE_INDEX.md](memory/FAILURE_INDEX.md).
2. Is the failure an **instance of a pattern**? → [memory/LESSONS.md](memory/LESSONS.md).
3. Did you **decide something** a future session would otherwise re-litigate? → [memory/DECISIONS.md](memory/DECISIONS.md).
4. Did you touch a path **not in the map**, or with the wrong risk/tests? → fix [knowledge/MODULES.md](knowledge/MODULES.md).
5. **What check would have caught this sooner?** Prefer an executable test over prose:
   an ERT test in `tests/run-tests.el`, a case in `tests/claude-loop-e2e.el`, a check in
   `scripts/lint.sh`, or a check in `scripts/are-audit.sh`. Prose is the fallback, not the goal.
6. Did you find a **knowledge line that is now wrong**? → correct that line. Do not rewrite the page.
7. Did the **verification level mislead you** (passed while broken, or failed spuriously)? → fix the level and say so in the report.

Cost control: incremental edits to existing files, not regenerated documents.

## 4. Token discipline

These are requirements, not suggestions. The knowledge base is small; keeping it cheap
is what keeps it worth having.

**Do**
- Start from `generated/CURRENT_CONTEXT.md` and the tables in
  [knowledge/MODULES.md](knowledge/MODULES.md).
- Prefer deterministic retrieval: `git diff --name-only`, `git log -n … -- <path>`,
  `grep`, the path map.
- Prefer running a test over reasoning about whether behaviour changed.
- Read a specific line range when you know it (`sed -n '900,960p'`).

**Do not**
- Load the whole `.are/knowledge/` tree for a one-module change.
- Read `SPEC.md` in full — 2408 lines, drifted, historical intent only. `grep` it.
- Re-read unchanged files "to confirm". If it is unchanged, it is what the knowledge says.
- Re-derive the module graph. `init.el` and [knowledge/ARCHITECTURE.md](knowledge/ARCHITECTURE.md) have it.
- Byte-compile or full-init to check a typo — `just check <file>` or `just are-verify fast`.

## 5. Where ARE deliberately does not duplicate the project

ARE is a thin layer. These stay authoritative where they are:

| Topic | Owner | ARE's role |
|---|---|---|
| Code style, `use-package` layout, keybinding conventions, module recipe | `AGENTS.md` | link to it |
| Per-module behaviour and design rationale | `AGENTS.md` module list + the module's own comments | link; add risk + tests |
| Build / run / test commands | `justfile` | wrap into risk tiers, never re-implement |
| Convention enforcement | `scripts/lint.sh` | extend it, do not fork it |
| Unit-level truth | `tests/run-tests.el`, `tests/claude-loop-e2e.el` | add cases, do not add a second framework |
| Historical design intent | `SPEC.md` | flag drift; never treat as truth |
| User-facing docs | `README.org` | flag drift |

If ARE and one of those disagree, the code wins, then the test, then the owner document,
then ARE. Record the discrepancy rather than silently picking a side.

## 6. Files ARE generates

`.are/generated/CURRENT_CONTEXT.md` is regenerated on demand and is **committed on
purpose**: it is small, it is a useful diff-time record of what the last session
believed it was touching, and keeping it in-tree avoids a `.gitignore` rule that would
silently swallow it. If it is stale, run `just are-context`.
