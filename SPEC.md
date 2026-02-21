# Ratatoskr Emacs — Configuration Spec

> Status: Draft v1 — 2026-02-21
> Scope: Full build-out from current skeleton to production-ready config.

---

## 1. Goals & Constraints

- **Sub-1-second cold startup** via daemon mode (`emacsclient`). All non-critical packages deferred.
- **Evil-first**: Every workflow reachable from normal state with `SPC` leader. No Emacs-style `C-x`
  muscle memory required.
- **Spacemacs mnemonics** preserved where possible.
- **Apheleia owns formatting** — lsp-mode format-on-save disabled everywhere.
- **No file-tree sidebar** — navigation via dired, consult, and projectile.
- **LLM-flexible** — config should make it easy to try new tools. Not locked to one.

---

## 2. Final Module Load Order

```
early-init.el
init.el
  ├── init-pkg        (elpaca bootstrap)
  ├── init-system     (no-littering, exec-path-from-shell)
  ├── init-ui         (theme, modeline, icons, which-key)
  ├── init-evil       (evil, general, undo-fu, surround, commenter, avy, winum)
  ├── init-completion (vertico stack + corfu stack)
  ├── init-dev        (lsp, dap, flycheck, apheleia, magit, forge, vterm, direnv)
  ├── init-lang       (rustic, go-mode, pyvenv, dockerfile, terraform, just, docker, markdown)
  ├── init-snippets   (yasnippet + community library + yatemplate)
  ├── init-llm        (gptel, ellama, aidermacs)
  ├── init-mcp        (mcp, mcp-server — experimental)
  └── init-org        (extend existing: org-modern, org-appear, consult-org-roam, org-roam-ui)
```

---

## 3. Package Manager Migration: `package.el` → `elpaca`

### Decision
Migrate fully to elpaca. Remove `init-pkg.el` contents, replace with elpaca bootstrap.

### Elpaca Bootstrap Strategy

`early-init.el` is the right place for the elpaca bootstrap snippet (before any package loads).
`init-pkg.el` becomes thin — just `(elpaca-use-package-mode)` and `(setq use-package-always-ensure t)`.

### Load-Order Problem with Daemon Mode

Elpaca installs packages asynchronously. On first run (no packages installed), the daemon
start will process the install queue before completing. **Strategy:**

1. Place `(elpaca-wait)` **after** `general.el` and `evil` are declared in `init-evil.el`.
   This ensures `rata-leader` is defined synchronously before any module calls it.
2. Accept that the **very first** `emacs --daemon` after a clean install will be slow (all
   packages download). Subsequent daemon starts are fast.
3. Provide a `just install` target that runs `emacs --daemon` once, then checks `emacsclient
   --eval "(elpaca-finished-p)"` to confirm.

### Keybinding Load-Order Rule (enforced across all modules)

**Every module that defines keybindings must:**
```elisp
(use-package some-package
  :after general   ; <- always
  :config
  (rata-leader ...))
```
Never call `rata-leader` in `:init`. This prevents the race condition that exists in the
current `init-org.el`.

---

## 4. Module Specs

### 4.1 `init-system.el` (NEW — loads second)

**Packages:** `no-littering`, `exec-path-from-shell`

**Responsibilities:**
- `no-littering` must be loaded before any other package writes to `~/.emacs.d`. Redirects
  auto-saves to `var/`, backups to `var/backup/`.
- `exec-path-from-shell` copies `$PATH`, `$GOPATH`, `$CARGO_HOME`, `$VIRTUAL_ENV` from the
  login shell into Emacs. Critical for LSP server discovery when running as daemon.

**Config sketch:**
```elisp
(use-package no-littering :demand t)

(use-package exec-path-from-shell
  :demand t
  :config
  (when (daemonp)
    (exec-path-from-shell-initialize)))
```

### 4.2 `init-ui.el` (EXTEND existing)

**New packages:** `doom-modeline`, `nerd-icons`

**Additions:**
- `nerd-icons`: `:demand t` since doom-modeline and nerd-icons-corfu both depend on it.
  Document that `M-x nerd-icons-install-fonts` must be run once after first install.
