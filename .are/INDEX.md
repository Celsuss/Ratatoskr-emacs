# ARE INDEX — Ratatoskr-emacs

Entry point for Autonomous Reliability Engineering in this repository.
Read this first. Follow the links; do not load the whole knowledge base.

- **How to operate ARE here:** [SYSTEM.md](SYSTEM.md)
- **Machine-readable config:** [config.yaml](config.yaml)
- **Task context for the change you are making:** run `just are-context`, then read
  [generated/CURRENT_CONTEXT.md](generated/CURRENT_CONTEXT.md)

---

## 1. What this system is

A personal GNU Emacs configuration, written entirely in Emacs Lisp, loaded from
`~/.config/emacs`. It is a **desktop editor configuration**, not a service.

| Question | Answer | Source |
|---|---|---|
| Language | Emacs Lisp (+ bash for tooling) | repo contents |
| Size | 36 modules under `lisp/`, ~5.2k lines of Elisp | `wc -l lisp/*.el init.el early-init.el` |
| Package manager | `elpaca`, bootstrapped in `init.el`; `package.el` disabled in `early-init.el` | `init.el`, `early-init.el` |
| Task runner | `just` (`justfile`) | `justfile` |
| Tests | ERT (`tests/run-tests.el`), bespoke e2e harness (`tests/claude-loop-e2e.el`) | `tests/` |
| CI/CD | **none** — no `.github/`, no `.gitlab-ci.yml` | verified absent |
| Deployment | **none** — it *is* the deployed artifact; `git pull` is the deploy | repo structure |
| Server / backend / HTTP API | **none** | verified absent |
| Database | **none owned.** A SQL *client* (ejc-sql → Snowflake) is configured | `lisp/init-sql.el` |
| Authentication / authorization | **no application auth.** Credentials are *consumed* via `auth-source` | [knowledge/SECRETS_AND_SENSITIVE_DATA.md](knowledge/SECRETS_AND_SENSITIVE_DATA.md) |
| User roles | **none.** One human operator. The nearest analogue is the *trust boundary* between that operator and the headless agent in `init-claude-loop.el` | [knowledge/CLAUDE_LOOP.md](knowledge/CLAUDE_LOOP.md) |
| Financial functionality | **none.** The nearest analogue is metered LLM API spend | [rules/SAFETY_RULES.md](rules/SAFETY_RULES.md) |
| Background jobs | Emacs timers only (elfeed 30-min refresh, gcmh, super-save idle, claude-loop timeouts) | [knowledge/ARCHITECTURE.md](knowledge/ARCHITECTURE.md) |

Categories from the generic ARE template that **do not exist here** (roles, HTTP API
map, migrations, webhooks, payments, infra, staging/prod) have no knowledge file on
purpose. Do not create them speculatively.

## 2. Knowledge base

| Read this | When your change touches |
|---|---|
| [knowledge/ARCHITECTURE.md](knowledge/ARCHITECTURE.md) | startup order, module loading, `init.el`, `early-init.el`, timers |
| [knowledge/MODULES.md](knowledge/MODULES.md) | **any** `lisp/` file — this is the path → area → risk → tests map |
| [knowledge/ENVIRONMENTS.md](knowledge/ENVIRONMENTS.md) | anything that must work headless, in a terminal, or in the daemon |
| [knowledge/CLAUDE_LOOP.md](knowledge/CLAUDE_LOOP.md) | `lisp/init-claude-loop.el`, autonomous agent execution, its tests |
| [knowledge/INTEGRATIONS.md](knowledge/INTEGRATIONS.md) | external CLIs, network services, language servers |
| [knowledge/SECRETS_AND_SENSITIVE_DATA.md](knowledge/SECRETS_AND_SENSITIVE_DATA.md) | credentials, `auth-source`, Snowflake, org-roam notes, anything committed |
| [knowledge/TESTING_STRATEGY.md](knowledge/TESTING_STRATEGY.md) | choosing a verification level; what each command does *not* prove |

**Conventions are not duplicated here.** `AGENTS.md` at the repo root is the
authoritative style/architecture guide and is actively maintained. ARE points at it.

