# Per-machine configuration

Two gitignored files, two different jobs. Do not merge them.

| File | Written by | Contains |
|------|------------|----------|
| `custom.el` | Emacs Custom, on every `M-x customize` save | faces, safe local variables, theme trust. Never edit by hand. |
| `local.el` | you | per-machine values that must not reach a public remote: instance hostnames, mail address, corporate identity |

A new machine is:

```sh
cp local.el.example local.el
```

then fill in the values. `local.el.example` is committed and is the checklist of everything a fresh checkout can set. `init.el` loads `custom.el`, then `local.el`, before the modules, so a hand-written value beats a stale Custom one.

## Secrets

Tokens and passwords do **not** go in `local.el`. They live in `~/.authinfo.gpg` and are read lazily when first needed, so startup never blocks on GPG. Features that need a secret (OpenAI-compatible LLM proxies, Proton Mail Bridge, Jira) say which `auth-source` entry they read.

## Examples

- Point the LLM tools at a work proxy: set `rata-llm-providers` (see [LLM tools](llm.md)).
- Set your mail address: `rata-mail-address` (see [Mail](mail.md)).
- Set the Jira host: `rata-jira-base-url` (see [Jira](jira.md)).
