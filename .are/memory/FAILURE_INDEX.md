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
| [FAIL-0014](failures/FAIL-0014.md) | MEDIUM | configuration, environment-drift, verification-gap | `init-llm.el`, `justfile` `install-deps`, `.are/knowledge/INTEGRATIONS.md` | The Claude ACP adapter was pinned to `claude-code-acp`, a name upstream abandoned five months earlier, and installed only via Arch-only `aur_pkgs` — so `SPC a i c c` had never worked on the Ubuntu host while the key itself resolved and every gate passed; an unrelated npm package of the same name (bin `cc-acp`) made `npm ls -g` look correct | pre-existing | FIXED | `rata-test-acp-adapter-commands-match-upstream`; `are-audit` check `acp-adapters-on-path` (warn) |
| [FAIL-0015](failures/FAIL-0015.md) | MEDIUM | environment-drift, verification-gap | `elpaca/builds/`, `eln-cache/`, `init-completion.el`, `tests/run-tests.el` | The host's Emacs went 30.2 -> 31.1, invalidating every byte-compiled package at once: `compat-call` resolves at compile time, so marginalia and elfeed hard-call `compat--seconds-to-string`, a shim compat correctly stops defining on 31 — `void-function` on every `find-file` while all 36 modules loaded and every gate stayed green | pre-existing, triggered externally by the 2026-09-04 Emacs upgrade | PARTIALLY FIXED — config changes applied; artifact rebuild is an operator action | `are-audit` check `build-artifact-emacs-version` (warn) |
| [FAIL-0016](failures/FAIL-0016.md) | MEDIUM | configuration, verification-gap | `init-jira.el`, `tests/run-tests.el` | The Jira buffers' emacs state lived in a `:config` block keyed on the `jira` feature, which nothing in the config ever loads (elpaca autoloads `jira-issues`; no file requires the umbrella) — so every jira.el key was shadowed by evil and `l` moved the cursor right | pre-existing | FIXED — hoisted out of `:config`; the emacs-state design was then replaced by a local-leader key mirror on operator instruction (D-015) | `rata-test-jira-buffers-keep-evil-and-mirror-keys`, `rata-test-jira-mirrored-keys-exist-upstream`, `rata-test-use-package-config-blocks-can-run` |
| [FAIL-0017](failures/FAIL-0017.md) | MEDIUM | verification-gap, integration-shape | `init-jira.el`, `tests/run-tests.el` | The new Sprint column showed every issue as Backlog: Jira Server's `field` endpoint sends `id` but no `key`, jira.el keeps `(NAME . key)`, so every custom field resolved to nil — the fixture had been written from Cloud docs, and no live read was done before delivery | introduced by D-018 the same day, over a pre-existing upstream defect | FIXED — `(or key id)`, `jira-api-get-fields` overridden, confirmed live | `rata-test-jira-custom-field-parent-resolves-to-its-id` (Server-shaped response) |

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
- **FAIL-0014** is the third, and it fails one level lower than either. The suite was green
  on a *correct* contract — `rata-test-keybindings-live-after-init` asserts `SPC a i c c`
  resolves to `agent-shell-anthropic-start-claude-code`, and it did. The command was live;
  only the external binary it spawns did not exist, and nothing in `tests/` execs an adapter.
  Worse, the knowledge base already recorded "not present on this Ubuntu host": a
  known-missing dependency had been written down as a settled property of the machine rather
  than a defect with a fix. See [LESSONS.md](LESSONS.md) L-033.
- **FAIL-0011** is the second such record, and the sharper one: the tests were not merely
  silent, they were *green on the right contract*. Both `feeds.org` and `init-elfeed.el`
  were correct; the stale copy of the tags lived in a third place neither file mentions
  (`elfeed-db/index`). When state is derived from config at write time, a config-vs-code
  test says nothing about the state already on disk — see L-026.
- **FAIL-0015** is the first record with **no cause inside the repository at all**. Nothing
  was committed, nothing drifted, no test was shallow — the host's Emacs was upgraded, and
  that silently invalidated every artifact under `elpaca/builds` and `eln-cache`, because
  macros resolve at byte-compile time. It extends the FAIL-0011 pattern (state on disk that
  no config-vs-code test can see) one step further: that state is not even version
  controlled, so no amount of reading the repository could have found it. The only check
  that works is one that reads the artifacts themselves — see L-036.

**Origin split:** FAIL-0001 through FAIL-0007, FAIL-0009 and FAIL-0010 are pre-existing. FAIL-0008 was
introduced by ARE, found by running the new tooling before trusting it, and fixed in the same
session. FAIL-0011 was introduced by the immediately preceding feature commit and found by the
operator using the feature — not by the suite. FAIL-0015 was triggered externally by an
OS-level Emacs upgrade and, like FAIL-0011, was found by the operator hitting it rather than
by any gate. FAIL-0017 was introduced by a feature delivered earlier the same day and found by
the operator within minutes; the suite was green because its fixture assumed the Cloud response
shape, and one live read-only request would have shown otherwise.
