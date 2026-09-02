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
| [FAIL-0011](failures/FAIL-0011.md) | MEDIUM | configuration, verification-gap | `init-elfeed.el`, `feeds.org` | Elfeed stamps a feed's tags onto an entry at fetch time, so the tag-axis rework left 22 of 36 views matching zero entries while every tag-contract test stayed green | introduced by `a037bab` | FIXED | `rata-test-elfeed-retag-wired` |
| [FAIL-0012](failures/FAIL-0012.md) | MEDIUM | configuration, verification-gap, self-inflicted | `init-dialogic.el`, `are-verify.sh`, `justfile` `batch` | `eval-when-compile` is `progn` in interpreted code, so a compile-time `(require 'org)` loaded built-in Org before elpaca activated the newer one; four version-mismatch warnings on every interactive start while `are-verify full` reported PASS on batch-startup | introduced by `a488d5c` | FIXED | `just batch-strict` (reads startup output, not just exit code) |
| [FAIL-0013](failures/FAIL-0013.md) | MEDIUM | repo-hygiene, verification-gap | `init-org.el`, `scripts/are-audit.sh` | A merge conflict marker was committed; it parses as two ordinary Elisp symbols and sits after `provide`, so lint, compile, the reader-based keybinding tests and `featurep` all stayed green | introduced by `b510337` | FIXED | `are-audit` check `no-conflict-markers` |

## Patterns visible across these records

Most of these are **verification gaps rather than code defects**, and that is the honest
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
- **FAIL-0011** is the second such record, and the sharper one: the tests were not merely
  silent, they were *green on the right contract*. Both `feeds.org` and `init-elfeed.el`
  were correct; the stale copy of the tags lived in a third place neither file mentions
  (`elfeed-db/index`). When state is derived from config at write time, a config-vs-code
  test says nothing about the state already on disk — see L-026.

**Origin split:** FAIL-0001 through FAIL-0007, FAIL-0009 and FAIL-0010 are pre-existing. FAIL-0008 was
introduced by ARE, found by running the new tooling before trusting it, and fixed in the same
session. FAIL-0011 was introduced by the immediately preceding feature commit and found by the
operator using the feature — not by the suite.