- `doom-modeline`: Shows git branch, LSP connection status, flycheck diagnostic counts,
  buffer modification state. Enable `doom-modeline-mode`.

**Existing config stays:** gruvbox-dark-medium, relative line numbers, which-key (0.3s).

### 4.3 `init-evil.el` (EXTEND existing)

**New packages:** `undo-fu`, `evil-surround`, `evil-nerd-commenter`, `avy`

**Changes to existing:**
- Fix keybinding ordering: wrap all `rata-leader` calls in `:after general` + `:config`.
- Add `(elpaca-wait)` after general + evil declarations.
- Move `consult-git-grep` from `SPC g g` to `SPC s g` (conflict resolution — see §5).

**New package configs:**

```elisp
;; undo-fu: better undo for evil
(use-package undo-fu
  :after evil
  :config
  (setq evil-undo-system 'undo-fu))

;; evil-surround: cs, ys, ds
(use-package evil-surround
  :after evil
  :config (global-evil-surround-mode 1))

;; evil-nerd-commenter: gcc to comment line
(use-package evil-nerd-commenter
  :after (evil general)
  :config
  (rata-leader
    :states '(normal visual)
    ";" '(evilnc-comment-or-uncomment-lines :which-key "comment")))

;; avy: jump to visible char
(use-package avy
  :after general
  :config
  (rata-leader
    :states '(normal visual)
    "jc" '(avy-goto-char-2 :which-key "jump to char")
    "jw" '(avy-goto-word-0 :which-key "jump to word")
    "jn" '(avy-goto-line   :which-key "jump to line")))
```

### 4.4 `init-completion.el` (EXTEND existing)

**New packages:** `corfu`, `cape`, `nerd-icons-corfu`

**Corfu config:**
- Auto-popup after 1 char, 0.2s delay.
- `global-corfu-mode t`
- Wire to lsp-mode: `(setq lsp-completion-provider :none)` and add `cape-capf-buster` to
  suppress duplicate candidates.
- `corfu-history-mode` for sorting by frequency.

**cape config:**
- Compose cape functions in `completion-at-point-functions`:
  `(cape-capf-super #'lsp-completion-at-point #'cape-file #'cape-dabbrev)`

**nerd-icons-corfu:**
```elisp
(use-package nerd-icons-corfu
  :after (corfu nerd-icons)
  :config
  (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))
```

**Embark keybindings** (currently commented out): wire up `C-.` → `embark-act`,
`C-;` → `embark-export` in `vertico-map`. These should work once general is loaded.

### 4.5 `init-dev.el` (NEW)

**Packages:** `lsp-mode`, `lsp-ui`, `flycheck`, `dap-mode`, `apheleia`, `magit`, `forge`,
`vterm`, `direnv`

#### LSP-mode
- `lsp-deferred` hooked on all major modes (configured per-lang in `init-lang.el`).
- `(setq lsp-prefer-flymake nil)` — use flycheck instead.
- Disable lsp format-on-save: `(setq lsp-enable-on-type-formatting nil)`
  and `(setq lsp-before-save-edits nil)`.
- `lsp-enable-file-watchers nil` for large repos (can be enabled per-project).

```
SPC l   -> :which-key "lsp"
SPC l d -> lsp-find-definition
SPC l r -> lsp-find-references
SPC l n -> lsp-rename
SPC l a -> lsp-execute-code-action
SPC l f -> lsp-format-buffer  (manual, apheleia handles save)
SPC l i -> lsp-find-implementation
SPC l t -> lsp-find-type-definition
SPC l s -> lsp-workspace-restart
SPC l l -> lsp  (manually start LSP)
```

#### lsp-ui
- Full UI enabled: `lsp-ui-doc-enable t`, `lsp-ui-sideline-enable t`.
- Doc popup on hover: `lsp-ui-doc-show-with-cursor t`.
- Sideline shows diagnostics and code actions.

