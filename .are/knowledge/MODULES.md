# Path map — area, risk, verification, knowledge

**This file is machine-read.** `scripts/are-context.sh` and `scripts/are-audit.sh` parse
the table in section 2. Keep the format exactly: five `|`-delimited columns, one row per
path pattern, `PATH` matched against `git`-reported paths with shell globbing.

`scripts/are-audit.sh` fails if any `lisp/init-*.el` file has no row here. Adding a
module therefore requires adding a row — that is the point.

Risk values: `LOW` `MEDIUM` `HIGH` `CRITICAL`. Definitions: [../rules/RISK_RULES.md](../rules/RISK_RULES.md).
Verify values: `fast` `relevant` `full`. Definitions: [../rules/VERIFICATION_RULES.md](../rules/VERIFICATION_RULES.md).

## 1. Why the risk tiers land where they do

There is no production environment to break, no customer data and no money. The things
that can actually go wrong in an Emacs configuration are:

- **Bricking the editor.** A startup-path error costs the operator their tool. Files that
  run unconditionally at startup are HIGH regardless of how simple they look.
- **Breaking the synchronisation point.** `init-evil.el` contains the `(elpaca-wait)` that
  makes `general` and `evil` available to every later module. Damage there silently
  disables keybindings across the whole config.
- **Autonomous write access.** `init-claude-loop.el` launches a headless agent with
  `--permission-mode acceptEdits` and runs an operator-supplied shell command. It is the
  only CRITICAL area.
- **Reaching the operator's data.** `~/workspace/second-brain` (org-roam notes) is not in
  this repo and is not covered by any test here. Modules that write to it are MEDIUM.
- **Leaking identity.** Anything committed can reach a public GitHub remote.

## 2. Map

