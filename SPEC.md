# Ratatoskr Emacs — Configuration Spec

> Status: Draft v3 — 2026-02-21
> Scope: Full build-out from current skeleton to production-ready config.
> Implementation progress tracked per-section with status markers:
> - DONE = fully implemented in code
> - PARTIAL = module exists but missing packages/config from spec
> - TODO = not yet started

---

## 1. Goals & Constraints

- **Sub-1-second cold startup** via daemon mode (`emacsclient`). All non-critical packages deferred.
- **Evil-first**: Every workflow reachable from normal state with `SPC` leader. No Emacs-style `C-x`
  muscle memory required.
- **Spacemacs mnemonics** preserved where possible.
- **Apheleia owns formatting** — lsp-mode format-on-save disabled everywhere.
- **No file-tree sidebar** — navigation via dirvish, consult, and projectile.
- **LLM-flexible** — config should make it easy to try new tools. Not locked to one.
- **Resilient startup** — each module wrapped in `condition-case`; a broken module logs a
  warning but does not prevent the rest of the config from loading.

---

## 2. Final Module Load Order

```
early-init.el          — disables package.el, UI chrome, maxes GC
init.el                — elpaca bootstrap, module loader
  ├── init-pkg         (elpaca use-package defaults)                        ✓ DONE
  ├── init-system      (no-littering, exec-path-from-shell + TODO: shackle, TRAMP, ediff, recentf)
  ├── init-ui          (gruvbox, doom-modeline, nerd-icons, which-key + TODO: rainbow, helpful, golden-ratio)
  ├── init-evil        (evil, general, winum, undo-fu, surround, commenter, avy + TODO: matchit, args, textobj-ts, evil-mc, smartparens)
  ├── init-completion  (vertico, orderless, marginalia, consult, embark, corfu, cape, nerd-icons-corfu + TODO: wgrep)
  ├── init-dev         (lsp, lsp-ui, flycheck, apheleia, magit, forge, vterm, direnv, projectile + TODO: vterm-toggle, dirvish, esup, flyspell)
  ├── init-lang        (rustic, go, python, dockerfile, terraform, just, docker, markdown, dap-mode + TODO: tree-sitter)
  ├── init-snippets    (yasnippet, yasnippet-snippets, yatemplate)          ✓ DONE
  ├── init-llm         (gptel, ellama, aidermacs)                           ✓ DONE
  ├── init-mcp         (mcp — experimental, commented out in init.el)       ✓ DONE
  ├── init-persp       (persp-mode workspaces — NOT YET CREATED)            ✗ TODO
  └── init-org         (org, org-roam, org-super-agenda, org-kanban, org-modern, org-appear, consult-org-roam, org-roam-ui, writegood-mode)  ✓ DONE
```

**Error recovery in init.el — TODO:** Each `(require 'init-xxx)` should be wrapped:
```elisp
(condition-case err
    (require 'init-xxx)
  (error (message "WARNING: Failed to load init-xxx: %s" (error-message-string err))))
```
With `--debug-init`, errors propagate normally for full backtrace.
Currently init.el uses bare `(require ...)` calls without error handling.

---

## 3. Package Manager Migration: `package.el` → `elpaca` — DONE

Elpaca is fully bootstrapped and operational:
- `early-init.el` disables `package-enable-at-startup`.
- `init.el` contains the full elpaca bootstrap snippet + `elpaca-use-package` integration.
- `init-pkg.el` is thin: just `(setq use-package-always-ensure t)`.
- `(elpaca-wait)` is in `init-evil.el` after general + evil declarations.
- All modules use `:after general` + `:config` for keybindings (load-order rule enforced).

### Elpaca Lockfile (Reproducibility) — TODO

Use `elpaca-lock` to generate a lockfile pinning exact package commits. Check the lockfile
into version control. Fresh installs get identical package versions.

- `just lock` → runs `(elpaca-lock)` to regenerate lockfile.
- `just update` → runs `(elpaca-update-all)` then `(elpaca-lock)`.
- Lockfile location: `var/elpaca-lock.el` (managed by no-littering paths).

### Keybinding Load-Order Rule (enforced across all modules) — DONE

**Every module that defines keybindings must:**
```elisp
(use-package some-package
  :after general   ; <- always
  :config
  (rata-leader ...))
```
All modules now follow this rule. The `init-org.el` `:init` bug has been fixed.