## 3. Rules

| File | Purpose |
|---|---|
| [rules/RISK_RULES.md](rules/RISK_RULES.md) | classify a change LOW / MEDIUM / HIGH / CRITICAL |
| [rules/VERIFICATION_RULES.md](rules/VERIFICATION_RULES.md) | required verification depth per risk tier |
| [rules/SAFETY_RULES.md](rules/SAFETY_RULES.md) | destructive operations, secrets, API spend, what needs approval |

## 4. Memory

| File | Purpose |
|---|---|
| [memory/FAILURE_INDEX.md](memory/FAILURE_INDEX.md) | compact index of every recorded failure |
| [memory/failures/](memory/failures/) | one record per failure |
| [memory/LESSONS.md](memory/LESSONS.md) | patterns that generalise beyond a single failure |
| [memory/DECISIONS.md](memory/DECISIONS.md) | decisions worth not re-litigating |

## 5. Verification commands

All are existing `just` targets unless marked NEW. Measured on this machine.

| Level | Command | Wall time | Needs packages? |
|---|---|---|---|
| L1 fast | `just are-verify fast` (NEW) → `lint` + `test-claude-loop` + ARE map check | ~4 s | no |
| L2 relevant | `just are-verify relevant` (NEW) → L1 + `compile` + `test-ert` | ~2 min | yes |
| L3 full | `just are-verify full` (NEW) → `just test` + `test-claude-loop` + `are-audit` | ~3 min | yes |
| audit | `just are-audit` (NEW) — repo-wide checks, wider than the diff | ~1 s | no |
| context | `just are-context` (NEW) — regenerate `generated/CURRENT_CONTEXT.md` | <1 s | no |

Underlying project targets: `just lint`, `just compile`, `just batch`, `just test-ert`,
`just test-claude-loop`, `just test`. See [knowledge/TESTING_STRATEGY.md](knowledge/TESTING_STRATEGY.md)
for what each one actually proves.

## 6. Known risks (live)

Ranked. Full detail in the linked records.

1. **Two checkouts of this repo exist and the docs point at the stale one.**
   `~/.config/emacs` is live (branch `dev`); `~/workspace/Ratatoskr-emacs` is 4 commits
   behind. `README.org`, `AGENTS.md` and `rata-dashboard-git-repos` all name the stale
   path. → [FAIL-0001](memory/failures/FAIL-0001.md), [knowledge/ENVIRONMENTS.md](knowledge/ENVIRONMENTS.md)
2. **`just compile` cannot catch semantic errors.** Modules are byte-compiled with no
   package on `load-path`, so every `use-package` body compiles blind and ~130
   "Cannot load" lines are expected. It proves syntax only, and it exits 0 regardless.
   → [FAIL-0003](memory/failures/FAIL-0003.md), [knowledge/TESTING_STRATEGY.md](knowledge/TESTING_STRATEGY.md)
3. **The `claude-loop` e2e suite is excluded from `just test`,** so the largest and only
   stateful module (1573 lines) is outside the pre-commit gate.
   → [FAIL-0004](memory/failures/FAIL-0004.md)
4. **`.githooks/pre-commit` is not installed** (`core.hooksPath` unset), so nothing gates
   commits today. Fix is one command: `just install-hooks`. → [FAIL-0005](memory/failures/FAIL-0005.md)
5. **Corporate identifiers are committed** in `lisp/init-sql.el` (work email, Snowflake
   account/role/warehouse/database/schema) in a repo with a public GitHub remote. No
   secret is exposed; SSO is used. → [knowledge/SECRETS_AND_SENSITIVE_DATA.md](knowledge/SECRETS_AND_SENSITIVE_DATA.md)
6. **`SPEC.md` (2408 lines) has drifted** from the implementation and is the largest
   token trap in the repo. Treat it as historical intent, not truth.
   → [memory/DECISIONS.md](memory/DECISIONS.md)

## 7. Failure history

See [memory/FAILURE_INDEX.md](memory/FAILURE_INDEX.md). At bootstrap: 6 records,
all pre-existing, none introduced by ARE.