#### flycheck
- `global-flycheck-mode t`.
- `(setq flycheck-display-errors-delay 0.3)`.
- SPC e bindings already wired (`consult-flymake` → should be `consult-flycheck` or keep
  flymake for SPC e l; document the distinction).

  **Note:** `consult-flycheck` is a separate package. Either add it or keep
  `consult-flymake` for the SPC e l binding (flymake and flycheck can coexist —
  lsp-mode will use flycheck, flymake stays for non-LSP buffers).

#### apheleia
```elisp
(use-package apheleia
  :config
  (apheleia-global-mode t)
  ;; Ensure LSP format-on-save is disabled (belt + suspenders)
  (setq lsp-enable-on-type-formatting nil))
```
Apheleia has built-in formatters for rustfmt, gofmt, black/ruff, shfmt, prettier.
Per-language overrides go in `init-lang.el`.

#### magit + forge
```
SPC g   -> :which-key "git"
SPC g s -> magit-status
SPC g g -> consult-git-grep  (moved from SPC g g conflict)
SPC g b -> magit-blame
SPC g l -> magit-log
SPC g f -> magit-find-file
SPC g d -> magit-diff-buffer-file
SPC g F -> forge-list-pullreqs
SPC g I -> forge-list-issues
```
- Forge requires `~/.authinfo.gpg` with GitHub token. Document setup step.

#### vterm
- `SPC t t` → `vterm` (toggle/open terminal).
- `vterm-toggle` package optional but convenient.

#### direnv
- `(direnv-mode)` globally — loads `.envrc` when visiting a directory.
- Required for Python venvs, Go workspaces, Rust toolchain pins.

### 4.6 `init-lang.el` (NEW)

**Packages:** `rustic`, `go-mode`, `pyvenv`, `dockerfile-mode`, `terraform-mode`,
`just-mode`, `docker`, `markdown-mode`

**Pattern per language:**
```elisp
(use-package go-mode
  :hook (go-mode . lsp-deferred)
  :config
  ;; apheleia handles gofmt — no need for before-save-hook manually
  (setq go-tab-width 4))
```

**Rust (rustic):**
- rustic replaces rust-mode. It has built-in lsp-mode integration.
- `(setq rustic-lsp-client 'lsp-mode)`.
- rust-analyzer server must be installed (`rustup component add rust-analyzer`).

**Python (pyvenv):**
- `(pyvenv-mode t)` globally.
- `direnv` handles automatic venv activation from `.envrc`.
- Hook: `(add-hook 'python-mode-hook #'lsp-deferred)`.
- Document pyright vs pylsp decision (pyright recommended for lsp-mode).

**Go:**
- gopls server: `go install golang.org/x/tools/gopls@latest`.
- apheleia uses `gofmt` by default; override to `goimports` if preferred.

**DAP mode:**
```
SPC d   -> :which-key "debug"
SPC d d -> dap-debug
SPC d n -> dap-next
SPC d i -> dap-step-in
SPC d o -> dap-step-out
SPC d c -> dap-continue
SPC d b -> dap-breakpoint-toggle
SPC d B -> dap-breakpoint-condition
SPC d r -> dap-ui-repl
SPC d q -> dap-disconnect
```
- `dap-auto-configure-mode t` for automatic adapter setup.
- Per-language adapters: codelldb (Rust), delve (Go), debugpy (Python).

### 4.7 `init-snippets.el` (NEW)

**Packages:** `yasnippet`, `yasnippet-snippets`, `yatemplate`

```elisp
(use-package yasnippet
  :config (yas-global-mode 1))

(use-package yasnippet-snippets
  :after yasnippet)

(use-package yatemplate
  :after yasnippet
  :config (yatemplate-fill-alist))
```

- Store custom snippets in `~/.config/emacs-from-scratch/snippets/`.
- `SPC i s` → `yas-insert-snippet`.
- `SPC i n` → `yas-new-snippet`.

### 4.8 `init-llm.el` (NEW)

**Packages:** `gptel`, `ellama`, `aidermacs`

**Strategy:** Ollama for gptel/ellama (local), Anthropic Claude for aidermacs (agentic).

