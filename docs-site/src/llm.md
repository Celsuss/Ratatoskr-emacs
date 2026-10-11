# LLM tools

gptel, ellama, aidermacs and agent-shell live under `SPC a i`.

## One provider list

The three model tools (gptel, ellama, aidermacs) are configured from a single list, `rata-llm-providers`. Each entry is a plist:

| Key | Meaning |
|-----|---------|
| `:name` | label shown when you switch providers |
| `:protocol` | `ollama`, or `openai` for any OpenAI-compatible chat-completions server such as LiteLLM |
| `:url` | base URL |
| `:models` | list of models; the first is the default |
| `:embedding-model` | optional |
| `:auth-host` | optional; the `~/.authinfo.gpg` host holding the API key |

The tracked default is Ollama on localhost. A work proxy belongs in `local.el` (the template is in `local.el.example`). No API key is stored in either file: an `openai` entry reads its key from `~/.authinfo.gpg` at request time.

gptel and ellama register every entry (switch with `gptel-menu` or `ellama-provider-select`). aidermacs uses the first entry. A malformed entry produces a warning at load naming the entry and the fault.

## agent-shell

Local-leader (`,`) commands in an agent-shell buffer:

| Key | Command |
|-----|---------|
| `R` | restart (clears the session) |
| `S` | permission mode |
| `m` | model |
| `t` | thought level |
| `p` | latest permission prompt |
| `q` | quote region |
| `y` / `c` | copy last output / last code block |
| `e` | compose |
| `a` | fold all |
| `f` | fork |
| `u` | usage |
| `o` | shell ↔ viewport |

See [Agents panel](generated/agents.md) for managing many sessions at once, including one git worktree per task and the prompt library.
