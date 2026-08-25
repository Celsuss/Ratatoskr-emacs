# Verification rules

What must be run, per risk tier. Levels are defined in
[../knowledge/TESTING_STRATEGY.md](../knowledge/TESTING_STRATEGY.md) §3 and implemented by
`scripts/are-verify.sh`.

---

## 1. Required depth

| Tier | Minimum | Also required |
|---|---|---|
| LOW | `just are-verify fast` | — |
| MEDIUM | `just are-verify relevant` | name the affected area in the report |
| HIGH | `just are-verify full` | plus a targeted manual check of the specific behaviour changed, or an explicit NOT TESTED with a reason |
| CRITICAL | `just are-verify full` | plus a new or extended case in `tests/claude-loop-e2e.el` covering the changed behaviour, plus operator approval |

**Any session that changed a `.el` file must end with at least `just are-verify relevant`.**
`fast` does not load a single package and cannot see a broken module.

## 2. Non-negotiables

1. **Never report PASS for something you did not run.** The vocabulary is PASS / FAIL /
   NOT TESTED, per area. "Should work", "looks correct" and "no reason it would break" are
   not verification.
2. **Never claim an integration works.** Nothing in `tests/` contacts a network service.
   Integrations are NOT TESTED unless the operator ran them by hand and said so.
3. **`just batch` exiting 0 is not "startup is fine."** `rata-load-module` swallows module
   failures. The claim requires `rata-test-no-failed-modules`, i.e. `test-ert`.
4. **`just compile` exiting 0 is not "it compiles clean."** It compiles with no packages
   loaded; ~130 `Cannot load` lines are normal and warnings never fail it.
5. **Separate pre-existing failures from ones you caused.** If unsure, `git stash`, re-run,
   `git stash pop`. Report both lists.
6. **A red test is never "fixed" by deleting, skipping or loosening it** without an
   explicit, stated reason and an equivalent replacement check.
7. **Do not run `just clean`, `just reset` or `just update` to make a test pass.** They
   destroy the package tree and `custom.el`. See [SAFETY_RULES.md](SAFETY_RULES.md).
8. **Re-verify after every fix.** Fix → verify → and if the fix changed anything else,
   verify again. Do not stop at the first green.

## 3. Reporting format

End every code-changing session with:

```
Area            Result       Evidence
--------------  -----------  ------------------------------------
lint            PASS         just lint, 0.5s
claude-loop     PASS         just test-claude-loop, 9/9 groups
ERT             PASS         just test-ert, 21/21
startup         PASS         just batch, exit 0
integrations    NOT TESTED   no network/credentials in test env
GUI behaviour   NOT TESTED   headless
```

Then: what changed, what ARE learned, what is still risky.

## 4. Improving the levels

Improving verification is part of finishing a task, not a separate project
([../SYSTEM.md](../SYSTEM.md) §3). If a failure slipped past a level, fix the level in the
same session and say so. Prefer, in order:

1. an ERT test in `tests/run-tests.el`;
2. a case in `tests/claude-loop-e2e.el`;
3. a check in `scripts/lint.sh` (textual, needs no Emacs);
4. a check in `scripts/are-audit.sh` (repo-wide, needs no Emacs);
5. a line of prose in `.are/knowledge/` — last resort, weakest memory.