| PATH | AREA | RISK | VERIFY | KNOWLEDGE |
|---|---|---|---|---|
| init.el | startup | HIGH | full | knowledge/ARCHITECTURE.md |
| early-init.el | startup | HIGH | full | knowledge/ARCHITECTURE.md |
| lisp/init-pkg.el | packaging | HIGH | full | knowledge/ARCHITECTURE.md |
| lisp/init-system.el | system,secrets | HIGH | relevant | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| lisp/init-evil.el | keybindings,load-order | HIGH | relevant | knowledge/ARCHITECTURE.md |
| lisp/init-claude-loop.el | autonomous-agent | CRITICAL | full | knowledge/CLAUDE_LOOP.md |
| lisp/init-sql.el | integrations,secrets | HIGH | relevant | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| lisp/init-dev.el | tooling,secrets | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-org.el | notes,operator-data | MEDIUM | relevant | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| lisp/init-present.el | notes,operator-data | MEDIUM | relevant | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| lisp/init-khoj.el | integrations,operator-data | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-llm.el | integrations,operator-data | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-irc.el | integrations,secrets | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-elfeed.el | integrations,network | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-jira.el | integrations,network,secrets | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-lang.el | languages,toolchain | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-completion.el | ui,keybindings | MEDIUM | relevant | knowledge/ARCHITECTURE.md |
| lisp/init-ui.el | ui | MEDIUM | relevant | knowledge/ARCHITECTURE.md |
| lisp/init-dashboard.el | ui | MEDIUM | relevant | knowledge/ENVIRONMENTS.md |
| lisp/init-persp.el | ui,state | MEDIUM | relevant | knowledge/ARCHITECTURE.md |
| lisp/init-gamedev.el | languages,subprocess | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-k8s.el | integrations | MEDIUM | relevant | knowledge/INTEGRATIONS.md |
| lisp/init-mcp.el | integrations,unloaded | LOW | fast | knowledge/ARCHITECTURE.md |
| lisp/init-ansible.el | languages,secrets | MEDIUM | relevant | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| lisp/init-rust.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-go.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-python.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-cpp.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-cmake.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-terraform.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-just.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-docker.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-markdown.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-yaml.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-jupyter.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-helm.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-pkgbuild.el | languages | LOW | relevant | knowledge/MODULES.md |
| lisp/init-casual.el | ui,keybindings | LOW | relevant | knowledge/MODULES.md |
| lisp/init-snippets.el | editing | LOW | relevant | knowledge/MODULES.md |
| tests/run-tests.el | verification | HIGH | relevant | knowledge/TESTING_STRATEGY.md |
| tests/claude-loop-e2e.el | verification | HIGH | fast | knowledge/CLAUDE_LOOP.md |
| tests/work-agenda-render.el | verification,notes | HIGH | relevant | knowledge/TESTING_STRATEGY.md |
| scripts/lint.sh | verification | HIGH | fast | knowledge/TESTING_STRATEGY.md |
| scripts/are-*.sh | verification,are | HIGH | fast | SYSTEM.md |
| justfile | verification,tooling | HIGH | full | knowledge/TESTING_STRATEGY.md |
| .githooks/* | verification | HIGH | fast | knowledge/TESTING_STRATEGY.md |
| .claude/* | verification,tooling | MEDIUM | fast | SYSTEM.md |
| .are/* | are | MEDIUM | fast | SYSTEM.md |
| AGENTS.md | docs,conventions | MEDIUM | fast | SYSTEM.md |
| CLAUDE.md | docs,conventions | MEDIUM | fast | SYSTEM.md |
| README.org | docs | LOW | fast | knowledge/ENVIRONMENTS.md |
| docs/* | docs,are | LOW | fast | SYSTEM.md |
| SPEC.md | docs,historical | LOW | fast | memory/DECISIONS.md |
| snippets/* | editing | LOW | fast | knowledge/MODULES.md |
| feeds.org | integrations,network | LOW | fast | knowledge/INTEGRATIONS.md |
| local.el.example | packaging,secrets | MEDIUM | fast | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| .gitignore | packaging | MEDIUM | fast | knowledge/SECRETS_AND_SENSITIVE_DATA.md |
| .gitattributes | packaging | LOW | fast | knowledge/MODULES.md |
| repomix.config.json | packaging,tooling | LOW | fast | knowledge/MODULES.md |
| .repomixignore | packaging,tooling | LOW | fast | knowledge/MODULES.md |
| logo.png | assets | LOW | fast | knowledge/MODULES.md |
| LICENSE | legal | LOW | fast | knowledge/MODULES.md |

## 3. What the leaf language modules have in common

Every `lisp/init-<lang>.el` is LOW risk and structurally identical: one or more
`use-package` forms, mode-local keybindings under the `,` local leader, and occasionally
one helper. They cannot break startup because they are deferred, and a mistake costs one
language's tooling rather than the editor. They are still `relevant`-verified rather than
`fast`-verified, because `tests/run-tests.el` checks every leader binding in every module
for `commandp` and for anonymous lambdas — and that check needs the packages loaded.

## 4. Tests that cover more than one module

These live in `tests/run-tests.el` and fire for **any** module change, which is why most
rows say `relevant`:

| Test | What it protects |
|---|---|
| `rata-test-keybindings-no-lambdas` | every `rata-leader` binding is a named command, not a lambda |
| `rata-test-keybindings-all-commandp` | every bound symbol actually satisfies `commandp` after load |
| `rata-test-no-failed-modules` | `rata--failed-modules` is empty — nothing silently failed to load |
| `rata-test-no-littering-backup-redirect` | backups do not land in the repo |
| `rata-test-no-littering-auto-save-redirect` | auto-saves do not land in the repo |
| `rata-test-yas-snippet-dirs-exist` | every `yas-snippet-dirs` entry resolves to a real directory (added at ARE bootstrap, see [FAIL-0002](../memory/failures/FAIL-0002.md)) |
| `rata-test-init-loads-every-module` | every `lisp/init-*.el` is either loaded by `init.el` or on the known-unloaded list (added at ARE bootstrap, see [FAIL-0006](../memory/failures/FAIL-0006.md)) |