#### gptel
```elisp
(use-package gptel
  :after general
  :config
  ;; Primary backend: Ollama local
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :models '("deepseek-coder:latest" "mistral:latest")
    :stream t)
  (setq gptel-default-mode 'org-mode)
  (rata-leader
    :states '(normal visual insert emacs)
    "ai"   '(:ignore t :which-key "AI")
    "aig"  '(gptel           :which-key "gptel chat")
    "ais"  '(gptel-send      :which-key "send to gptel")
    "air"  '(gptel-rewrite   :which-key "rewrite with gptel")
    "aim"  '(gptel-menu      :which-key "gptel menu")))
```

#### ellama
```elisp
(use-package ellama
  :after general
  :config
  (setq ellama-provider
        (make-llm-ollama :chat-model "mistral:latest" :embedding-model "nomic-embed-text"))
  (rata-leader
    :states '(normal visual insert emacs)
    "aic"  '(ellama-chat         :which-key "ellama chat")
    "aik"  '(ellama-ask-about    :which-key "ask about region")
    "aie"  '(ellama-enhance-code :which-key "enhance code")))
```

#### aidermacs
```elisp
(use-package aidermacs
  :after general
  :config
  ;; Use Claude Sonnet for agentic sessions
  (setq aidermacs-default-model "claude-sonnet-4-5")
  (rata-leader
    :states '(normal visual insert emacs)
    "aiA"  '(aidermacs-transient-menu :which-key "aider menu")
    "aio"  '(aidermacs-open           :which-key "open aider")))
```

**API key management:** Keys should live in `~/.authinfo.gpg` or be set via `auth-source`.
Do not hardcode in config.

### 4.9 `init-mcp.el` (NEW — Experimental)

**Packages:** `mcp`, `mcp-server-emacs` (or equivalent)

**Use case:** Expose org-roam nodes + current Emacs buffers to external AI tools (Claude
Code, gptel with tool use). Full context: notes + buffers + eval.

**Status:** Mark as experimental in init.el with a comment. The MCP Emacs ecosystem is
rapidly changing. Config should be easy to disable (`(require 'init-mcp)` line in init.el
commented out until stable).

```
SPC a m   -> :which-key "MCP"
SPC a m s -> mcp-server-start
SPC a m S -> mcp-server-stop
SPC a m l -> mcp-list-resources
```

### 4.10 `init-org.el` (EXTEND existing)

**New packages:** `org-modern`, `org-appear`, `consult-org-roam`, `org-roam-ui`

**Fix:** Move `rata-leader` calls into `:after general` + `:config` blocks.

#### org-modern
```elisp
(use-package org-modern
  :after org
  :config
  (global-org-modern-mode)
  (setq org-modern-agenda t))  ; style agenda buffers too
```

#### org-appear
```elisp
(use-package org-appear
  :after org
  :hook (org-mode . org-appear-mode)
  :config
  (setq org-appear-autolinks t
        org-appear-autosubmarkers t))
```

#### consult-org-roam
```elisp
(use-package consult-org-roam
  :after (org-roam consult)
  :config
  (consult-org-roam-mode 1)
  (rata-leader
    :states '(normal visual insert emacs)
    "ors" '(consult-org-roam-search      :which-key "search roam")
    "orb" '(consult-org-roam-backlinks   :which-key "backlinks consult")
    "orF" '(consult-org-roam-file-find   :which-key "find file consult")))
```
Note: `SPC o r f` stays as `org-roam-node-find` (standard). `SPC o r s` is the new
full-text search via consult-org-roam.

#### org-roam-ui
```elisp
(use-package org-roam-ui
  :after org-roam
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "oru" '(org-roam-ui-mode :which-key "roam graph UI")))
```

#### writegood-mode (EXTEND init-org)
```elisp
(use-package writegood-mode
  :after (org markdown-mode)
  :hook ((org-mode      . writegood-mode)
         (markdown-mode . writegood-mode)))
```

---

## 5. Keybinding Map (Complete)