---

## 4. Module Specs

### 4.1 `init-system.el` — PARTIAL

**Implemented:** `no-littering`, `exec-path-from-shell`
**TODO:** `shackle`, TRAMP config, ediff config, `recentf-mode`
**Note:** `savehist-mode` currently lives in `init-completion.el` (alongside vertico). Consider
moving to init-system.el or leaving it — either is fine.

**Packages:** `no-littering`, `exec-path-from-shell`, `shackle`

**Responsibilities:**
- `no-littering` must be loaded before any other package writes to `~/.emacs.d`. Redirects
  auto-saves to `var/`, backups to `var/backup/`. **DONE**
- `exec-path-from-shell` copies `$PATH`, `$GOPATH`, `$CARGO_HOME`, `$VIRTUAL_ENV` from the
  login shell into Emacs. Critical for LSP server discovery when running as daemon. **DONE**
- `savehist-mode` for minibuffer history persistence (corfu-history, consult, vertico).
- `recentf-mode` for recent file tracking.
- `shackle` for popup/buffer placement rules.
- TRAMP configuration for SSH + Docker.
- Ediff configuration (side-by-side, same frame).

**Config sketch:**
```elisp
(use-package no-littering :demand t)

(use-package exec-path-from-shell
  :demand t
  :config
  (when (daemonp)
    (exec-path-from-shell-initialize)))

;; Persistence (minimal — no desktop-save-mode)
(savehist-mode 1)
(recentf-mode 1)
(setq recentf-max-saved-items 200)

;; Ediff: side-by-side in same frame, restore windows on quit
(setq ediff-split-window-function #'split-window-horizontally
      ediff-window-setup-function #'ediff-setup-windows-plain)
(add-hook 'ediff-after-quit-hook-internal #'winner-undo)

;; TRAMP
(setq tramp-default-method "ssh")
(with-eval-after-load 'tramp
  ;; Connection caching for performance
  (setq tramp-persistency-file-name
        (expand-file-name "var/tramp" user-emacs-directory))
  ;; Disable problematic features over TRAMP
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path))

;; Disable apheleia + file-watchers over TRAMP (see §7)
(defun rata-tramp-buffer-p ()
  "Return non-nil if current buffer is visiting a remote file."
  (and (buffer-file-name) (file-remote-p (buffer-file-name))))

;; Shackle: rule-based popup placement
(use-package shackle
  :demand t
  :config
  (shackle-mode 1)
  (setq shackle-rules
        '(("*compilation*"    :align below :size 0.3 :popup t)
          ("*vterm*"          :align below :size 0.4 :popup t :select t)
          ("*Help*"           :align right :size 0.4 :popup t :select t)
          ("*helpful*"        :align right :size 0.4 :popup t :select t :regexp t)
          ("*grep*"           :align below :size 0.3 :popup t)
          ("*Flycheck errors*" :align below :size 0.25 :popup t)
          ("*lsp-help*"       :align right :size 0.4 :popup t :select t)
          ("*Messages*"       :align below :size 0.25 :popup t))))
```

### 4.2 `init-ui.el` — PARTIAL

**Implemented:** `gruvbox-theme`, `nerd-icons`, `doom-modeline`, `which-key`, relative line numbers
**TODO:** `rainbow-delimiters`, `helpful`, `golden-ratio` (off by default), change which-key
delay from 0.3s → 0.1s

**Additions remaining:**
- `rainbow-delimiters`: Rainbow-colored parens by nesting depth. Hook on `prog-mode`.
- `helpful`: Better *Help* buffers with source links, callers, and formatting.
- `golden-ratio`: Install but off by default, toggle via `SPC t g`.
- `which-key`: Change delay from 0.3s to **0.1s** for faster popup.

**Existing config stays:** gruvbox-dark-medium (single theme, no switching), relative line numbers.

```elisp
(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(use-package helpful
  :after general
  :config
  ;; Replace built-in describe-* with helpful equivalents
  (global-set-key [remap describe-function] #'helpful-callable)
  (global-set-key [remap describe-variable] #'helpful-variable)
  (global-set-key [remap describe-key]      #'helpful-key))
```

### 4.3 `init-evil.el` — PARTIAL

**Implemented:** `evil`, `evil-collection`, `general` (rata-leader), `winum`, `undo-fu`,
`evil-surround`, `evil-nerd-commenter`, `avy`, `(elpaca-wait)`, keybinding ordering fixed
**TODO:** `evil-matchit`, `evil-args`, `evil-textobj-tree-sitter`, `evil-mc`, `smartparens`

