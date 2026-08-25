# Failure index

Compact index. Read a record only when your change touches its area.
Add a row here whenever you add a record — the record is the detail, this is the lookup.

| ID | Sev | Category | Area | Summary | Origin | Status | Regression protection |
|---|---|---|---|---|---|---|---|
| [FAIL-0001](failures/FAIL-0001.md) | MEDIUM | environment-drift, documentation | repo layout, `README.org`, `AGENTS.md`, `init-dashboard.el` | Two checkouts of this repo; docs and the dashboard point at the stale one | pre-existing | OPEN — operator decision | `are-audit` check `docs-paths` |
| [FAIL-0002](failures/FAIL-0002.md) | LOW | configuration, obsolete-api | `init-snippets.el` | Obsolete `yas-installed-snippets-dir` warned on every startup | pre-existing | FIXED | `rata-test-yas-snippet-dirs-exist` |
| [FAIL-0003](failures/FAIL-0003.md) | MEDIUM | verification-gap | `justfile` `compile` | Compiles with no packages loaded; exits 0 on any warning — proves syntax only | pre-existing | DOCUMENTED | scope labelled in `are-verify` output |
| [FAIL-0004](failures/FAIL-0004.md) | MEDIUM | verification-gap | `justfile`, `.githooks/pre-commit` | The CRITICAL module's 3 s e2e suite was excluded from the gate | pre-existing | FIXED | `are-audit` check `gate-covers-tests` |
| [FAIL-0005](failures/FAIL-0005.md) | MEDIUM | verification-gap | git config | `core.hooksPath` was unset, so the local pre-commit gate was off | pre-existing | FIXED here — CI added 2026-08-24; hook installed 2026-08-25. Recurs in any fresh clone (cause is per-clone config) | `are-audit` check `hooks-installed` (warn) |
| [FAIL-0006](failures/FAIL-0006.md) | LOW | verification-gap | `init.el`, `lisp/` | A module could exist in `lisp/` and never be wired into `init.el` | pre-existing, latent | FIXED | `rata-test-init-loads-every-module` |
| [FAIL-0007](failures/FAIL-0007.md) | LOW | repo-hygiene | repo root | Stray untracked 5-byte file `ɢ`; nothing notices unexpected untracked files | pre-existing | FIXED — deleted 2026-08-24 on operator instruction | `are-audit` check `stray-files` (warn) |
| [FAIL-0008](failures/FAIL-0008.md) | LOW | verification-gap, self-inflicted | `scripts/are-audit.sh`, `scripts/are-context.sh` | ARE's own first audit run produced 3 false results; checks were pointed at the wrong artifact | **introduced by ARE** | FIXED | every check deliberately broken and confirmed to fire |
| [FAIL-0009](failures/FAIL-0009.md) | MEDIUM | configuration, verification-gap | `init-dev.el`, `init-evil.el`, 20 more modules | Leader keys bound in a deferred `use-package :config` are never created; `SPC p f` was undefined in the live editor while every test passed | pre-existing | RESOLVED 2026-08-24 — all 113 dead global keys hoisted to top-level `with-eval-after-load 'general`; probe now reports 0 dead | `rata-test-all-global-leader-keys-live-after-init` (exhaustive) |
| [FAIL-0010](failures/FAIL-0010.md) | HIGH | verification-gap, configuration | `init-claude-loop.el` | Bash was never permitted, so a task told to verify its work reasoned about the diff instead and reported `done`; the loop ticked the box | pre-existing | FIXED | `rata-test-claude-loop-classify-unverified`, e2e §14 |

## Patterns visible across these records

Six of nine are **verification gaps rather than code defects**, and that is the honest
headline of this bootstrap: the Elisp in this repository is in good shape, and what was
weak was the machinery that would tell you if it stopped being so.

- **FAIL-0003, FAIL-0004, FAIL-0005, FAIL-0006, FAIL-0008** are all the same shape — a check
  that exists but does not reach as far as its name suggests, or a gate that is off. See
  [LESSONS.md](LESSONS.md) L-003 through L-006 and L-008, L-010.
- **FAIL-0001 and FAIL-0007** are both "the repository's own state drifted and nothing
  looked". Now audited.
- **FAIL-0002** and **FAIL-0009** are the behavioural defects in the configuration itself.
  FAIL-0002 was cosmetic; FAIL-0009 is not — it left 86 leader keys dead in the running
  editor, and it is the first record where the *tests themselves* certified the broken thing
  as correct (see [LESSONS.md](LESSONS.md) L-011).

**Origin split:** FAIL-0001 through FAIL-0007 and FAIL-0009 are pre-existing. FAIL-0008 was introduced by
ARE, found by running the new tooling before trusting it, and fixed in the same session.