```
SPC SPC  execute-extended-command

SPC 0-9  winum window selection

SPC a    AI
  SPC a i    (sub-group)
    SPC a i g  gptel chat
    SPC a i s  gptel-send
    SPC a i r  gptel-rewrite
    SPC a i m  gptel-menu
    SPC a i c  ellama-chat
    SPC a i k  ellama-ask-about
    SPC a i e  ellama-enhance-code
    SPC a i A  aidermacs-transient-menu
    SPC a i o  aidermacs-open
  SPC a m    MCP
    SPC a m s  mcp-server-start
    SPC a m S  mcp-server-stop

SPC b    buffers
  SPC b b  consult-buffer
  SPC b B  consult-buffer-other-window
  SPC b k  kill-current-buffer

SPC d    debug (dap-mode)
  SPC d d  dap-debug
  SPC d n  dap-next
  SPC d i  dap-step-in
  SPC d o  dap-step-out
  SPC d c  dap-continue
  SPC d b  dap-breakpoint-toggle
  SPC d B  dap-breakpoint-condition
  SPC d r  dap-ui-repl
  SPC d q  dap-disconnect

SPC e    errors
  SPC e l  consult-flymake (non-LSP) / consult-flycheck (LSP buffers)
  SPC e n  flycheck-next-error
  SPC e p  flycheck-previous-error

SPC f    files
  SPC f f  consult-find
  SPC f r  consult-recent-file
  SPC f s  save-buffer
  SPC f L  consult-locate

SPC g    git
  SPC g s  magit-status
  SPC g g  consult-git-grep      (moved from original SPC g g)
  SPC g b  magit-blame
  SPC g l  magit-log
  SPC g f  magit-find-file
  SPC g d  magit-diff-buffer-file
  SPC g F  forge-list-pullreqs
  SPC g I  forge-list-issues

SPC h    help
  SPC h m  consult-man
  SPC h I  consult-info

SPC i    insert
  SPC i s  yas-insert-snippet
  SPC i n  yas-new-snippet

SPC j    jump
  SPC j c  avy-goto-char-2
  SPC j w  avy-goto-word-0
  SPC j n  avy-goto-line
  SPC j l  consult-line
  SPC j j  consult-imenu
  SPC j J  consult-imenu-multi
  SPC j o  consult-outline

SPC l    lsp
  SPC l d  lsp-find-definition
  SPC l r  lsp-find-references
  SPC l n  lsp-rename
  SPC l a  lsp-execute-code-action
  SPC l f  lsp-format-buffer (manual)
  SPC l i  lsp-find-implementation
  SPC l t  lsp-find-type-definition
  SPC l s  lsp-workspace-restart
  SPC l l  lsp (manual start)

SPC m    mode-specific (local leader alias)
  SPC m m  consult-mode-command

SPC o    org
  SPC o c  org-capture
  SPC o a  org-agenda
  SPC o t  org-todo-list
  SPC o r    org-roam
    SPC o r l  org-roam-buffer-toggle
    SPC o r f  org-roam-node-find        (standard)
    SPC o r s  consult-org-roam-search   (full-text)
    SPC o r F  consult-org-roam-file-find
    SPC o r b  consult-org-roam-backlinks
    SPC o r g  org-roam-graph
    SPC o r i  org-roam-node-insert
    SPC o r c  org-roam-capture
    SPC o r u  org-roam-ui-mode
    SPC o r d    dailies
      SPC o r d c  org-roam-dailies-capture-today

SPC p    project (projectile)
  SPC p p  projectile-switch-project
  SPC p f  consult-projectile-find-file
  SPC p b  consult-project-buffer
  SPC p s  consult-projectile-ripgrep
  SPC p t  projectile-run-project-tests
  SPC p k  projectile-kill-buffers

SPC q    quit
  SPC q r  reload init.el

SPC r    registers
  SPC r r  consult-register
  SPC r L  consult-register-load
  SPC r S  consult-register-store

SPC s    search
  SPC s g  consult-grep
  SPC s r  consult-ripgrep
  SPC s s  consult-line
  SPC s S  consult-line-multi
  SPC s k  consult-keep-lines
  SPC s i  consult-info

SPC t    toggle
  SPC t t  vterm
  SPC t w  writegood-mode (manual toggle when not in org/markdown)

SPC w    windows
  SPC w h  evil-window-left
  SPC w l  evil-window-right
  SPC w k  evil-window-up
  SPC w j  evil-window-down

SPC y    yank
  SPC y y  consult-yank-from-kill-ring

;  evil-nerd-commenter (normal/visual states, no SPC prefix)
```