**Note:** `consult-git-grep` is still at `SPC g g` in code (spec says move to `SPC s g`).
This conflicts with the `SPC g g` being used as `consult-git-grep` in init-evil.el
while magit-status is at `SPC g s` in init-dev.el — no actual conflict currently since
they're different keys. Keep `SPC g g` as git-grep per current code.

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

;; evil-matchit: % to jump between matching tags/parens/keywords
(use-package evil-matchit
  :after evil
  :config (global-evil-matchit-mode 1))

;; evil-args: dia/daa to operate on function arguments
(use-package evil-args
  :after evil
  :config
  (define-key evil-inner-text-objects-map "a" 'evil-inner-arg)
  (define-key evil-outer-text-objects-map "a" 'evil-outer-arg))

;; evil-textobj-tree-sitter: language-aware text objects (vaf, vac, vic)
(use-package evil-textobj-tree-sitter
  :after evil
  :config
  (define-key evil-outer-text-objects-map "f"
    (evil-textobj-tree-sitter-get-textobj "function.outer"))
  (define-key evil-inner-text-objects-map "f"
    (evil-textobj-tree-sitter-get-textobj "function.inner"))
  (define-key evil-outer-text-objects-map "c"
    (evil-textobj-tree-sitter-get-textobj "class.outer"))
  (define-key evil-inner-text-objects-map "c"
    (evil-textobj-tree-sitter-get-textobj "class.inner")))

;; evil-mc: multiple cursors
(use-package evil-mc
  :after evil
  :config
  (global-evil-mc-mode 1))
;; Key workflow: grn (make cursor at next match), M-n/M-p (skip), gru (undo all cursors)

;; smartparens: auto-pairing and structural navigation
(use-package smartparens
  :after evil
  :config
  (require 'smartparens-config)  ; default pairs for all languages
  (smartparens-global-mode 1)
  (show-smartparens-global-mode 1))
;; Note: disable electric-pair-mode to avoid conflict with smartparens
```

### 4.4 `init-completion.el` — PARTIAL

**Implemented:** `orderless`, `vertico`, `savehist`, `marginalia`, `consult`, `embark` (C-. and
C-; ARE wired in vertico-map), `embark-consult`, `corfu` (auto, 1-char prefix, 0.2s delay,
history-mode), `cape` (file + dabbrev), `nerd-icons-corfu`
**TODO:** `wgrep`

**New packages remaining:** `wgrep`

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

**wgrep** (editable grep buffers):
```elisp
(use-package wgrep
  :after embark
  :config
  (setq wgrep-auto-save-buffer t))
```
Workflow: `consult-ripgrep` → `embark-export` (C-;) → `wgrep-change-to-wgrep-mode` (C-c C-p) →
edit matches → `wgrep-finish-edit` (C-c C-c).

### 4.5 `init-dev.el` — PARTIAL

**Implemented:** `transient` (+ elpaca-wait), `lsp-mode` (full config + SPC l bindings),
`lsp-ui` (doc + sideline), `flycheck` (global + SPC e n/p), `apheleia` (global-mode),
`magit` (SPC g bindings), `forge` (SPC g F/I), `vterm` (SPC t t), `direnv` (global mode),
`projectile` (SPC p bindings), `consult-projectile` (SPC p f/s)
**TODO:** `vterm-toggle` (currently using plain vterm), `dirvish`, `esup`,
`flyspell`, TRAMP guards on apheleia, `projectile-replace` bindings (SPC p r/R)
**Note:** `dap-mode` was placed in `init-lang.el` instead of here. Either location works.

**Packages:** `lsp-mode`, `lsp-ui`, `flycheck`, `dap-mode`, `apheleia`, `magit`, `forge`,
`vterm`, `vterm-toggle`, `direnv`, `projectile`, `consult-projectile`, `dirvish`, `esup`

#### LSP-mode
- `lsp-deferred` hooked on all major modes (configured per-lang in `init-lang.el`).
- `(setq lsp-prefer-flymake nil)` — use flycheck instead.
- Disable lsp format-on-save: `(setq lsp-enable-on-type-formatting nil)`
  and `(setq lsp-before-save-edits nil)`.
- `lsp-enable-file-watchers nil` for large repos (can be enabled per-project).
- **TRAMP:** Disable file watchers over TRAMP connections automatically.

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

#### flyspell (spell checking)
```elisp
;; Spell checking in code comments/strings
(add-hook 'prog-mode-hook #'flyspell-prog-mode)
;; Spell checking in prose (org + markdown hooked in their respective modules)
(add-hook 'text-mode-hook #'flyspell-mode)
```

#### apheleia
```elisp
(use-package apheleia
  :config
  (apheleia-global-mode t)
  ;; Disable apheleia on remote (TRAMP) files
  (setq apheleia-remote-algorithm 'cancel)
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

#### vterm + vterm-toggle
```elisp
(use-package vterm
  :commands vterm)

(use-package vterm-toggle
  :after (vterm general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "tt" '(vterm-toggle :which-key "toggle terminal")
    "tT" '(vterm-toggle-cd :which-key "terminal at project root")))
```
- `SPC t t` toggles a vterm popup at the bottom (shackle controls placement).
- `SPC t T` opens vterm cd'd to current directory.

#### direnv
- `(direnv-mode)` globally — loads `.envrc` when visiting a directory.
- Required for Python venvs, Go workspaces, Rust toolchain pins.

#### projectile + consult-projectile
```elisp
(use-package projectile
  :demand t
  :config
  (projectile-mode 1)
  (setq projectile-project-search-path '("~/workspace/")))

(use-package consult-projectile
  :after (consult projectile general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "p"  '(:ignore t :which-key "project")
    "pp" '(projectile-switch-project       :which-key "switch project")
    "pf" '(consult-projectile-find-file    :which-key "find file")
    "pb" '(consult-project-buffer          :which-key "project buffers")
    "ps" '(consult-projectile-ripgrep      :which-key "search project")
    "pt" '(projectile-run-project-tests    :which-key "run tests")
    "pk" '(projectile-kill-buffers         :which-key "kill project buffers")
    "pr" '(projectile-replace              :which-key "replace in project")
    "pR" '(projectile-replace-regexp       :which-key "replace regexp")))
```

#### dirvish (modern dired replacement)
```elisp
(use-package dirvish
  :after general
  :config
  (dirvish-override-dired-mode)
  (setq dirvish-attributes '(nerd-icons file-size vc-state git-msg))
  (rata-leader
    :states '(normal visual insert emacs)
    "fd" '(dirvish :which-key "dirvish")))
```
- Preview pane, git status icons, fd integration, subtree toggle.
- Replaces vanilla dired everywhere.

#### esup (startup profiling)
```elisp
(use-package esup
  :commands esup
  :config
  (setq esup-depth 0))  ; top-level only for speed
```
- Available via `M-x esup` or `SPC h P` (profile startup).
- `use-package-compute-statistics t` in init-pkg.el for per-package timing via
  `M-x use-package-report`.

### 4.6 `init-lang.el` — PARTIAL

**Implemented:** `rustic` (+ lsp-deferred hook), `go-mode` (+ lsp-deferred), `pyvenv` (+
python-mode lsp hook), `dockerfile-mode`, `terraform-mode`, `just-mode`, `docker` (SPC a D),
`markdown-mode`, `dap-mode` (full SPC d bindings + auto-configure)
**TODO:** Tree-sitter grammar setup + `major-mode-remap-alist`

**Packages:** `rustic`, `go-mode`, `pyvenv`, `dockerfile-mode`, `terraform-mode`,
`just-mode`, `docker`, `markdown-mode`

**Tree-sitter strategy: Hybrid**
Use `-ts-mode` variants where stable and well-supported; keep classic modes where not.

```elisp
;; Tree-sitter grammar auto-install (Emacs 29+)
(setq treesit-language-source-alist
      '((go "https://github.com/tree-sitter/tree-sitter-go")
        (python "https://github.com/tree-sitter/tree-sitter-python")
        (rust "https://github.com/tree-sitter/tree-sitter-rust")
        (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
        (json "https://github.com/tree-sitter/tree-sitter-json")
        (yaml "https://github.com/tree-sitter/tree-sitter-yaml")
        (toml "https://github.com/tree-sitter/tree-sitter-toml")
        (dockerfile "https://github.com/camdencheek/tree-sitter-dockerfile")))

;; Remap to ts-mode where stable
(setq major-mode-remap-alist
      '((python-mode     . python-ts-mode)
        (go-mode         . go-ts-mode)
        (json-mode       . json-ts-mode)
        (yaml-mode       . yaml-ts-mode)
        (toml-mode       . toml-ts-mode)
        (dockerfile-mode . dockerfile-ts-mode)))
;; Note: Rust stays as rustic-mode (better LSP/cargo integration than rust-ts-mode)
```

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
- Keep rustic-mode (NOT rust-ts-mode) — rustic has tighter cargo/compile integration.

**Python (pyvenv):**
- `(pyvenv-mode t)` globally.
- `direnv` handles automatic venv activation from `.envrc`.
- Hook: `(add-hook 'python-ts-mode-hook #'lsp-deferred)`.
- Document pyright vs pylsp decision (pyright recommended for lsp-mode).

**Go:**
- gopls server: `go install golang.org/x/tools/gopls@latest`.
- apheleia uses `gofmt` by default; override to `goimports` if preferred.
- Remap to go-ts-mode (well-supported).

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

### 4.7 `init-snippets.el` — DONE

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

### 4.8 `init-llm.el` — DONE

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

### 4.9 `init-mcp.el` — DONE (Experimental)

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

### 4.10 `init-persp.el` — TODO

**Packages:** `persp-mode`

**Strategy:** Full workspace isolation with buffer-per-perspective filtering. Manual
perspective creation only (no auto-per-project bridge).

```elisp
(use-package persp-mode
  :after general
  :demand t
  :config
  (setq persp-auto-resume-time -1)  ; no auto-restore (minimal persistence)
  (persp-mode 1)
  (rata-leader
    :states '(normal visual insert emacs)
    "L"  '(:ignore t :which-key "layouts")
    "Ll" '(persp-switch           :which-key "switch layout")
    "Ln" '(persp-add-new          :which-key "new layout")
    "Lk" '(persp-kill             :which-key "kill layout")
    "Lr" '(persp-rename           :which-key "rename layout")
    "La" '(persp-add-buffer       :which-key "add buffer to layout")
    "Lb" '(persp-switch-to-buffer :which-key "layout buffers")
    "Ls" '(persp-save-state-to-file  :which-key "save layouts")
    "LL" '(persp-load-state-from-file :which-key "load layouts")))
```

**Notes:**
- `persp-auto-resume-time -1` disables auto-restore on startup (matches minimal persistence choice).
- Manual save/load available via `SPC L s` / `SPC L L` for when you want to persist specific layouts.
- Buffers are isolated per perspective — `consult-buffer` only shows current perspective's buffers.
- persp-mode integrates with consult via `persp-mode-consult` (filter buffer sources).

### 4.11 `init-org.el` — DONE

**Implemented:** `org` (full agenda config, SPC o bindings, keybinding fix applied),
`org-roam` (with capture templates for default/project/blog-post, dailies with nutrition
tracking, db-autosync), `org-roam-ql`, `org-super-agenda` (dashboard/work/project/habits
custom commands), `org-kanban`, `org-modern` (global + agenda), `org-appear` (autolinks +
autosubmarkers), `consult-org-roam` (search/backlinks/file-find), `org-roam-ui` (SPC o r u),
`writegood-mode` (org + markdown hooks + SPC t w toggle)

**Capture templates:** Fully implemented (TODO, Work Task, Home Lab, Emacs Tweak, Dotfiles
Tweak, Curriculum, Link/Read Later). Not deferred.

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
SPC SPC  execute-extended-command (consult, with savehist for recent-first)

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
  SPC b b  consult-buffer (filtered by persp-mode)
  SPC b B  consult-buffer-other-window
  SPC b k  kill-current-buffer
  SPC b m  bookmark-set
  SPC b M  consult-bookmark

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
  SPC f d  dirvish
  SPC f L  consult-locate

SPC g    git
  SPC g s  magit-status
  SPC g g  consult-git-grep
  SPC g b  magit-blame
  SPC g l  magit-log
  SPC g f  magit-find-file
  SPC g d  magit-diff-buffer-file
  SPC g F  forge-list-pullreqs
  SPC g I  forge-list-issues

SPC h    help
  SPC h f  helpful-callable (describe-function replacement)
  SPC h v  helpful-variable
  SPC h k  helpful-key
  SPC h b  describe-bindings
  SPC h m  consult-man
  SPC h I  consult-info
  SPC h P  esup (profile startup)

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

SPC L    layouts (persp-mode)
  SPC L l  persp-switch
  SPC L n  persp-add-new
  SPC L k  persp-kill
  SPC L r  persp-rename
  SPC L a  persp-add-buffer
  SPC L b  persp-switch-to-buffer
  SPC L s  persp-save-state-to-file
  SPC L L  persp-load-state-from-file

SPC m    mode-specific (local leader alias)
  SPC m m  consult-mode-command

SPC n    narrow
  SPC n n  narrow-to-region
  SPC n f  narrow-to-defun
  SPC n w  widen

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
  SPC p r  projectile-replace
  SPC p R  projectile-replace-regexp

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
  SPC t t  vterm-toggle
  SPC t T  vterm-toggle-cd
  SPC t g  golden-ratio-mode (off by default)
  SPC t w  writegood-mode (manual toggle when not in org/markdown)

SPC w    windows
  SPC w h  evil-window-left
  SPC w l  evil-window-right
  SPC w k  evil-window-up
  SPC w j  evil-window-down
  SPC w /  evil-window-vsplit
  SPC w -  evil-window-split
  SPC w d  evil-window-delete
  SPC w m  delete-other-windows (maximize/toggle)
  SPC w =  balance-windows
  SPC w u  winner-undo

SPC y    yank
  SPC y y  consult-yank-from-kill-ring

;  evil-nerd-commenter (normal/visual states, no SPC prefix)
```

---

## 6. Implementation Order & Status

### Completed

1. ~~**Migrate init-pkg.el to elpaca**~~ — DONE. Bootstrapped, `just run` works.
2. ~~**Create init-system.el**~~ — PARTIAL. no-littering + exec-path-from-shell done.
3. ~~**Fix init-evil.el**~~ — PARTIAL. elpaca-wait, keybinding ordering, undo-fu, surround,
   commenter, avy done.
4. ~~**Extend init-ui.el**~~ — PARTIAL. doom-modeline + nerd-icons done.
5. ~~**Extend init-completion.el**~~ — PARTIAL. corfu + cape + nerd-icons-corfu done.
   Embark keybindings wired.
6. ~~**Create init-dev.el**~~ — PARTIAL. lsp-mode + lsp-ui + flycheck + apheleia + magit +
   forge + vterm + direnv + projectile + consult-projectile done.
7. ~~**Create init-lang.el**~~ — PARTIAL. All language modes + dap-mode done.
8. ~~**Create init-snippets.el**~~ — DONE.
9. ~~**Create init-llm.el**~~ — DONE.
10. ~~**Extend init-org.el**~~ — DONE. All packages, keybinding fix, capture templates.
11. ~~**Create init-mcp.el**~~ — DONE (experimental, commented out).

### Remaining Work

Work these in any order — all can be done independently:

- [ ] **init-system.el:** Add shackle, ediff config, TRAMP config, recentf-mode.
- [ ] **init-ui.el:** Add rainbow-delimiters, helpful, golden-ratio (off by default).
      Change which-key delay 0.3s → 0.1s.
- [ ] **init-evil.el:** Add evil-matchit, evil-args, evil-textobj-tree-sitter, evil-mc,
      smartparens. Disable electric-pair-mode.
- [ ] **init-completion.el:** Add wgrep.
- [ ] **init-dev.el:** Replace vterm with vterm-toggle. Add dirvish, esup, flyspell.
      Add TRAMP guards on apheleia. Add projectile-replace bindings (SPC p r/R).
- [ ] **init-lang.el:** Add tree-sitter grammar setup + major-mode-remap-alist.
- [ ] **init-persp.el:** Create new module — persp-mode with SPC L bindings.
- [ ] **init.el:** Wrap each `(require 'init-xxx)` in `condition-case` for error recovery.
- [ ] **Elpaca lockfile:** Add `just lock` / `just update` targets. Generate and commit lockfile.
- [ ] **justfile:** Add `just install-fonts`, `just install-grammars`, `just lock`, `just update`
      targets.

---

## 7. Critical Gotchas & Decisions

### elpaca + daemon + load order
- `(elpaca-wait)` is mandatory after general.el and evil declarations. Without it,
  `rata-leader` may not be defined when later modules call it on first-install.
- All keybindings must use `:after general` (or `:after (evil general)`) and live in
  `:config`, never `:init`.

### elpaca lockfile
- Use `elpaca-lock` for reproducible installs. Lockfile checked into git.
- `just lock` / `just update` targets in justfile.

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

### TRAMP safety
- Disable `lsp-enable-file-watchers` over TRAMP (use `rata-tramp-buffer-p` guard).
- Disable apheleia on remote files: `(setq apheleia-remote-algorithm 'cancel)`.
- Connection reuse via SSH ControlMaster (configure in `~/.ssh/config`, not Emacs).
- Docker TRAMP: requires `docker-tramp` package or Emacs 29+ built-in support.

### smartparens + electric-pair-mode
- Disable `electric-pair-mode` globally when smartparens is active to avoid double-pairing.
- `(electric-pair-mode -1)` in init-evil.el after smartparens loads.

### tree-sitter grammar install
- Grammars must be compiled once: `M-x treesit-install-language-grammar` per language.
- Add `just install-grammars` target that batch-installs all grammars from
  `treesit-language-source-alist`.
- Hybrid approach: go-ts-mode, python-ts-mode, json-ts-mode, yaml-ts-mode, toml-ts-mode,
  dockerfile-ts-mode. Rust stays as rustic-mode.

### persp-mode + consult buffer filtering
- persp-mode filters `consult-buffer` to show only current perspective's buffers.
- May need `persp-mode-consult` integration or custom source configuration.
- `SPC b B` (consult-buffer-other-window) also filtered by perspective.

### ediff + evil
- ediff uses its own single-key bindings (a, b, n, p, q). These work in evil normal state.
- `ediff-setup-windows-plain` keeps ediff in the same frame (no popup frame).
- `winner-undo` restores window layout after quitting ediff.

### golden-ratio
- Installed but **off by default**. Toggle with `SPC t g`.
- When enabled, inhibit list should include: `*magit*`, `*Org Agenda*`, `*vterm*`.

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

### notifications
- Modeline-only (via doom-modeline). No desktop notifications or alert.el.
- doom-modeline already shows: compilation status, LSP progress, flycheck counts.

### whitespace
- Let apheleia/formatters handle all whitespace cleanup. No ws-butler or whitespace-cleanup-mode.
- No trailing whitespace highlighting. Trust the formatter.

---

## 8. Out of Scope (Explicitly Excluded)

| Item | Reason |
|------|--------|
| `org-auto-tangle` | Config is .el files, not literate org. Not needed. |
| `straight.el` / `package.el` long-term | Replaced by elpaca. |
| File tree sidebar (treemacs/neotree) | Dirvish + consult is sufficient. |
| `Helm` / `Ivy` / `Company` | Replaced by vertico/consult/corfu stack. |
| `Eglot` | Replaced by lsp-mode for DAP support. |
| `desktop-save-mode` | Minimal persistence: savehist + recentf only. |
| `alert.el` / desktop notifications | Modeline-only notification strategy. |
| Theme switching / `circadian.el` | Single theme (gruvbox-dark-medium). |
| `ws-butler` / whitespace cleanup | Formatters handle whitespace. |
| `persp-mode-projectile-bridge` | Manual perspective creation only. |

---

## 9. Out of Scope (Future Work)

| Item | Notes |
|------|-------|
| `jj.el` / Jujutsu UI | No mature Emacs package yet. Watch `https://github.com/bennyandresen/jujutsu.el` |
| `init-mcp.el` stable | Module exists but experimental. Enable once ecosystem stabilizes. |
| Per-project LSP config | `.dir-locals.el` patterns for LSP roots, env overrides. |
| `org-roam-ql` keybindings | Package installed, needs keybinding design and workflow. |
| Emacs as MCP server for Claude Code | Depends on mcp-server-emacs maturity. |
| `evil-cleverparens` | Structural editing for lisps. Consider if elisp editing becomes frequent. |

**Resolved (moved out of future work):**
- ~~Org capture templates~~ — Fully implemented in init-org.el with 7 templates.

---

## 10. PKGS.org Reconciliation

| Package              | Decision                         | In Scope?                               |
|----------------------|----------------------------------|-----------------------------------------|
| elpaca               | Use this                         | Yes — replaces package.el               |
| evil                 | Already implemented              | Yes                                     |
| evil-collection      | Already implemented              | Yes                                     |
| general.el           | Already implemented              | Yes                                     |
| evil-nerd-commenter  | Add to init-evil                 | Yes                                     |
| evil-surround        | Add to init-evil                 | Yes                                     |
| evil-matchit         | Add to init-evil                 | Yes                                     |
| evil-args            | Add to init-evil                 | Yes                                     |
| evil-textobj-tree-sitter | Add to init-evil             | Yes                                     |
| evil-mc              | Add to init-evil                 | Yes                                     |
| undo-fu              | Add to init-evil                 | Yes                                     |
| smartparens          | Add to init-evil                 | Yes                                     |
| Vertico              | Already implemented              | Yes                                     |
| Consult              | Already implemented              | Yes                                     |
| Orderless            | Already implemented              | Yes                                     |
| Marginalia           | Already implemented              | Yes                                     |
| corfu                | Add to init-completion           | Yes                                     |
| cape                 | Add to init-completion           | Yes                                     |
| wgrep                | Add to init-completion           | Yes                                     |
| kind-icon            | **Replaced by nerd-icons-corfu** | Yes (nerd-icons-corfu)                  |
| flycheck             | Add to init-dev                  | Yes                                     |
| lsp-mode             | Add to init-dev                  | Yes                                     |
| lsp-ui               | Add to init-dev                  | Yes                                     |
| dap-mode             | Add to init-dev                  | Yes                                     |
| magit                | Add to init-dev                  | Yes                                     |
| forge                | Add to init-dev                  | Yes                                     |
| apheleia             | Add to init-dev                  | Yes                                     |
| dirvish              | Add to init-dev                  | Yes                                     |
| esup                 | Add to init-dev                  | Yes                                     |
| rustic               | Add to init-lang                 | Yes                                     |
| go-mode              | Add to init-lang                 | Yes                                     |
| dockerfile-mode      | Add to init-lang                 | Yes                                     |
| terraform-mode       | Add to init-lang                 | Yes                                     |
| just-mode            | Add to init-lang                 | Yes                                     |
| docker               | Add to init-lang                 | Yes                                     |
| pyvenv               | Add to init-lang                 | Yes                                     |
| markdown-mode        | Add to init-lang                 | Yes                                     |
| direnv               | Add to init-dev                  | Yes                                     |
| vterm                | Add to init-dev                  | Yes                                     |
| vterm-toggle         | Add to init-dev                  | Yes                                     |
| org mode             | Already implemented              | Yes                                     |
| org-roam             | Already implemented              | Yes                                     |
| org-roam-ui          | Add to init-org                  | Yes                                     |
| consult-org-roam     | Add to init-org                  | Yes                                     |
| org-modern           | Add to init-org                  | Yes                                     |
| org-appear           | Add to init-org                  | Yes                                     |
| org-auto-tangle      | **Removed from scope**           | No                                      |
| org-agenda           | Already implemented              | Yes                                     |
| org-super-agenda     | Already implemented              | Yes                                     |
| ellama               | Add to init-llm                  | Yes                                     |
| Gptel                | Add to init-llm                  | Yes                                     |
| aidermacs            | Add to init-llm                  | Yes                                     |
| mcp-server           | Add to init-mcp (experimental)   | Experimental                            |
| mcp                  | Add to init-mcp (experimental)   | Experimental                            |
| claude-code-ide?     | **Replaced by aidermacs**        | No                                      |
| Emacs Agent Shell?   | **Covered by aidermacs**         | No                                      |
| ECA Emacs?           | Not needed                       | No                                      |
| no-littering         | Add to init-system               | Yes                                     |
| exec-path-from-shell | Add to init-system               | Yes                                     |
| shackle              | Add to init-system               | Yes                                     |
| persp-mode           | Add to init-persp                | Yes                                     |
| golden-ratio         | Add to init-ui (off by default)  | Yes                                     |
| rainbow-delimiters   | Add to init-ui                   | Yes                                     |
| helpful              | Add to init-ui                   | Yes                                     |
| Writegood-mode       | Add to init-org                  | Yes                                     |
| yatemplate           | Add to init-snippets             | Yes                                     |
| YASnippet            | Add to init-snippets             | Yes                                     |
| doom-modeline        | Add to init-ui                   | Yes                                     |
| nerd-icons           | Add to init-ui                   | Yes                                     |
| projectile           | Add to init-dev                  | Yes                                     |
| consult-projectile   | Add to init-dev                  | Yes                                     |
| avy                  | Add to init-evil                 | Yes                                     |
