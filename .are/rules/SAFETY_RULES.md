# Safety rules

There is no production system, no customer data and no money in this repository. What
there *is*: an editor the operator depends on daily, credentials on the machine, notes
that are not backed up by anything here, live corporate infrastructure one keybinding
away, and an agent that edits files unattended. These rules cover those.

---

## 1. Never do autonomously — explain, propose, and ask first

| Operation | Why |
|---|---|
| `just clean` / `just reset` | deletes `elpaca/`, `eln-cache/`, `elpa/`, `auto-save-list/`, `transient/`, **and `custom.el` and `history`**. The package tree is minutes to rebuild and rebuilds at *current* upstream HEAD, so the config that comes back is not the config that went away (no committed lockfile). `custom.el` is not recoverable |
| `just update` | `elpaca-update-all` moves ~197 packages to upstream HEAD in one step |
| `git commit`, `git push`, branch or history operations | this is the operator's dotfiles repo with a public remote. Committing is theirs to trigger |
| Rewriting history to remove the `init-sql.el` identifiers | see [../knowledge/SECRETS_AND_SENSITIVE_DATA.md](../knowledge/SECRETS_AND_SENSITIVE_DATA.md) §2 — needs a rotation decision too |
| Touching `~/.authinfo.gpg` or `~/.ansible-vault-pass` | credential stores. Read *about* them; never read, write, move or print them |
| Writing anywhere under `~/workspace/second-brain/` | the operator's notes. Nothing in `tests/` has a fixture for them; a bad path expression there loses real work |
| Deleting or moving `var/` or `etc/` | live editor state: recentf, history, persp layouts, elfeed database, SQL scratch |
| `terraform apply`, `terraform destroy`, `kubectl` mutations, `docker` prune | real infrastructure. See §2 |
| Running the claude-loop against another repository | it edits files there with `acceptEdits` |
| Adding `--dangerously-skip-permissions` or widening `--permission-mode` | removes the only boundary the loop has |
| Deleting untracked files you did not create | they may be the operator's work in progress |

## 2. Live infrastructure reachable from a keybinding

`lisp/init-terraform.el` binds `SPC m T a` → `rata-terraform-apply` → `compile "terraform
apply"`, one key away from `SPC m T p` (plan). `lisp/init-k8s.el` binds `kubel`, whose own
buffer offers pod deletion.

Today `terraform apply` under `compile` has no TTY, so terraform's interactive approval
prompt cannot be answered from that buffer — the command should fail rather than apply.
**This is inference from how `compile` works, NOT TESTED, and must never be tested against
real infrastructure.** Treat it as a near-miss, not a safeguard.

Hard rules:

- **Never add `-auto-approve`, `-force`, `--force`, `-y`, or `--yes`** to any `compile`,
  `shell-command` or `start-process` string in this repository. `scripts/are-audit.sh`
  checks for exactly this and fails the build if one appears.
- Never invoke `rata-terraform-apply`, `terraform destroy`, or a mutating `kubectl` while
  verifying anything. Reading a plan is fine; applying is not.
- If a change must add a destructive command, it must prompt with `yes-or-no-p` **inside
  Emacs**, before the subprocess starts, and it is CRITICAL risk.

## 3. Secrets

- Credentials come from `auth-source` (`~/.authinfo.gpg`) or a vault-password file. Never
  inline one, never add one to `custom.el`, never echo one into a buffer or a log.
- Before relying on any new file reaching version control, run
  `git check-ignore -v --no-index <path>`. `.gitignore` has live traps
  (`CONVENTIONS.md`, `docs/*`, `AGENTS.md`).
- Before committing, check the diff for identity: emails, account identifiers, warehouse
  and schema names, hostnames, nicks. The remote is public.
- `*claude-loop*`, `*Messages*` and `*ejc-sql-output*` can all hold sensitive content.
  Do not paste them wholesale into reports or commit messages.

## 4. The claude-loop, operationally

- Set `rata-claude-loop-task-budget-usd` before any unattended run. The default is `nil`,
  i.e. unbounded. This is the only metered-spend surface in the repo.
- `rata-claude-loop-verify-command` is arbitrary shell run unattended, with no
  confirmation. It must be non-destructive and it must be a check that fails when the work
  is wrong.
- Never point the loop at a repository with uncommitted work you cannot afford to lose;
  it edits under `acceptEdits`.
- Use `rata-claude-loop-status` / `--wedged-p` to inspect a stuck loop, and
  `rata-claude-loop-stop` to end it. Do not `kill -9` the child — the epoch and grace-period
  machinery exists so that a clean stop leaves nothing behind.

## 5. Degrading gracefully is the house style — preserve it

`rata-load-module` catches per-module failures so one broken module cannot cost the
operator their editor. Every consumer of an external binary is deferred so a missing
binary costs one feature, not startup. Do not "simplify" either pattern into something
that fails hard at startup.

The corollary is a verification duty, not a licence: because failures are swallowed, they
must be asserted against. See [VERIFICATION_RULES.md](VERIFICATION_RULES.md) §2.3.