---

## 6. Implementation Order

Work in this sequence to maintain a working config at every step:

1. **Migrate init-pkg.el to elpaca** — get bootstrapped, verify `just run` works.
2. **Create init-system.el** — add no-littering + exec-path-from-shell.
3. **Fix init-evil.el** — add `elpaca-wait`, fix keybinding ordering, add undo-fu + surround
   + commenter + avy.
4. **Extend init-ui.el** — add doom-modeline + nerd-icons. Run
   `M-x nerd-icons-install-fonts` once.
5. **Extend init-completion.el** — add corfu + cape + nerd-icons-corfu. Wire lsp-mode
   integration (`lsp-completion-provider :none`).
6. **Create init-dev.el** — lsp-mode + lsp-ui + flycheck + apheleia + magit + forge + vterm
   + direnv.
7. **Create init-lang.el** — per-language LSP hooks + DAP adapters.
8. **Create init-snippets.el** — yasnippet + community snippets + yatemplate.
9. **Create init-llm.el** — gptel (Ollama) + ellama (Ollama) + aidermacs (Anthropic).
10. **Extend init-org.el** — fix load-order bugs, add org-modern + org-appear +
    consult-org-roam + org-roam-ui + writegood-mode.
11. **Create init-mcp.el** — experimental, commented out by default in init.el.

---

## 7. Critical Gotchas & Decisions

### elpaca + daemon + load order
- `(elpaca-wait)` is mandatory after general.el and evil declarations. Without it,
  `rata-leader` may not be defined when later modules call it on first-install.
- All keybindings must use `:after general` (or `:after (evil general)`) and live in
  `:config`, never `:init`.

### nerd-icons font install
- One-time manual step after first install: `M-x nerd-icons-install-fonts`.
- Without this, doom-modeline and nerd-icons-corfu show boxes/question marks.
- Add to justfile: `just install-fonts` that opens emacs and calls the function.

### lsp-mode + apheleia conflict
- Set `(setq lsp-enable-on-type-formatting nil)` and disable `lsp-before-save-edits`.
- `(apheleia-global-mode t)` runs apheleia's formatter on every save.
- Do NOT add `before-save-hook` entries that call `lsp-format-buffer` in lang modules.

### corfu + lsp-mode integration
- `(setq lsp-completion-provider :none)` disables company/capf override by lsp-mode.
- Add `cape-capf-buster` to deduplicate candidates from multiple backends.
- `corfu-history-mode` and `savehist` persistence for ranking.

### flycheck + flymake coexistence
- `lsp-prefer-flymake nil` routes lsp diagnostics through flycheck.
- flymake stays active for non-LSP buffers (elisp, etc.).
- `consult-flymake` binding at SPC e l still works for elisp buffers.
- Add `consult-flycheck` package for `SPC e l` in LSP buffers, or accept the split.

### forge auth
- forge requires a GitHub token in `~/.authinfo.gpg`:
  `machine api.github.com login USERNAME^forge password TOKEN`

### magit + jj coexistence
- Use magit for repos not managed with jj (open-source contributions, etc.).
- jj integration in Emacs is nascent; track `jj.el` as a future item.

### projectile vs project.el SPC p bindings
- Current `init-evil.el` uses `consult-project-buffer` and `consult-project-find` (project.el-based).
- These bindings must be replaced with projectile equivalents in step 6.
- `consult-projectile` package required for consult-style projectile commands.

### LLM API keys
- Never hardcode in config. Use `auth-source`:
  ```elisp
  (setq gptel-api-key (auth-source-pick-first-password :host "api.anthropic.com"))
  ```
- Keys in `~/.authinfo.gpg`.

### aidermacs model naming
- aidermacs uses aider's model string format: `"claude-sonnet-4-5"` maps to
  `claude-sonnet-4-5-20251022` internally. Keep updated as models change.

---

## 8. Out of Scope (Explicitly Excluded)

