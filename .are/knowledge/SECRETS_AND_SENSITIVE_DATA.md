# Secrets, identity and sensitive data

Source: `lisp/init-system.el`, `init-sql.el`, `init-irc.el`, `init-dev.el`,
`init-ansible.el`, `init-org.el`, `init-khoj.el`, `.gitignore`, `git` inspection.
Confidence: HIGH.

This repository has a **public git remote** (`github.com/Celsuss/Ratatoskr-emacs`).
Everything committed is potentially world-readable. That is the frame for this page.

---

## 1. No secret material is committed — verified

Searched the whole Elisp tree for `password|passwd|secret|api[-_]key|token|credential|
authinfo|netrc`. Every hit is a *reference to* a credential store, never a credential:

| Hit | What it is |
|---|---|
| `init-system.el:42` | `auth-sources '("~/.authinfo.gpg")` — the store, outside the repo |
| `init-system.el:51` | `rata-auth-get` helper, wraps `auth-source-pick-first-password` |
| `init-system.el` (`epa`) | `epg-pinentry-mode 'loopback` so GPG prompts do not freeze Emacs |
| `init-irc.el:75` | SASL password fetched at connect time via `rata-auth-get` |
| `init-dev.el:111` | comment documenting the required `~/.authinfo.gpg` line for `forge` |
| `init-ansible.el:8` | `ansible-vault-password-file "~/.ansible-vault-pass"` — a path, outside the repo |
| `init-sql.el` | Snowflake with `authenticator=externalbrowser`; the comment states no secret lives there, and that is correct |

**Status: PASS.** No key, token or password is in version control.

## 2. Corporate identity *is* committed — MEDIUM, unresolved

`lisp/init-sql.el:8-20` commits, in plain text, on a public remote:

- work email `JENS.LORDEN@TELE2.COM`
- Snowflake account `tele2.eu-west-1`
- role `USER__JENS_DOT_LORDEN_AT_TELE2_DOT_COM`
- warehouse `AIHUB_B2C_LIGHT_WH`
- database `SANDBOX`, schema `JENS_DOT_LORDEN_AT_TELE2_DOT_COM`

None of it authenticates anything on its own — SSO stands in the way. It is
reconnaissance-grade information: an employer, an internal warehouse name, a tenant
region, a working email. Whether that is acceptable is the operator's judgement, not
ARE's, so **this has not been changed.**

If it should be removed, note that removal is not a simple edit: the values are in git
history from commit `0d3eb8a` onward, so it needs history rewriting plus a rotation
decision, and it is a HIGH-risk operation requiring explicit approval
([../rules/SAFETY_RULES.md](../rules/SAFETY_RULES.md)). The low-friction alternative is to
move the six `defvar`s into the already-`.gitignore`d `custom.el`, or into a
`private.el` loaded with `(load … 'noerror)`.

## 3. Operator data reachable from this config

Not in the repo, not covered by any test, and modules here can read or transmit it:

| Data | Path | Who touches it |
|---|---|---|
| org-roam second brain | `~/workspace/second-brain/org-roam/` | `init-org.el` (read/write), `init-present.el` (read + HTML export), `init-khoj.el` (**transmits to `khoj.homelab.local` for indexing**) |
| Hugo site | `~/workspace/second-brain/hugo/` | `init-org.el` (`ox-hugo` export) |
| Credentials | `~/.authinfo.gpg`, `~/.ansible-vault-pass` | `auth-source`, ansible-vault |
| Editor state | `var/`, `etc/` — recentf, history, elfeed db, SQL scratch, persp | `no-littering`; gitignored |
| Buffer contents sent to models | wherever the operator is editing | `init-llm.el` — `gptel`/`ellama`/`aidermacs` all point at **local Ollama**, so this stays on the machine; `init-claude-loop.el` and `agent-shell` send to Anthropic |

`init-present.el` deliberately redirects HTML export **out of** the roam tree
(`rata-reveal-export-dir`) so generated files never land among the notes. Preserve that.

## 4. `.gitignore` traps — verify before creating files

`.gitignore:23-24` lists `AGENTS.md` and `CONVENTIONS.md` under `# LLMs`. `AGENTS.md` is
nonetheless **tracked**, so the rule is dead for it (`git check-ignore --no-index AGENTS.md`
matches; plain `git check-ignore AGENTS.md` does not, because git skips tracked paths).
`CONVENTIONS.md` genuinely is ignored, so a `CONVENTIONS.md` created by a future session
would silently never be committed. `docs/*` is ignored too.

**Rule:** any new file intended for version control must be checked with
`git check-ignore -v --no-index <path>` before it is relied on. `scripts/are-audit.sh`
does this automatically for everything under `.are/`, `scripts/are-*.sh` and `.claude/`.

Verified at bootstrap: every file ARE created is committable.

## 5. Exposure surfaces to keep in mind

| Surface | Concern |
|---|---|
| `*claude-loop*` buffer | renders assistant text and tool arguments; may contain file contents from the task's repo |
| `*Messages*` | `rata-claude-loop--guard` demotes errors here; error strings can carry paths |
| `*ejc-sql-output*` | query results from a corporate warehouse land in an Emacs buffer, popped up by `shackle` |
| `var/sql/snowflake.sql` | persistent scratch file; whatever the operator queried, kept on disk |
| elfeed db | 93 subscribed feeds, i.e. a reading profile |
| `browse-at-remote` | constructs public URLs from local paths |
