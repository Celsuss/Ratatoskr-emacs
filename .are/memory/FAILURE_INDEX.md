# Failure index

Compact index. Read a record only when your change touches its area.
Add a row here whenever you add a record — the record is the detail, this is the lookup.

| ID | Sev | Category | Area | Summary | Origin | Status | Regression protection |
|---|---|---|---|---|---|---|---|
| [FAIL-0001](failures/FAIL-0001.md) | MEDIUM | environment-drift, documentation | repo layout, `README.org`, `AGENTS.md`, `init-dashboard.el` | Two checkouts of this repo; docs and the dashboard point at the stale one | pre-existing | OPEN — operator decision | `are-audit` check `docs-paths` |
| [FAIL-0002](failures/FAIL-0002.md) | LOW | configuration, obsolete-api | `init-snippets.el` | Obsolete `yas-installed-snippets-dir` warned on every startup | pre-existing | FIXED | `rata-test-yas-snippet-dirs-exist` |
| [FAIL-0003](failures/FAIL-0003.md) | MEDIUM | verification-gap | `justfile` `compile` | Compiles with no packages loaded; exits 0 on any warning — proves syntax only | pre-existing | DOCUMENTED | scope labelled in `are-verify` output |
| [FAIL-0004](failures/FAIL-0004.md) | MEDIUM | verification-gap | `justfile`, `.githooks/pre-commit` | The CRITICAL module's 3 s e2e suite was excluded from the gate | pre-existing | FIXED | `are-audit` check `gate-covers-tests` |
| [FAIL-0005](failures/FAIL-0005.md) | MEDIUM | verification-gap | git config | `core.hooksPath` unset, so the only possible gate is off; no CI exists | pre-existing | OPEN — `just install-hooks` | `are-audit` check `hooks-installed` (warn) |
| [FAIL-0006](failures/FAIL-0006.md) | LOW | verification-gap | `init.el`, `lisp/` | A module could exist in `lisp/` and never be wired into `init.el` | pre-existing, latent | FIXED | `rata-test-init-loads-every-module` |
| [FAIL-0007](failures/FAIL-0007.md) | LOW | repo-hygiene | repo root | Stray untracked 5-byte file `ɢ`; nothing notices unexpected untracked files | pre-existing | OPEN — reported, not deleted | `are-audit` check `stray-files` (warn) |
| [FAIL-0008](failures/FAIL-0008.md) | LOW | verification-gap, self-inflicted | `scripts/are-audit.sh`, `scripts/are-context.sh` | ARE's own first audit run produced 3 false results; checks were pointed at the wrong artifact | **introduced by ARE** | FIXED | every check deliberately broken and confirmed to fire |

## Patterns visible across these records

Six of eight are **verification gaps rather than code defects**, and that is the honest
headline of this bootstrap: the Elisp in this repository is in good shape, and what was
weak was the machinery that would tell you if it stopped being so.

- **FAIL-0003, FAIL-0004, FAIL-0005, FAIL-0006, FAIL-0008** are all the same shape — a check
  that exists but does not reach as far as its name suggests, or a gate that is off. See
  [LESSONS.md](LESSONS.md) L-003 through L-006 and L-008, L-010.
- **FAIL-0001 and FAIL-0007** are both "the repository's own state drifted and nothing
  looked". Now audited.
- **FAIL-0002** is the only behavioural defect in the configuration itself, and it was
  cosmetic.

**Origin split:** FAIL-0001 through FAIL-0007 are pre-existing. FAIL-0008 was introduced by
ARE, found by running the new tooling before trusting it, and fixed in the same session.