| Item | Reason |
|------|--------|
| `org-auto-tangle` | Config is .el files, not literate org. Not needed. |
| `straight.el` / `package.el` long-term | Replaced by elpaca. |
| File tree sidebar (treemacs/neotree) | Dired + consult is sufficient. |
| `Helm` / `Ivy` / `Company` | Replaced by vertico/consult/corfu stack. |
| `Eglot` | Replaced by lsp-mode for DAP support. |

---

## 9. Out of Scope (Future Work)

| Item | Notes |
|------|-------|
| `jj.el` / Jujutsu UI | No mature Emacs package yet. Watch `https://github.com/bennyandresen/jujutsu.el` |
| `init-mcp.el` stable | Enable once mcp + mcp-server-emacs stabilize. |
| Per-project LSP config | `.dir-locals.el` patterns for LSP roots, env overrides. |
| `org-roam-ql` queries | Already installed, needs keybindings and workflow design. |
| Emacs as MCP server for Claude Code | Depends on mcp-server-emacs maturity. |

---

## 10. PKGS.org Reconciliation

| Package | Decision | In Scope? |
|---------|----------|-----------|
| elpaca | Use this | Yes — replaces package.el |
| evil | Already implemented | Yes |
| evil-collection | Already implemented | Yes |
| general.el | Already implemented | Yes |
| evil-nerd-commenter | Add to init-evil | Yes |
| evil-surround | Add to init-evil | Yes |
| undo-fu | Add to init-evil | Yes |
| Vertico | Already implemented | Yes |
| Consult | Already implemented | Yes |
| Orderless | Already implemented | Yes |
| Marginalia | Already implemented | Yes |
| corfu | Add to init-completion | Yes |
| cape | Add to init-completion | Yes |
| kind-icon | **Replaced by nerd-icons-corfu** | Yes (nerd-icons-corfu) |
| flycheck | Add to init-dev | Yes |
| lsp-mode | Add to init-dev | Yes |
| lsp-ui | Add to init-dev | Yes |
| dap-mode | Add to init-dev | Yes |
| magit | Add to init-dev | Yes |
| forge | Add to init-dev | Yes |
| apheleia | Add to init-dev | Yes |
| rustic | Add to init-lang | Yes |
| go-mode | Add to init-lang | Yes |
| dockerfile-mode | Add to init-lang | Yes |
| terraform-mode | Add to init-lang | Yes |
| just-mode | Add to init-lang | Yes |
| docker | Add to init-lang | Yes |
| pyvenv | Add to init-lang | Yes |
| markdown-mode | Add to init-lang | Yes |
| direnv | Add to init-dev | Yes |
| vterm | Add to init-dev | Yes |
| org mode | Already implemented | Yes |
| org-roam | Already implemented | Yes |
| org-roam-ui | Add to init-org | Yes |
| consult-org-roam | Add to init-org | Yes |
| org-modern | Add to init-org | Yes |
| org-appear | Add to init-org | Yes |
| org-auto-tangle | **Removed from scope** | No |
| org-agenda | Already implemented | Yes |
| org-super-agenda | Already implemented | Yes |
| ellama | Add to init-llm | Yes |
| Gptel | Add to init-llm | Yes |
| aidermacs | Add to init-llm | Yes |
| mcp-server | Add to init-mcp (experimental) | Experimental |
| mcp | Add to init-mcp (experimental) | Experimental |
| claude-code-ide? | **Replaced by aidermacs** | No |
| Emacs Agent Shell? | **Covered by aidermacs** | No |
| ECA Emacs? | Not needed | No |
| no-littering | Add to init-system | Yes |
| exec-path-from-shell | Add to init-system | Yes |
| Writegood-mode | Add to init-org | Yes |
| yatemplate | Add to init-snippets | Yes |
| YASnippet | Add to init-snippets | Yes |
| doom-modeline | Add to init-ui | Yes (not in original PKGS.org — add it) |
| nerd-icons | Add to init-ui | Yes (not in original PKGS.org — add it) |
| projectile | Add to init-dev | Yes (not in original PKGS.org — add it) |
| consult-projectile | Add to init-dev | Yes |
| avy | Add to init-evil | Yes (not in original PKGS.org — add it) |
