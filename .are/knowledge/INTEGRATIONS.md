# External integrations

Source: `lisp/*.el`, `justfile` (`install-deps`), `feeds.org`. Confidence: HIGH for what
is configured; **LOW for what is actually reachable** — none of it is verified at test time.

Nothing in `tests/` contacts any of these. Every row is a runtime dependency that no
verification level exercises. That is the single biggest coverage gap in this repository,
and it is largely unavoidable: the alternative is tests that need the operator's network,
credentials and a homelab.

---

## 1. Network services

| Service | Endpoint | Used by | Auth | Notes |
|---|---|---|---|---|
| Anthropic API, via the `claude` CLI | CLI-managed | `init-claude-loop.el` | the CLI's own login | metered spend; see [CLAUDE_LOOP.md](CLAUDE_LOOP.md) |
| Claude Code over ACP | `claude-code-acp` binary | `init-llm.el` (`agent-shell`) | web login | AUR package on Arch; not present on this Ubuntu host |
| Ollama (local models) | `localhost:11434` | `init-llm.el` (`gptel`, `ellama`, `aidermacs`) | none | local only; models `deepseek-coder`, `mistral`, `nomic-embed-text` |
| Khoj (self-hosted) | `http://khoj.homelab.local` | `init-khoj.el` | none configured | **indexes `~/workspace/second-brain/org-roam/`** — sends the operator's notes to the homelab host |
| Snowflake | `<rata-sql-snowflake-account>.snowflakecomputing.com` over JDBC, set in `local.el` | `init-sql.el` | SSO, `authenticator=externalbrowser` | corporate. nil in the tracked sources since D-012, so `SPC a d s` refuses to build a URI until `local.el` exists; see [SECRETS_AND_SENSITIVE_DATA.md](SECRETS_AND_SENSITIVE_DATA.md) |
| GitHub | api.github.com | `init-dev.el` (`forge`) | `~/.authinfo.gpg`, `USER^forge` | |
| Jira REST API | `rata-jira-base-url`, set in the gitignored `local.el` | `init-jira.el` (`jira.el`) | `~/.authinfo.gpg`, `machine <instance> login <email> port https` | corporate. Unset by default, so the module loads inert. Cloud API token or on-prem PAT (`jira-token-is-personal-access-token`) |
| Libera.Chat IRC | port 6697, TLS | `init-irc.el` (`circe`) | SASL password from `auth-source` | nick `celsuss` |
| QuakeNet IRC | port 6667, **no TLS** | `init-irc.el` | none | plaintext by protocol choice |
| Hugo dev server | `localhost:1313` | `init-org.el` | none | `start-process "hugo"` |
| reveal.js CDN | `cdn.jsdelivr.net/npm/reveal.js@4.6.1` | `init-present.el` | none | `rata-reveal-install-local` clones a local copy instead |
| reveal.js repo | `github.com/hakimel/reveal.js.git` | `init-present.el` | none | on-demand clone |
| RSS/Atom feeds | 93 URLs | `init-elfeed.el` + `feeds.org` | none | auto-refreshed every 30 min |
| tree-sitter grammar repos | 10 GitHub repos | `init-lang.el` | none | `just install-grammars` **downloads and compiles C** |
| Maven Central | via Leiningen | `init-sql.el` | none | resolves `snowflake-jdbc` 3.28.0 into `~/.m2` on first connect |
| elpaca package sources | 132 declared, 197 built (incl. transitive) | `init-pkg.el` / every module | none | see §3 |

**The Jira row is the one most likely to rot, and the reason is not in this repo.**
Atlassian retired the old JQL search endpoints on Cloud, so an Emacs Jira client is alive
or dead according to which endpoint its source calls — not according to its star count.
Verified in the installed build: `elpaca/builds/jira/jira-api.el:244-270` probes
`search/jql` first and caches the answer in `jira-search-endpoint`, falling back to
`search` only for instances too old to know it. That fallback is why `jira-api-version 2`
still works on-premise. Packages pinned to `rest/api/2/search` — `jiralib2`, and therefore
`ejira` — are what stopped working on Cloud, and that, not maintenance activity alone, is
why they were rejected in D-011. If `SPC J j` ever returns nothing, read that probe before
suspecting credentials.

## 2. External binaries

Assumed on `PATH`, declared in `justfile install-deps` (Arch-only, never run on this host):

- **Core:** `git`, `ripgrep`, `fd`, `enchant` (jinx spellcheck), `shfmt`, `editorconfig`
- **Language servers:** `pyright`, `gopls`, `rust-analyzer` (rustup nightly), `terraform-ls`
- **Formatters:** `black`, `prettier` (apheleia drives these; lsp formatting is disabled)
- **Tools:** `kubectl` (kubel), `docker`, `hugo`, `delve` (dap-go), `pytest`, `go-tools`, `gomodifytags`
- **SQL:** `jdk-openjdk`, `leiningen` — ejc-sql drives JDBC through a Clojure nREPL
- **LaTeX:** `texlive-*` for org math preview (`dvisvgm`)
- **Agents:** `claude` (claude-loop), `claude-code-acp` (agent-shell)

A missing binary degrades one feature; it does not break startup, because every consumer
is deferred. `just batch` and `just test-ert` therefore pass with all of them absent —
which is exactly why they prove nothing about integrations.

## 3. Supply chain

`elpaca` clones every package from upstream git at first run and byte-compiles it locally.
Verified counts: **132 `use-package` declarations** across `lisp/`, **197 built package
directories** under `elpaca/builds/` (the difference is transitive dependencies).

There is **no lockfile committed.** `just lock` and `just update` write to
`var/elpaca-lock.el`, and `.gitignore:44` (`/var/`) excludes it; the file does not currently
exist on this machine either. Consequence: package versions are whatever upstream `HEAD` was
on the day each machine first installed, two checkouts of this repo will not agree, and a
`just clean` followed by `just run` can produce a different configuration than the one that
was working. Reproducibility is by convention only. `SPEC.md` §3 claims the lockfile is
"DONE (justfile targets added)" — the targets exist, the committed lockfile does not.

This is a known, accepted trade-off, not an oversight — see [../memory/DECISIONS.md](../memory/DECISIONS.md).

## 4. Verification stance

| Claim | Status |
|---|---|
| The configuration for each integration is syntactically valid and loads | PASS via `just test-ert` |
| Every leader binding for these packages resolves to a real command | PASS via `rata-test-keybindings-all-commandp` |
| Any of these services is reachable, authenticating, or returning what the config expects | **NOT TESTED** — requires the operator's network and credentials |
