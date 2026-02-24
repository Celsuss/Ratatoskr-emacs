# Ratatoskr Emacs — Configuration Spec

> Status: Draft v8 — 2026-02-24
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
  ├── init-system      (no-littering, exec-path-from-shell, recentf, ediff, TRAMP, shackle)  ✓ DONE
  ├── init-ui          (gruvbox, doom-modeline, nerd-icons, which-key, rainbow-delimiters, helpful, golden-ratio)  ✓ DONE
  ├── init-evil        (evil, general, winum, undo-fu, surround, commenter, avy, matchit, args, textobj-ts, evil-mc, smartparens)  ✓ DONE
  ├── init-completion  (vertico, orderless, marginalia, consult, embark, corfu, cape, nerd-icons-corfu, wgrep)  ✓ DONE
  ├── init-dev         (lsp, lsp-ui, flycheck, apheleia, magit, forge, vterm, vterm-toggle, envrc, projectile, dirvish, esup, jinx, diff-hl, editorconfig, browse-at-remote, consult-flycheck, restclient, restclient-jq, breadcrumb, explain-pause-mode)  ✓ DONE
  ├── init-lang        (rustic, cargo, go, python, dockerfile, terraform, just, docker, markdown, markdown-preview-mode, dap-mode, tree-sitter, yaml-pro, python-pytest, pkgbuild-mode, ansible-mode, ein, polymode)  PARTIAL
  ├── init-k8s         (kubel, kubel-evil — kubectl interface)                    ✓ DONE
  ├── init-snippets    (yasnippet, yasnippet-snippets, yatemplate)          ✓ DONE
  ├── init-llm         (gptel, ellama, aidermacs)                           ✓ DONE
  ├── init-mcp         (mcp — experimental, commented out in init.el)       ✓ DONE
  ├── init-persp       (persp-mode workspaces, SPC L bindings)              ✓ DONE
  ├── init-org         (org, org-roam, org-super-agenda, org-kanban, org-modern, org-appear, consult-org-roam, org-roam-ui, org-roam-ql, writegood-mode, org-download, org-transclusion, ox-hugo)  DONE
  └── init-dashboard   (dashboard.el — start page with logo, agenda, roam stats, git status)  TODO
```

**Error recovery in init.el — DONE:** Each module load is wrapped via `rata-load-module`,
which uses `condition-case` in normal mode and bare `require` with `--debug-init` for full backtrace.

---

## 3. Package Manager Migration: `package.el` → `elpaca` — DONE

Elpaca is fully bootstrapped and operational:
- `early-init.el` disables `package-enable-at-startup`.
- `init.el` contains the full elpaca bootstrap snippet + `elpaca-use-package` integration.
- `init-pkg.el` is thin: just `(setq use-package-always-ensure t)`.
- `(elpaca-wait)` is in `init-evil.el` after general + evil declarations.
- All modules use `:after general` + `:config` for keybindings (load-order rule enforced).

### Elpaca Lockfile (Reproducibility) — DONE (justfile targets added)

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

### 4.1 `init-system.el` — DONE

**Implemented:** `no-littering`, `exec-path-from-shell`, `recentf-mode`, ediff config,
TRAMP config (SSH + Docker, `rata-tramp-buffer-p` helper), `shackle`
**Note:** `savehist-mode` lives in `init-completion.el` (alongside vertico). Left there intentionally.

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

### 4.2 `init-ui.el` — DONE

**Implemented:** `gruvbox-theme`, `nerd-icons`, `doom-modeline`, `which-key` (0.1s delay), relative line numbers,
`rainbow-delimiters`, `helpful` (with SPC h f/v/k bindings + remap), `golden-ratio` (off by default, SPC t g toggle)

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

### 4.3 `init-evil.el` — DONE

**Implemented:** `evil`, `evil-collection`, `general` (rata-leader), `winum`, `undo-fu`,
`evil-surround`, `evil-nerd-commenter`, `avy`, `(elpaca-wait)`, keybinding ordering fixed,
`evil-matchit`, `evil-args`, `evil-textobj-tree-sitter`, `evil-mc`, `smartparens`

**Note:** `SPC g g` is now `magit-status` (Spacemacs convention). `consult-git-grep` moved to `SPC g G`.
LSP bindings moved from `SPC l` to `SPC L`. Layouts (persp-mode) moved from `SPC L` to `SPC l`.

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

### 4.4 `init-completion.el` — DONE

**Implemented:** `orderless`, `vertico`, `savehist`, `marginalia`, `consult`, `embark` (C-. and
C-; ARE wired in vertico-map), `embark-consult`, `corfu` (auto, 1-char prefix, 0.2s delay,
history-mode), `cape` (file + dabbrev), `nerd-icons-corfu`, `wgrep`

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

### 4.5 `init-dev.el` — DONE

**Implemented:** `transient` (+ elpaca-wait), `lsp-mode` (full config + SPC l bindings),
`lsp-ui` (doc + sideline), `flycheck` (global + SPC e n/p), `apheleia` (global-mode +
TRAMP cancel), `magit` (SPC g bindings), `forge` (SPC g F/I), `vterm` + `vterm-toggle`
(SPC t t/T), `envrc` (buffer-local direnv, replaces `direnv`), `projectile` (SPC p bindings + replace SPC p r/R),
`consult-projectile` (SPC p f/s), `dirvish` (SPC f d), `esup` (SPC h P), `flyspell`
(prog-mode + text-mode hooks), `diff-hl` (git gutter + magit integration), `consult-flycheck`
(SPC e l), `editorconfig` (global), `browse-at-remote` (SPC g o)
**Note:** `dap-mode` was placed in `init-lang.el` instead of here. Either location works.

**Packages:** `lsp-mode`, `lsp-ui`, `flycheck`, `dap-mode`, `apheleia`, `magit`, `forge`,
`vterm`, `vterm-toggle`, `envrc`, `projectile`, `consult-projectile`, `dirvish`, `esup`,
`diff-hl`, `consult-flycheck`, `editorconfig`, `browse-at-remote`

#### LSP-mode
- `lsp-deferred` hooked on all major modes (configured per-lang in `init-lang.el`).
- `(setq lsp-prefer-flymake nil)` — use flycheck instead.
- Disable lsp format-on-save: `(setq lsp-enable-on-type-formatting nil)`
  and `(setq lsp-before-save-edits nil)`.
- `lsp-enable-file-watchers nil` for large repos (can be enabled per-project).
- **TRAMP:** Disable file watchers over TRAMP connections automatically.

```
SPC L   -> :which-key "lsp"
SPC L d -> lsp-find-definition
SPC L r -> lsp-find-references
SPC L n -> lsp-rename
SPC L a -> lsp-execute-code-action
SPC L f -> lsp-format-buffer  (manual, apheleia handles save)
SPC L i -> lsp-find-implementation
SPC L t -> lsp-find-type-definition
SPC L s -> lsp-workspace-restart
SPC L L -> lsp  (manually start LSP)
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
SPC g g -> magit-status
SPC g G -> consult-git-grep
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

#### envrc (replaces direnv) — DONE
**Replaces `direnv-mode`.** `envrc.el` is buffer-local direnv integration (vs global
`direnv-mode`). Better for multi-project workflows where different buffers need different
environments simultaneously (e.g., Python project in one window, Rust in another).

```elisp
(use-package envrc
  :demand t
  :config
  (envrc-global-mode))
```
- Buffer-local: each buffer gets the `.envrc` from its project root.
- Required for Python venvs, Go workspaces, Rust toolchain pins.
- Drop-in replacement — remove `direnv` package when adding `envrc`.

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

#### diff-hl (git gutter indicators) — DONE
Git change indicators in the fringe (added/changed/deleted lines). Visible at a glance
while editing — complements magit's diff views.

```elisp
(use-package diff-hl
  :demand t
  :config
  (global-diff-hl-mode)
  (diff-hl-flydiff-mode)  ; update diffs without saving
  (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh)
  ;; Use margin instead of fringe in terminal
  (unless (display-graphic-p)
    (diff-hl-margin-mode)))
```
- Integrates with magit: fringe updates after magit operations.
- `diff-hl-flydiff-mode` shows uncommitted changes in real-time.
- Works over TRAMP (respects remote git).

#### consult-flycheck — DONE
Consult-style interface for flycheck errors. Replaces the `consult-flymake` binding
for LSP buffers.

```elisp
(use-package consult-flycheck
  :after (consult flycheck general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "el" '(consult-flycheck :which-key "list errors")))
```

#### editorconfig — DONE
Respects `.editorconfig` files common in open-source projects. Auto-sets indent style,
tab width, line endings, trailing whitespace, etc.

```elisp
(use-package editorconfig
  :demand t
  :config
  (editorconfig-mode 1))
```
- Important for Arch Linux contributions and multi-project workflows.
- Does not conflict with apheleia (editorconfig sets buffer vars, apheleia formats on save).

#### browse-at-remote — DONE
Open the current file/line on GitHub/GitLab/etc. from Emacs. Useful for sharing links
in PRs and code reviews.

```elisp
(use-package browse-at-remote
  :after general
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "go" '(browse-at-remote :which-key "open on remote")))
```

### 4.6 `init-lang.el` — DONE

**Implemented:** `rustic` (+ lsp-deferred hook), `go-mode` (+ lsp-deferred), `pyvenv` (+
python-ts-mode lsp hook), `dockerfile-mode`, `terraform-mode`, `just-mode`, `docker` (SPC a D),
`markdown-mode`, `dap-mode` (full SPC d bindings + auto-configure), tree-sitter grammar sources
+ `major-mode-remap-alist` (python/go/json/yaml/toml/dockerfile → ts-mode; rust stays rustic),
`yaml-pro` (structural YAML via yaml-ts-mode hook), `python-pytest` (SPC m t bindings),
`pkgbuild-mode` (auto-activates on PKGBUILD files)

**Packages:** `rustic`, `go-mode`, `pyvenv`, `dockerfile-mode`, `terraform-mode`,
`just-mode`, `docker`, `markdown-mode`, `yaml-pro`, `python-pytest`, `pkgbuild-mode`

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

#### yaml-pro (structural YAML editing) — DONE
Tree-sitter powered structural editing for YAML. Essential for large Helm values files
and Kubernetes manifests. Fold/unfold nodes, move sections, tree-aware navigation.

```elisp
(use-package yaml-pro
  :after yaml-ts-mode
  :hook (yaml-ts-mode . yaml-pro-ts-mode)
  :config
  ;; yaml-pro-ts-mode uses tree-sitter for structural ops
  ;; Key workflow: C-c C-f fold, C-c C-u unfold, M-up/down move nodes
  )
```
- Hooks into `yaml-ts-mode` (our default for YAML via remap).
- Massive QoL for Helm charts, k8s manifests, Terraform YAML.

#### python-pytest — DONE
Run pytest from Emacs with local-leader bindings. Integrates with projectile for
project-root detection.

```elisp
(use-package python-pytest
  :after (python general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'python-ts-mode-map
    "mt"  '(:ignore t :which-key "test")
    "mtt" '(python-pytest-file            :which-key "test file")
    "mtf" '(python-pytest-function        :which-key "test function")
    "mtr" '(python-pytest-repeat          :which-key "repeat last test")
    "mtl" '(python-pytest-last-failed     :which-key "last failed")
    "mtp" '(python-pytest                 :which-key "test project")))
```
- `SPC m t t` run tests for current file.
- `SPC m t f` run test at point (function).
- `SPC m t l` re-run only last-failed tests.
- Uses projectile root to find `pytest.ini` / `pyproject.toml`.

#### pkgbuild-mode (Arch Linux) — DONE
Syntax highlighting, validation, and helpers for PKGBUILD files. Essential for
Arch Linux package contributions.

```elisp
(use-package pkgbuild-mode
  :mode "/PKGBUILD$"
  :config
  ;; PKGBUILDs are bash — ensure shellcheck runs via flycheck
  (setq pkgbuild-update-sums-on-save nil))  ; manual sums update
```
- Auto-activates on files named `PKGBUILD`.
- Flycheck uses `shellcheck` for linting (via `sh-mode` base).
- `M-x pkgbuild-update-sums` to recalculate checksums.

### 4.7 `init-k8s.el` — DONE

**Packages:** `kubel`, `kubernetes-evil`

**Strategy:** Interactive kubectl interface inside Emacs. List pods, view logs, exec
into containers, describe resources, port-forward — all without leaving the editor.

```elisp
(use-package kubel
  :after general
  :commands kubel
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "ak"  '(:ignore t :which-key "kubernetes")
    "akk" '(kubel                           :which-key "kubel")
    "akn" '(kubel-set-namespace             :which-key "set namespace")
    "akc" '(kubel-set-context               :which-key "set context")
    "akp" '(kubel-port-forward-pod          :which-key "port forward")
    "akl" '(kubel-get-pod-logs              :which-key "pod logs")))

(use-package kubel-evil
  :after kubel)
```

**Key workflows:**
- `SPC a k k` — Open kubel buffer (interactive pod/resource list).
- `SPC a k n` — Switch namespace.
- `SPC a k c` — Switch kubectl context.
- `SPC a k l` — Tail pod logs.
- `SPC a k p` — Port-forward to a pod.
- Inside kubel buffer: `RET` to describe, `l` for logs, `e` to exec, `C` to copy pod name.
- kubel-evil provides evil keybindings in the kubel buffer.

**Prerequisites:**
- `kubectl` must be on `$PATH` (handled by `envrc` / `exec-path-from-shell`).
- `~/.kube/config` must exist with cluster contexts.

### 4.8 `init-snippets.el` — DONE

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

### 4.9 `init-llm.el` — DONE

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

### 4.10 `init-mcp.el` — DONE (Experimental)

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

### 4.11 `init-persp.el` — DONE

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

### 4.12 `init-org.el` — DONE

**Implemented:** `org` (full agenda config, SPC o bindings, keybinding fix applied),
`org-roam` (with capture templates for default/project/blog-post, dailies with nutrition
tracking, db-autosync), `org-roam-ql`, `org-super-agenda` (dashboard/work/project/habits
custom commands), `org-kanban`, `org-modern` (global + agenda), `org-appear` (autolinks +
autosubmarkers), `consult-org-roam` (search/backlinks/file-find), `org-roam-ui` (SPC o r u),
`writegood-mode` (org + markdown hooks + SPC t w toggle)

**Capture templates (existing):** TODO, Work Task, Home Lab, Emacs Tweak, Dotfiles
Tweak, Curriculum, Link/Read Later.

**v7 enhancements implemented:** See §4.15 for full details.

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

#### org-download (paste/drag images) — DONE
Drag-and-drop or paste images (screenshots, diagrams) into org files. Auto-saves to
an attachments directory relative to the org file.

```elisp
(use-package org-download
  :after org
  :hook (org-mode . org-download-enable)
  :config
  ;; Store images relative to org file in ./images/
  (setq org-download-image-dir "./images"
        org-download-heading-lvl nil
        org-download-method 'directory))
```
- `org-download-clipboard` to paste from clipboard (screenshot workflow).
- `org-download-yank` to download image from URL in kill ring.
- Works with org-roam notes for visual knowledge management.

---

### 4.13 v5 Additions — Developer QoL & Workflow Enhancements

#### cargo.el (Rust build commands) — DONE (EXTEND init-lang)
Run cargo commands directly from Emacs via compilation buffers. Errors are clickable
and jump to source location. Uses `compile` infrastructure for familiar workflow.

```elisp
(use-package cargo
  :after (rustic general)
  :hook (rustic-mode . cargo-minor-mode)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'rustic-mode-map
    "mc"  '(:ignore t :which-key "cargo")
    "mcb" '(cargo-process-build       :which-key "cargo build")
    "mct" '(cargo-process-test        :which-key "cargo test")
    "mcr" '(cargo-process-run         :which-key "cargo run")
    "mcc" '(cargo-process-clippy      :which-key "cargo clippy")
    "mcd" '(cargo-process-doc         :which-key "cargo doc")
    "mcf" '(cargo-process-fmt         :which-key "cargo fmt")
    "mca" '(cargo-process-add         :which-key "cargo add")
    "mcB" '(cargo-process-bench       :which-key "cargo bench")))
```
- `SPC m c t` run tests for current crate.
- `SPC m c c` run clippy for linting.
- Results appear in compilation buffer — `next-error` / `previous-error` to navigate.
- Complements rustic's built-in cargo integration with leader-key access.

#### makepkg helpers (Arch Linux PKGBUILD) — DONE (EXTEND init-lang)
Custom helper functions for PKGBUILD workflows. Not a package — defined inline
in `init-lang.el` within the `pkgbuild-mode` use-package block.

```elisp
;; Inside pkgbuild-mode use-package :config
(defun rata-makepkg-build ()
  "Run makepkg in the current PKGBUILD directory."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "makepkg -sf")))

(defun rata-makepkg-srcinfo ()
  "Generate .SRCINFO from current PKGBUILD."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "makepkg --printsrcinfo > .SRCINFO")))

(defun rata-namcap-check ()
  "Run namcap on the current PKGBUILD."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile (format "namcap %s" (buffer-file-name)))))

(defun rata-updpkgsums ()
  "Run updpkgsums on the current PKGBUILD."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "updpkgsums")))

(rata-leader
  :states '(normal visual insert emacs)
  :keymaps 'pkgbuild-mode-map
  "mp"  '(:ignore t :which-key "pkgbuild")
  "mpb" '(rata-makepkg-build    :which-key "makepkg build")
  "mps" '(rata-makepkg-srcinfo  :which-key "gen .SRCINFO")
  "mpn" '(rata-namcap-check     :which-key "namcap lint")
  "mpu" '(rata-updpkgsums       :which-key "update sums"))
```
- `SPC m p b` build the package.
- `SPC m p n` lint with namcap.
- `SPC m p u` recalculate checksums.
- Prerequisites: `makepkg`, `namcap`, `updpkgsums` on `$PATH` (standard Arch dev tools).

#### ansible-mode — DONE (EXTEND init-lang)
Syntax highlighting, documentation lookup, and linting for Ansible playbooks, roles,
and inventory files.

```elisp
(use-package ansible
  :hook ((yaml-ts-mode . ansible)
         (yaml-mode    . ansible))
  :config
  ;; Auto-detect ansible files by path patterns
  (setq ansible-vault-password-file "~/.ansible-vault-pass"))

(use-package ansible-doc
  :after ansible
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'ansible-key-map
    "ma"  '(:ignore t :which-key "ansible")
    "mad" '(ansible-doc :which-key "ansible doc")))
```
- Auto-activates on YAML files in roles/playbooks directories.
- `ansible-doc` for inline module documentation lookup.
- Works with yaml-pro for structural editing of playbooks.
- Ansible-vault integration for encrypted vars (needs vault password file).

#### restclient.el (HTTP client) — DONE (EXTEND init-dev)
Write and execute HTTP requests from `.http` files. Responses displayed inline.
Great for API testing without leaving Emacs.

```elisp
(use-package restclient
  :mode ("\\.http\\'" . restclient-mode)
  :after general
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'restclient-mode-map
    "mr"  '(:ignore t :which-key "restclient")
    "mrr" '(restclient-http-send-current      :which-key "send request")
    "mrR" '(restclient-http-send-current-raw  :which-key "send raw")
    "mrn" '(restclient-jump-next              :which-key "next request")
    "mrp" '(restclient-jump-prev              :which-key "prev request")
    "mrc" '(restclient-copy-curl-command      :which-key "copy as curl")))

(use-package restclient-jq
  :after restclient
  :config
  ;; Enables jq filtering in restclient responses
  ;; Use :jq .field in your .http files to filter JSON responses
  )
```
- `C-c C-c` or `SPC m r r` to execute request at point.
- Supports variables, headers, body, and chained requests.
- `restclient-jq` adds jq filtering for JSON responses (`:jq .data[]`).
- `.http` files can be checked into repos as API documentation.

#### ein (Emacs IPython Notebook) — DONE (EXTEND init-lang)
Full Jupyter notebook support inside Emacs. Run cells, see output inline,
connect to local or remote kernels.

```elisp
(use-package ein
  :after general
  :commands (ein:run ein:login ein:notebooklist-open)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "aj"  '(:ignore t :which-key "jupyter")
    "ajr" '(ein:run                  :which-key "start jupyter")
    "ajl" '(ein:login                :which-key "login to jupyter")
    "ajn" '(ein:notebooklist-open    :which-key "notebook list")))
```
- `SPC a j r` starts a local Jupyter server and opens notebook list.
- `SPC a j l` connects to an existing Jupyter server (local or remote).
- Cell execution, output display, image rendering all work in Emacs.
- Integrates with pyvenv/envrc for correct Python environment.
- Prerequisites: `jupyter` must be installed in the active Python venv.

#### popper.el (popup management) — DONE (EXTEND init-system)
Smart popup management — dismiss, cycle, and toggle popup buffers (compilation,
help, vterm, flycheck) with unified keybindings.

```elisp
(use-package popper
  :after general
  :demand t
  :config
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*Warnings\\*"
          "Output\\*$"
          "\\*Async Shell Command\\*"
          "\\*compilation\\*"
          "\\*Backtrace\\*"
          "\\*Help\\*"
          "\\*helpful"
          "\\*Flycheck errors\\*"
          "\\*lsp-help\\*"
          "\\*grep\\*"
          "\\*cargo-.*\\*"
          "\\*pytest.*\\*"
          "\\*restclient.*\\*"
          vterm-mode))
  (popper-mode 1)
  ;; Use M-` to toggle popups (doesn't conflict with SPC leader)
  (global-set-key (kbd "M-`") #'popper-toggle)
  (global-set-key (kbd "C-M-`") #'popper-cycle)
  (global-set-key (kbd "M-~") #'popper-toggle-type))
```
- `M-\`` toggles the last popup on/off.
- `C-M-\`` cycles through popup buffers.
- `M-~` promotes a popup to a regular buffer (or demotes).
- Complements shackle: shackle controls initial placement, popper controls dismissal.
- **Note:** Consider whether popper replaces some shackle rules or complements them.

#### breadcrumb (LSP header-line context) — DONE (EXTEND init-dev)
Shows the current file > class > method path in the header line using LSP symbols.
Always know where you are in large files.

```elisp
(use-package breadcrumb
  :after lsp-mode
  :hook (lsp-mode . breadcrumb-local-mode)
  :config
  ;; breadcrumb uses lsp-mode's document symbols for context
  ;; No extra config needed — auto-displays in header line
  )
```
- Automatically appears in header line for all LSP-enabled buffers.
- Shows hierarchical context: `file.py > MyClass > process_data`.
- Zero-config — hooks into lsp-mode's existing symbol information.
- Useful in Rust (deeply nested modules), Python (class methods), YAML (nested keys).

#### jinx (modern spellcheck, replaces flyspell) — DONE (EXTEND init-dev)
Enchant-based spell checker that replaces flyspell. Faster, supports multiple
dictionaries, integrates with vertico for corrections.

```elisp
(use-package jinx
  :demand t
  :config
  (global-jinx-mode)
  ;; Replaces flyspell — remove flyspell hooks when adding jinx
  (rata-leader
    :states '(normal visual insert emacs)
    "ts" '(jinx-correct :which-key "spell correct")))
```
- **Replaces flyspell entirely** — remove `flyspell-prog-mode` and `flyspell-mode` hooks.
- Uses enchant backend (supports aspell, hunspell, nuspell).
- `M-$` or `SPC t s` to correct word at point (uses vertico for selection).
- Faster than flyspell — no per-word subprocess calls.
- Prerequisites: `enchant` package installed (`pacman -S enchant`).

#### hl-todo (highlight TODO/FIXME keywords) — DONE (EXTEND init-ui)
Highlight TODO, FIXME, HACK, NOTE, DEPRECATED, and other keywords in code
comments with distinct colors.

```elisp
(use-package hl-todo
  :hook (prog-mode . hl-todo-mode)
  :config
  (setq hl-todo-keyword-faces
        '(("TODO"       . "#FF8C00")
          ("FIXME"      . "#FF0000")
          ("HACK"       . "#FF00FF")
          ("NOTE"       . "#00BFFF")
          ("DEPRECATED" . "#808080")
          ("BUG"        . "#FF0000")
          ("XXX"        . "#FF00FF")))
  ;; Navigate between TODO keywords
  (rata-leader
    :states '(normal visual insert emacs)
    "et" '(hl-todo-next     :which-key "next TODO")
    "eT" '(hl-todo-previous :which-key "prev TODO")))
```
- Hooks into `prog-mode` — active in all programming buffers.
- `SPC e t` / `SPC e T` to jump between TODO/FIXME comments.
- Colors are gruvbox-friendly (can be adjusted to match theme).

#### explain-pause-mode (performance profiling) — DONE (EXTEND init-dev)
Profile Emacs to find what's making it slow. Identifies laggy hooks,
expensive functions, and slow packages in real-time.

```elisp
(use-package explain-pause-mode
  :commands explain-pause-mode
  :config
  ;; Only enable when debugging — not in normal use
  (rata-leader
    :states '(normal visual insert emacs)
    "hE" '(explain-pause-mode :which-key "explain pauses")))
```
- `SPC h E` toggles profiling mode on/off.
- When enabled, logs every function that causes Emacs to pause >X ms.
- `M-x explain-pause-top` shows a `top`-like view of slow functions.
- Complements esup (startup profiling) — this profiles runtime performance.

#### polymode (YAML + Go templates for Helm) — DONE (EXTEND init-lang)
True multi-mode editing for Helm chart templates. YAML mode outside `{{ }}` blocks,
Go template mode inside. Accurate highlighting and indentation for both.

```elisp
(use-package polymode
  :after yaml-ts-mode
  :config
  ;; Define Go-template inner mode
  (define-hostmode poly-yaml-hostmode
    :mode 'yaml-ts-mode)

  (define-innermode poly-go-template-innermode
    :mode 'go-ts-mode
    :head-matcher "{{[-]?"
    :tail-matcher "[-]?}}"
    :head-mode 'host
    :tail-mode 'host)

  (define-polymode poly-yaml-go-template-mode
    :hostmode 'poly-yaml-hostmode
    :innermodes '(poly-go-template-innermode)))

;; Auto-activate on Helm template files
(add-to-list 'auto-mode-alist
             '("/templates/.*\\.ya?ml\\'" . poly-yaml-go-template-mode))
(add-to-list 'auto-mode-alist
             '("\\.tpl\\'" . poly-yaml-go-template-mode))
```
- Auto-activates on files in `templates/` directories (Helm convention).
- Also activates on `.tpl` files.
- YAML navigation and structure (yaml-pro) works in YAML regions.
- Go template syntax highlighting and completion works inside `{{ }}`.
- **Note:** May need tuning per-project. Consider `.dir-locals.el` for non-standard paths.

### 4.14 `init-dashboard.el` — TODO (v6)

**Package:** `dashboard.el` + custom widgets

**Strategy:** Spacemacs-inspired start page with second-brain integration. Uses dashboard.el
as the base with custom widgets for org-agenda, org-roam stats, and git repo status.
Single-column centered layout (dashboard.el native). Refreshes on buffer revisit.

**Logo:** `logo.png` in repo root (Ratatoskr squirrel on Yggdrasil with circuit-board branches).
Centered with "Ratatoskr Emacs" subtitle below.

#### Sections (top to bottom)

1. **Logo + subtitle** — Centered logo image + "Ratatoskr Emacs" text
2. **Fortune/quote** — Random quote from hardcoded list mixing programming wisdom (Dijkstra,
   Knuth, ESR) and Norse mythology (Eddas, Hávamál proverbs). No system `fortune` dependency.
3. **Quick action buttons** — Shortcut buttons for common actions (find file, recent projects, etc.)
4. **Recent projects** — From projectile, with number shortcuts for quick access
5. **Bookmarks** — Emacs bookmarks section
6. **Week agenda** — Custom widget: 7-day org-agenda overview (today + 6 days) pulling from
   `~/workspace/second-brain/org-roam/` agenda files. Uses org-super-agenda grouping.
7. **Org-roam stats** — Custom widget: total note count + notes created/modified this week.
   Reads from org-roam database.
8. **Git status** — Custom widget: dirty/clean status of hardcoded repos. Initial list:
   `~/workspace/Ratatoskr-emacs`, `~/workspace/second-brain`. User can extend list.
9. **Footer** — Startup time (from `emacs-init-time`) + loaded package count

#### Navigation

- Full Evil keybindings: `j`/`k` to move between items, `RET` to open
- Number shortcuts for quick access to items within sections
- `SPC` leader still works in dashboard buffer

#### Refresh behavior

- Re-renders when switching back to the `*dashboard*` buffer (not timer-based)
- Agenda, roam stats, and git status all refresh on revisit

#### Quotes list

Hardcoded `rata-dashboard-quotes` variable. Mix of:
- **Programming:** Dijkstra, Knuth, Alan Kay, Rich Hickey, ESR, etc.
- **Norse mythology:** Hávamál verses, Poetic Edda wisdom, Ratatoskr lore

```elisp
(use-package dashboard
  :ensure t
  :demand t
  :config
  (setq dashboard-startup-banner (expand-file-name "logo.png" user-emacs-directory)
        dashboard-banner-logo-title "Ratatoskr Emacs"
        dashboard-image-banner-max-height 200
        dashboard-center-content t
        dashboard-vertically-center-content nil
        dashboard-projects-backend 'projectile
        dashboard-display-icons-p t
        dashboard-icon-type 'nerd-icons
        dashboard-set-heading-icons t
        dashboard-set-file-icons t
        dashboard-items '((projects    . 5)
                          (bookmarks   . 5)
                          (rata-agenda . 1)
                          (rata-roam-stats . 1)
                          (rata-git-status . 1))
        dashboard-set-navigator t
        dashboard-force-refresh t)

  ;; Quote as init-info (below banner)
  (setq dashboard-init-info
        (nth (random (length rata-dashboard-quotes)) rata-dashboard-quotes))

  ;; Footer: startup time + package count
  (setq dashboard-set-footer t
        dashboard-footer-messages
        (list (format "Emacs loaded in %s with %d packages"
                      (emacs-init-time "%.2fs")
                      (length package-activated-list))))

  ;; Evil navigation in dashboard
  (evil-set-initial-state 'dashboard-mode 'normal)

  ;; SPC b h to open dashboard
  (rata-leader
    :states '(normal visual insert emacs)
    "bh" '(dashboard-open :which-key "home (dashboard)"))

  (dashboard-setup-startup-hook))

;; Ensure dashboard is fully installed before init completes
(elpaca-wait)
```

#### Custom widgets

**Agenda widget:** Queries org-agenda for 7 days, formats as compact day-by-day list.
Uses `org-agenda-get-day-entries` or similar to pull scheduled/deadline items.

**Org-roam stats widget:** Queries `org-roam-db` for total node count. Counts files
modified in the last 7 days via filesystem check on `~/workspace/second-brain/org-roam/`.

**Git status widget:** Runs `git status --porcelain` on each hardcoded repo path.
Displays repo name + clean/dirty indicator. Non-blocking (uses `process-file` or
`call-process` to avoid blocking startup).

#### Hardcoded repos for git status

```elisp
(defcustom rata-dashboard-git-repos
  '("~/workspace/Ratatoskr-emacs"
    "~/workspace/second-brain")
  "List of git repositories to show status for on the dashboard."
  :type '(repeat directory)
  :group 'rata-dashboard)
```

### 4.15 v7 Additions — Org & Org-Roam Supercharge (EXTEND init-org)

> **Goal:** Transform the second-brain from a note dump into an interconnected
> Zettelkasten with frictionless capture, robust agenda integration, and periodic
> review workflows. All changes live in `init-org.el` unless otherwise noted.

#### Design Decisions

- **Zettelkasten-style atomic notes** — preferred structure. File count growing
  large (~1,400+) is acceptable; discoverability via search/tags/links compensates.
- **Tag-based agenda inclusion** — roam notes with TODOs get a `:hastodo:` filetag
  automatically via capture template. Only those files are scanned by org-agenda
  (avoids scanning all 1,400+ roam files on every refresh).
- **Work/personal separation** — single roam database, tag-based filtering
  (`:work:` / `:personal:`). Agenda custom command + consult-org-roam filter.
- **Fleeting notes** — dedicated `inbox.org` for quick dumps; weekly review
  processes inbox into proper roam notes.
- **Habits** — dedicated `habits.org` with proper org-habit SCHEDULED repeaters
  (`.+1d`). Daily template references habits but doesn't duplicate tracking.
- **Timestamp filenames kept** — collision-safe, user doesn't look at filenames.

#### New Packages

**org-transclusion** — live embedding of content from one note inside another.
Enables hub/MOC (Map of Content) notes that pull in sections from atomic notes.

```elisp
(use-package org-transclusion
  :after (org general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "ort"  '(:ignore t :which-key "transclusion")
    "orta" '(org-transclusion-add          :which-key "add transclusion")
    "ortA" '(org-transclusion-add-all      :which-key "add all transclusions")
    "ortr" '(org-transclusion-remove       :which-key "remove transclusion")
    "ortR" '(org-transclusion-remove-all   :which-key "remove all")
    "orte" '(org-transclusion-live-sync-start :which-key "edit source")
    "ortm" '(org-transclusion-mode         :which-key "toggle mode")))
```
- Use `#+transclude: [[id:...]]` or `#+transclude: [[file:...]] :lines 5-15` in org files.
- `org-transclusion-mode` renders transclusions inline (read-only by default).
- `org-transclusion-live-sync-start` allows editing the source from the transclusion.
- Perfect for MOC/hub notes that aggregate content from atomic Zettelkasten notes.

**ox-hugo** — export org-roam blog posts to Hugo with leader keybindings.

```elisp
(use-package ox-hugo
  :after (ox general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "ob"  '(:ignore t :which-key "blog/hugo")
    "obe" '(org-hugo-export-wim-to-md :which-key "export to hugo")
    "obp" '(rata-hugo-preview         :which-key "preview post")))

(defun rata-hugo-preview ()
  "Start Hugo server for previewing blog posts."
  (interactive)
  (let ((default-directory (expand-file-name "~/workspace/second-brain/hugo/")))
    (if (get-buffer "*hugo-server*")
        (browse-url "http://localhost:1313")
      (start-process "hugo-server" "*hugo-server*" "hugo" "server" "-D")
      (run-at-time 2 nil (lambda () (browse-url "http://localhost:1313"))))))
```
- `SPC o b e` exports current org buffer to Hugo markdown.
- `SPC o b p` starts Hugo dev server and opens browser (or just opens browser if already running).
- Blog template already has `#+hugo_base_dir` — ox-hugo reads this for export path.

#### org-roam-ql Keybindings & Workflow — DONE

Design keybindings for org-roam-ql queries. Useful for weekly review and note discovery.

```elisp
(use-package org-roam-ql
  :after (org-roam general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "orq"  '(:ignore t :which-key "roam queries")
    "orqo" '(rata-roam-orphan-notes      :which-key "orphan notes")
    "orqr" '(rata-roam-recent-notes      :which-key "recent notes")
    "orqw" '(rata-roam-work-notes        :which-key "work notes")
    "orqt" '(rata-roam-stale-todos       :which-key "stale TODOs")))

(defun rata-roam-orphan-notes ()
  "Show org-roam notes with zero backlinks."
  (interactive)
  (org-roam-ql-search
   '(not (backlink-count > 0))
   "Orphan notes (no backlinks)"))

(defun rata-roam-recent-notes ()
  "Show org-roam notes modified in the last 7 days."
  (interactive)
  (org-roam-ql-search
   `(file-mtime > ,(- (float-time) (* 7 24 60 60)))
   "Notes modified this week"))

(defun rata-roam-work-notes ()
  "Show all org-roam notes tagged :work:."
  (interactive)
  (org-roam-ql-search
   '(tags "work")
   "Work notes"))

(defun rata-roam-stale-todos ()
  "Show org-roam notes with TODOs older than 2 weeks."
  (interactive)
  (org-roam-ql-search
   '(and (todo) (file-mtime < ,(- (float-time) (* 14 24 60 60))))
   "Stale TODOs (>2 weeks)"))
```
- **Note:** org-roam-ql query syntax may need adjustment — verify against actual API.
  The exact predicates (`backlink-count`, `file-mtime`, `todo`) need testing.

#### New Org Capture Templates (extend existing list)

Add to `org-capture-templates`:

```elisp
;; Fleeting note / inbox
("f" "Fleeting Note (Inbox)" entry
 (file "~/workspace/second-brain/org-roam/inbox.org")
 "** %U %?\n%i\n%a"
 :empty-lines 1)
```

#### New Org-Roam Capture Templates (extend existing list)

Add to `org-roam-capture-templates`:

```elisp
;; Meeting notes — minimal, auto-tagged :work: :hastodo:
("m" "meeting" plain
 "\n* Meeting Notes\n%?\n\n* Action Items\n** TODO \n"
 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                     "#+title: ${title}\n#+author: Jens Lordén\n#+date: %U\n#+filetags: :work:hastodo:\n")
 :unnarrowed t)

;; Tool / package evaluation
("e" "tool evaluation" plain
 "\n* ${title}\n\n** What it does\n%?\n\n** Pros\n- \n\n** Cons\n- \n\n** Alternatives & Comparison\n| Tool | Pros | Cons | Verdict |\n|------+------+------+---------|\n| ${title} | | | |\n| | | | |\n\n** Verdict\n/adopt · trial · reject · revisit/\n"
 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                     "#+title: ${title}\n#+author: Jens Lordén\n#+date: %U\n#+filetags: :tool-eval:\n")
 :unnarrowed t)

;; Troubleshooting log
("T" "troubleshooting" plain
 "\n* Problem\n%?\n\n* Environment\n- OS: \n- Tool version: \n\n* Steps Tried\n1. \n\n* Root Cause\n\n* Solution\n"
 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                     "#+title: ${title}\n#+author: Jens Lordén\n#+date: %U\n#+filetags: :troubleshooting:\n")
 :unnarrowed t)
```

#### Tag-Based Agenda Inclusion (:hastodo: auto-tagging)

Templates that include TODOs automatically add `:hastodo:` to filetags. The agenda
scans only these files plus the existing flat task files.

```elisp
;; Add roam files with :hastodo: tag to agenda-files dynamically
(defun rata-org-roam-agenda-files ()
  "Return list of org-roam files tagged with :hastodo:."
  (mapcar #'car
          (org-roam-db-query
           [:select [nodes:file]
            :from tags
            :left-join nodes
            :on (= tags:node-id nodes:id)
            :where (= tags:tag "hastodo")
            :group-by nodes:file])))

(defun rata-org-agenda-files-with-roam ()
  "Return combined agenda files: static list + roam :hastodo: files."
  (append org-agenda-files (rata-org-roam-agenda-files)))

;; Override org-agenda-files dynamically
(setq org-agenda-files-function #'rata-org-agenda-files-with-roam)
```
- Roam capture templates that include TODO headings set `:hastodo:` in filetags.
- The meeting template auto-includes `:hastodo:` (has action items section).
- Other templates: user manually adds `:hastodo:` if they add TODOs to a note.
- **Performance:** Only queries roam DB (SQLite) — fast even at 1,400+ nodes.

#### Org-Habit Setup (habits.org)

Proper org-habit entries in `habits.org` with SCHEDULED repeaters. Replaces
the checkbox-based habit tracking in the daily template.

```elisp
;; In org config — habits.org structure:
;; * Habits
;; ** TODO Workout
;;    SCHEDULED: <2026-02-24 Mon .+1d>
;;    :PROPERTIES:
;;    :STYLE: habit
;;    :END:
;; ** TODO Chinese Study
;;    SCHEDULED: <2026-02-24 Mon .+1d>
;;    :PROPERTIES:
;;    :STYLE: habit
;;    :END:
;; (etc. for: Reading, Supplements, Commit Dotfiles, Clear Inbox)
```
- habits.org already in `org-agenda-files` — habit graph appears in agenda.
- `org-habit-show-habits-only-for-today nil` already set (shows full streak).
- Daily template `Habits` section becomes optional quick-reference, not the source of truth.

#### Weekly Review Agenda Command

Custom agenda command for periodic review workflow:

```elisp
;; Add to org-agenda-custom-commands:
("r" "Weekly Review"
 ((tags-todo "+TIMESTAMP_IA<\"<-2w>\""
             ((org-agenda-overriding-header "Stale TODOs (>2 weeks old)")
              (org-super-agenda-groups
               '((:auto-tags t)))))
  (tags "+TIMESTAMP_IA>=\"<-7d>\""
        ((org-agenda-overriding-header "Notes Modified This Week")
         (org-agenda-files (rata-org-roam-agenda-files-all))
         (org-super-agenda-groups
          '((:auto-tags t)))))))
```
- `SPC o a` then `r` to trigger weekly review.
- Surfaces stale TODOs (open >2 weeks) and this week's activity.
- **Note:** The timestamp queries may need refinement — `TIMESTAMP_IA` matches
  inactive timestamps from `:CREATED:` properties. Alternative: use file mtime
  via a custom function.

#### Work/Personal Tag Filtering

Agenda already has `"w"` for Work Focus. Add consult-org-roam filtered search:

```elisp
;; Filtered roam search by tag
(defun rata-roam-search-work ()
  "Search org-roam notes filtered to :work: tag."
  (interactive)
  (let ((consult-org-roam-buffer-after-buffers t))
    (consult-org-roam-search nil "work")))

(defun rata-roam-search-personal ()
  "Search org-roam notes excluding :work: tag."
  (interactive)
  (consult-org-roam-search))

(rata-leader
  :states '(normal visual insert emacs)
  "orw" '(rata-roam-search-work     :which-key "search work notes")
  "orP" '(rata-roam-search-personal :which-key "search personal notes"))
```
- Meeting template auto-tags `:work:` — all meeting notes are work-filtered.
- `SPC o r w` searches only work-tagged roam notes.

#### Fleeting Notes Workflow

Dedicated `inbox.org` for quick thought capture. Weekly review processes inbox
into proper roam notes.

- **Capture:** `SPC o c f` dumps a timestamped entry into `inbox.org`.
- **Process:** During weekly review, open `inbox.org`, read each entry, and either:
  - Refile into an existing roam note (`org-refile`)
  - Create a new roam note from it (`org-roam-node-insert` or manual)
  - Delete if no longer relevant
- **inbox.org** lives at `~/workspace/second-brain/org-roam/inbox.org`.

```elisp
;; Add inbox to agenda for visibility
;; (already covered if inbox.org gets :hastodo: items)

;; Keybinding for quick inbox capture
(rata-leader
  :states '(normal visual insert emacs)
  "of" '((lambda () (interactive)
           (org-capture nil "f"))
         :which-key "fleeting note"))
```

#### Random Note in Dashboard (EXTEND init-dashboard)

Add random note discovery to the dashboard start page:

```elisp
;; In init-dashboard.el — add to dashboard sections
(defun rata-dashboard-random-note ()
  "Return a random org-roam node for dashboard display."
  (let* ((nodes (org-roam-db-query [:select [id title file] :from nodes
                                    :order-by (random)
                                    :limit 1]))
         (node (car nodes)))
    (when node
      (format "  Rediscover: %s" (nth 1 node)))))
```
- Shows a random note title on the dashboard for serendipitous rediscovery.
- Clickable — opens the note when selected.
- Refreshes on each dashboard visit (new random note each time).

---

## 5. Keybinding Map (Complete)

```
SPC SPC  execute-extended-command (consult, with savehist for recent-first)
SPC TAB  evil-switch-to-windows-last-buffer (toggle last buffer)
SPC /    consult-ripgrep (project search shortcut)

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
  SPC a k    kubernetes
    SPC a k k  kubel
    SPC a k n  kubel-set-namespace
    SPC a k c  kubel-set-context
    SPC a k p  kubel-port-forward-pod
    SPC a k l  kubel-get-pod-logs
  SPC a j    jupyter (ein)
    SPC a j r  ein:run (start jupyter)
    SPC a j l  ein:login (connect to server)
    SPC a j n  ein:notebooklist-open
  SPC a m    MCP
    SPC a m s  mcp-server-start
    SPC a m S  mcp-server-stop

SPC b    buffers
  SPC b b  consult-buffer (filtered by persp-mode)
  SPC b B  consult-buffer-other-window
  SPC b k  kill-current-buffer
  SPC b s  switch-to-buffer "*scratch*"
  SPC b m  bookmark-set
  SPC b M  consult-bookmark

SPC c    compile
  SPC c c  compile (prompts for command)
  SPC c r  recompile (repeats last)
  SPC c k  kill-compilation

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
  SPC e l  consult-flycheck
  SPC e n  flycheck-next-error
  SPC e p  flycheck-previous-error
  SPC e t  hl-todo-next (next TODO/FIXME)
  SPC e T  hl-todo-previous (prev TODO/FIXME)

SPC f    files
  SPC f f  consult-find
  SPC f r  consult-recent-file
  SPC f s  save-buffer
  SPC f d  dirvish
  SPC f L  consult-locate

SPC g    git
  SPC g g  magit-status
  SPC g G  consult-git-grep
  SPC g b  magit-blame
  SPC g l  magit-log
  SPC g f  magit-find-file
  SPC g d  magit-diff-buffer-file
  SPC g o  browse-at-remote (open on GitHub/GitLab)
  SPC g F  forge-list-pullreqs
  SPC g I  forge-list-issues

SPC h    help
  SPC h f  helpful-callable (describe-function replacement)
  SPC h v  helpful-variable
  SPC h k  helpful-key
  SPC h b  describe-bindings
  SPC h w  where-is (find key for command)
  SPC h m  consult-man
  SPC h I  consult-info
  SPC h P  esup (profile startup)
  SPC h E  explain-pause-mode (runtime profiler)

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

SPC l    layouts (persp-mode)
  SPC l l  persp-switch
  SPC l n  persp-add-new
  SPC l k  persp-kill
  SPC l r  persp-rename
  SPC l a  persp-add-buffer
  SPC l b  persp-switch-to-buffer
  SPC l s  persp-save-state-to-file
  SPC l L  persp-load-state-from-file

SPC L    lsp
  SPC L d  lsp-find-definition
  SPC L r  lsp-find-references
  SPC L n  lsp-rename
  SPC L a  lsp-execute-code-action
  SPC L f  lsp-format-buffer (manual)
  SPC L i  lsp-find-implementation
  SPC L t  lsp-find-type-definition
  SPC L s  lsp-workspace-restart
  SPC L L  lsp (manual start)

SPC m    mode-specific (local leader alias)
  SPC m m  consult-mode-command
  SPC m c  cargo (rustic-mode)
    SPC m c b  cargo-process-build
    SPC m c t  cargo-process-test
    SPC m c r  cargo-process-run
    SPC m c c  cargo-process-clippy
    SPC m c d  cargo-process-doc
    SPC m c f  cargo-process-fmt
    SPC m c a  cargo-process-add
    SPC m c B  cargo-process-bench
  SPC m t  test (python-ts-mode)
    SPC m t t  python-pytest-file
    SPC m t f  python-pytest-function
    SPC m t r  python-pytest-repeat
    SPC m t l  python-pytest-last-failed
    SPC m t p  python-pytest (project)
  SPC m p  pkgbuild (pkgbuild-mode)
    SPC m p b  rata-makepkg-build
    SPC m p s  rata-makepkg-srcinfo
    SPC m p n  rata-namcap-check
    SPC m p u  rata-updpkgsums
  SPC m a  ansible (ansible yaml)
    SPC m a d  ansible-doc
  SPC m r  restclient (restclient-mode)
    SPC m r r  restclient-http-send-current
    SPC m r R  restclient-http-send-current-raw
    SPC m r n  restclient-jump-next
    SPC m r p  restclient-jump-prev
    SPC m r c  restclient-copy-curl-command
  SPC m T  terraform (terraform-mode)
    SPC m T p  rata-terraform-plan
    SPC m T a  rata-terraform-apply
    SPC m T i  rata-terraform-init
  SPC m p  markdown preview (markdown-mode — note: pkgbuild-mode also uses SPC m p, keymaps are separate)
    SPC m p p  markdown-preview-mode (live preview in browser)

SPC n    narrow
  SPC n n  narrow-to-region
  SPC n f  narrow-to-defun
  SPC n w  widen

SPC o    org
  SPC o c  org-capture
  SPC o a  org-agenda
  SPC o t  org-todo-list
  SPC o d  org-deadline (add DEADLINE to heading at point)
  SPC o f  fleeting note (quick capture to inbox.org)
  SPC o b    blog/hugo
    SPC o b e  org-hugo-export-wim-to-md (export to hugo)
    SPC o b p  rata-hugo-preview (start server + open browser)
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
    SPC o r w  rata-roam-search-work     (search work-tagged notes)
    SPC o r P  rata-roam-search-personal (search non-work notes)
    SPC o r d    dailies
      SPC o r d c  org-roam-dailies-capture-today
    SPC o r t    transclusion
      SPC o r t a  org-transclusion-add
      SPC o r t A  org-transclusion-add-all
      SPC o r t r  org-transclusion-remove
      SPC o r t R  org-transclusion-remove-all
      SPC o r t e  org-transclusion-live-sync-start (edit source)
      SPC o r t m  org-transclusion-mode (toggle)
    SPC o r q    roam queries (org-roam-ql)
      SPC o r q o  rata-roam-orphan-notes (no backlinks)
      SPC o r q r  rata-roam-recent-notes (modified this week)
      SPC o r q w  rata-roam-work-notes (tagged :work:)
      SPC o r q t  rata-roam-stale-todos (open >2 weeks)

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
  SPC q q  save-buffers-kill-terminal (quit with save prompts)
  SPC q Q  kill-emacs (force quit, no prompts)

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
  SPC s p  consult-projectile-ripgrep (project search alias)
  SPC s w  wgrep-change-to-wgrep-mode (edit grep results)

SPC t    toggle
  SPC t t  vterm-toggle
  SPC t T  vterm-toggle-cd
  SPC t g  golden-ratio-mode (off by default)
  SPC t n  display-line-numbers-mode (toggle line numbers on/off)
  SPC t r  toggle relative/absolute line numbers
  SPC t l  toggle-truncate-lines (word wrap)
  SPC t s  jinx-correct (spell correct at point)
  SPC t w  writegood-mode (manual toggle when not in org/markdown)

SPC w    windows
  SPC w h  evil-window-left
  SPC w l  evil-window-right
  SPC w k  evil-window-up
  SPC w j  evil-window-down
  SPC w w  evil-window-next (cycle windows)
  SPC w r  evil-window-rotate-downwards (rotate layout)
  SPC w /  evil-window-vsplit
  SPC w -  evil-window-split
  SPC w d  evil-window-delete (kill window only)
  SPC w x  rata-kill-buffer-and-window (kill buffer + window)
  SPC w m  delete-other-windows (maximize/toggle)
  SPC w =  balance-windows
  SPC w u  winner-undo

SPC x    text manipulation
  SPC x a  align-regexp
  SPC x s  sort-lines
  SPC x c  count-words-region

SPC y    yank
  SPC y y  consult-yank-from-kill-ring

;  evil-nerd-commenter (normal/visual states, no SPC prefix)
```

---

## 6. Implementation Order & Status

### Completed

1. ~~**Migrate init-pkg.el to elpaca**~~ — DONE. Bootstrapped, `just run` works.
2. ~~**Create init-system.el**~~ — DONE. no-littering, exec-path-from-shell, recentf, ediff, TRAMP, shackle.
3. ~~**Fix init-evil.el**~~ — DONE. elpaca-wait, keybinding ordering, undo-fu, surround,
   commenter, avy, matchit, args, textobj-ts, evil-mc, smartparens.
4. ~~**Extend init-ui.el**~~ — DONE. doom-modeline, nerd-icons, rainbow-delimiters, helpful, golden-ratio, which-key 0.1s.
5. ~~**Extend init-completion.el**~~ — DONE. corfu + cape + nerd-icons-corfu + wgrep done.
   Embark keybindings wired.
6. ~~**Create init-dev.el**~~ — DONE. lsp-mode + lsp-ui + flycheck + apheleia + magit +
   forge + vterm + vterm-toggle + direnv + projectile + consult-projectile + dirvish + esup + flyspell done.
7. ~~**Create init-lang.el**~~ — DONE. All language modes + dap-mode + tree-sitter done.
8. ~~**Create init-snippets.el**~~ — DONE.
9. ~~**Create init-llm.el**~~ — DONE.
10. ~~**Extend init-org.el**~~ — DONE. All packages, keybinding fix, capture templates.
11. ~~**Create init-mcp.el**~~ — DONE (experimental, commented out).

### Remaining Work

Work these in any order — all can be done independently:

- [x] **init-system.el:** Add shackle, ediff config, TRAMP config, recentf-mode.
- [x] **init-ui.el:** Add rainbow-delimiters, helpful, golden-ratio (off by default).
      Change which-key delay 0.3s → 0.1s.
- [x] **init-evil.el:** Add evil-matchit, evil-args, evil-textobj-tree-sitter, evil-mc,
      smartparens. Disable electric-pair-mode.
- [x] **init-completion.el:** Add wgrep.
- [x] **init-dev.el:** Replace vterm with vterm-toggle. Add dirvish, esup, flyspell.
      Add TRAMP guards on apheleia. Add projectile-replace bindings (SPC p r/R).
- [x] **init-lang.el:** Add tree-sitter grammar setup + major-mode-remap-alist.
- [x] **init-persp.el:** Create new module — persp-mode with SPC L bindings.
- [x] **init.el:** Wrap each `(require 'init-xxx)` in `condition-case` for error recovery.
- [x] **Elpaca lockfile:** Add `just lock` / `just update` targets.
- [x] **justfile:** Add `just install-fonts`, `just install-grammars`, `just lock`, `just update`
      targets.

### Remaining Work (v4)

Work these in any order — all can be done independently:

- [x] **init-dev.el:** Replace `direnv` with `envrc` (buffer-local direnv). Drop `direnv` package.
- [x] **init-dev.el:** Add `diff-hl` (git gutter fringe indicators + magit integration).
- [x] **init-dev.el:** Add `consult-flycheck` (replaces `consult-flymake` for LSP buffers).
- [x] **init-dev.el:** Add `editorconfig` (respect `.editorconfig` in open-source projects).
- [x] **init-dev.el:** Add `browse-at-remote` (SPC g o — open file on GitHub/GitLab).
- [x] **init-lang.el:** Add `yaml-pro` (structural YAML editing for Helm charts / k8s manifests).
- [x] **init-lang.el:** Add `python-pytest` (SPC m t bindings for pytest).
- [x] **init-lang.el:** Add `pkgbuild-mode` (Arch Linux PKGBUILD syntax + validation).
- [x] **init-k8s.el:** Create new module — `kubel` + `kubel-evil` with SPC a k bindings.
- [x] **init.el:** Add `(require 'init-k8s)` to module load order (after init-lang).

### Remaining Work (v5) — ALL DONE

- [x] **init-lang.el:** Add `cargo.el` (SPC m c bindings for cargo build/test/clippy/run in rustic-mode).
- [x] **init-lang.el:** Add `makepkg helpers` (custom rata- functions for makepkg/namcap/updpkgsums, SPC m p bindings in pkgbuild-mode).
- [x] **init-lang.el:** Add `ansible-mode` + `ansible-doc` (Ansible playbook syntax + doc lookup).
- [x] **init-dev.el:** Add `restclient.el` + `restclient-jq` (HTTP client in .http files, SPC m r bindings).
- [x] **init-lang.el:** Add `ein` (Jupyter notebook support, SPC a j bindings).
- [x] **init-org.el:** Add `org-download` (paste/drag images into org files).
- [x] **init-system.el:** Add `popper.el` (popup management — M-` toggle/cycle/promote).
- [x] **init-dev.el:** Add `breadcrumb` (LSP header-line context: file > class > method).
- [x] **init-dev.el:** Replace `flyspell` with `jinx` (enchant-based spellcheck, SPC t s). Remove flyspell hooks.
- [x] **init-ui.el:** Add `hl-todo` (highlight TODO/FIXME/HACK in comments, SPC e t/T navigation).
- [x] **init-dev.el:** Add `explain-pause-mode` (runtime performance profiler, SPC h E).
- [x] **init-lang.el:** Add `polymode` (YAML + Go template multi-mode for Helm .tpl files).

### Remaining Work (v6) — ALL DONE

- [x] **init-dashboard.el:** Create new module — `dashboard.el` with logo (max-height 200px), quote, projects, bookmarks, custom widgets.
- [x] **init-dashboard.el:** Implement `rata-dashboard-insert-agenda` (7-day org-agenda overview).
- [x] **init-dashboard.el:** Implement `rata-dashboard-insert-roam-stats` (total notes + weekly activity from org-roam-db).
- [x] **init-dashboard.el:** Implement `rata-dashboard-insert-git-status` (dirty/clean for hardcoded repos).
- [x] **init-dashboard.el:** Add hardcoded `rata-dashboard-quotes` list (25 quotes: programming + Norse mythology mix).
- [x] **init-dashboard.el:** Wire Evil navigation (normal state in dashboard buffer) + `SPC b h` to open.
- [x] **init-dashboard.el:** Add refresh-on-revisit behavior (`dashboard-force-refresh t`).
- [x] **init.el:** Add `(rata-load-module 'init-dashboard)` to module load order (after init-org).

**Gotcha:** `(elpaca-wait)` must come *after* `use-package dashboard` (not before) so elpaca queues the install first. Delete stale `.elc` files after editing the module.

### Remaining Work (v7) — Org & Org-Roam Supercharge

- [x] **init-org.el:** Add `org-transclusion` (live content embedding, SPC o r t bindings).
- [x] **init-org.el:** Add `ox-hugo` (blog export, SPC o b e/p bindings + `rata-hugo-preview` function).
- [x] **init-org.el:** Add 3 new org-roam capture templates (meeting, tool-eval, troubleshooting) with auto-tagging.
- [x] **init-org.el:** Add fleeting note capture template + `inbox.org` workflow (SPC o f quick capture).
- [x] **init-org.el:** Implement tag-based agenda inclusion (`rata-org-roam-agenda-files` queries roam DB for `:hastodo:` tagged files).
- [x] **init-org.el:** Design `org-roam-ql` keybindings + query functions (orphan notes, recent notes, work notes, stale TODOs).
- [x] **init-org.el:** Add work/personal roam search filtering (`rata-roam-search-work`, SPC o r w).
- [ ] **init-org.el:** Set up proper org-habit entries in `habits.org` (SCHEDULED repeaters, `:STYLE: habit`).
- [x] **init-org.el:** Add weekly review agenda command (`"r"` in org-agenda-custom-commands: stale TODOs + week activity).
- [x] **init-dashboard.el:** Add random roam note to dashboard (`rata-dashboard-random-note`).
- [ ] **second-brain:** Create `inbox.org` file in org-roam directory.
- [ ] **second-brain:** Convert habit checkboxes in `habits.org` to proper org-habit entries with SCHEDULED repeaters.

### Remaining Work (v8) — Keybinding Overhaul

- [ ] **init-evil.el:** Swap `SPC l` / `SPC L` — `l` = layouts (persp-mode), `L` = LSP.
- [ ] **init-evil.el:** Move `SPC g g` from `consult-git-grep` to `magit-status`. Add `SPC g G` for `consult-git-grep`.
- [ ] **init-evil.el:** Add `SPC w x` (`rata-kill-buffer-and-window` — custom function), `SPC w w` (`evil-window-next`), `SPC w r` (`evil-window-rotate-downwards`).
- [ ] **init-evil.el:** Add `SPC TAB` (`evil-switch-to-windows-last-buffer`), `SPC /` (`consult-ripgrep` in project root).
- [ ] **init-evil.el:** Add `SPC b s` (switch to *scratch* buffer).
- [ ] **init-evil.el:** Add `SPC q q` (`save-buffers-kill-terminal`), `SPC q Q` (`kill-emacs`).
- [ ] **init-evil.el:** Add `SPC c` compile group: `SPC c c` (`compile`), `SPC c r` (`recompile`), `SPC c k` (`kill-compilation`).
- [ ] **init-evil.el:** Add `SPC x` text manipulation group: `SPC x a` (`align-regexp`), `SPC x s` (`sort-lines`), `SPC x c` (`count-words-region`).
- [ ] **init-evil.el:** Add `SPC t n` (`display-line-numbers-mode`), `SPC t r` (toggle relative/absolute line numbers), `SPC t l` (`toggle-truncate-lines`).
- [ ] **init-evil.el:** Add `SPC h b` (`describe-bindings`), `SPC h w` (`where-is`).
- [ ] **init-evil.el:** Add `SPC s p` (`consult-projectile-ripgrep` alias), `SPC s w` (`wgrep-change-to-wgrep-mode`).
- [ ] **init-org.el:** Add `SPC o d` (`org-deadline`).
- [ ] **init-persp.el:** Update keybindings from `SPC L` prefix to `SPC l` prefix.
- [ ] **init-dev.el:** Update LSP keybindings from `SPC l` prefix to `SPC L` prefix.
- [ ] **init-lang.el:** Add terraform compile wrappers (`rata-terraform-plan`, `rata-terraform-apply`, `rata-terraform-init`) with `SPC m T` bindings in `terraform-mode-map`.
- [ ] **init-lang.el:** Add `markdown-preview-mode` package with `SPC m p p` binding in `markdown-mode-map`.

---

## 7. Critical Gotchas & Decisions

### elpaca + daemon + load order
- `(elpaca-wait)` is mandatory after general.el and evil declarations. Without it,
  `rata-leader` may not be defined when later modules call it on first-install.
- When a module needs `:demand t`, place `(elpaca-wait)` **after** the `use-package`
  form, not before — elpaca must queue the install before it can wait on it.
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

### envrc vs direnv
- `envrc.el` is **buffer-local** (each buffer loads its own `.envrc`).
- `direnv-mode` is **global** (one env per Emacs session — last-visited project wins).
- For multi-project workflows (Python in one window, Rust in another), envrc is required.
- Drop-in replacement: remove `direnv` package, add `envrc`, call `(envrc-global-mode)`.

### diff-hl + magit
- Must hook `diff-hl-magit-pre-refresh` and `diff-hl-magit-post-refresh` to keep fringe
  in sync after magit operations.
- `diff-hl-flydiff-mode` shows changes in real-time (before save).
- In terminal mode, use `diff-hl-margin-mode` instead of fringe.

### kubel prerequisites
- `kubectl` must be on `$PATH`. Handled by `envrc` + `exec-path-from-shell`.
- `~/.kube/config` must exist with cluster contexts configured.
- `kubel-evil` provides evil keybindings inside the kubel buffer — load after kubel.

### yaml-pro + tree-sitter
- `yaml-pro-ts-mode` requires the `yaml` tree-sitter grammar (already in
  `treesit-language-source-alist`).
- Hooks into `yaml-ts-mode` (our default via remap). Does not conflict with lsp.

### python-pytest + projectile
- `python-pytest` uses `projectile-project-root` to find the project root.
- Looks for `pytest.ini`, `pyproject.toml`, `setup.cfg` for pytest config.
- Results appear in a compilation buffer (shackle can control placement).

### jinx replaces flyspell (v5)
- Remove all `flyspell-prog-mode` and `flyspell-mode` hooks when adding jinx.
- jinx requires `enchant` system package: `pacman -S enchant`.
- Uses vertico for correction suggestions (integrates with completion stack).
- Significantly faster than flyspell (no per-word subprocess calls).

### popper + shackle coexistence (v5)
- **shackle** controls initial buffer placement (where a popup appears).
- **popper** controls popup lifecycle (dismiss, cycle, promote to regular buffer).
- They complement each other — no conflict. Keep both.
- Consider removing some shackle `:popup t` rules if popper handles them better.

### polymode for Helm templates (v5)
- Polymode requires both `yaml-ts-mode` and `go-ts-mode` to be available.
- Add `go` grammar to `treesit-language-source-alist` if not already present.
- Auto-mode-alist pattern `/templates/.*\.ya?ml` catches Helm template files.
- May need `.dir-locals.el` for non-standard Helm chart directory structures.

### ein prerequisites (v5)
- `jupyter` must be installed in the Python venv (`pip install jupyter`).
- ein connects to Jupyter kernel — respects envrc for correct Python env.
- Results buffer placement can be controlled via shackle/popper.

### restclient workflow (v5)
- `.http` files can be checked into repos alongside code (API documentation).
- Variables defined at top of file: `:base-url = http://localhost:8080`.
- Chained requests: use `->` to pass response values to next request.
- `restclient-jq` enables jq filtering: add `:jq .data[]` after request.

---

### Tag-based agenda inclusion (v7)
- Roam capture templates with TODO sections auto-add `:hastodo:` to filetags.
- `rata-org-roam-agenda-files` queries roam DB (SQLite) for files with `:hastodo:` tag.
- Combined with static `org-agenda-files` via `org-agenda-files-function`.
- **Performance:** DB query is fast (~ms) even at 1,400+ nodes. Avoid scanning
  all roam files via `org-agenda-files` directory entry.
- **Gotcha:** `org-agenda-files-function` is not a standard variable — may need
  to use advice on `org-agenda-files` or `org-agenda-file-regexp` instead.
  Test with `(setq org-agenda-files (rata-org-agenda-files-with-roam))` first,
  then optimize with a hook if agenda becomes slow.

### org-transclusion + org-roam (v7)
- Transclusions reference roam nodes by ID: `#+transclude: [[id:abc123]]`.
- Transclusion content is read-only by default — use `org-transclusion-live-sync-start`
  to edit the source note from within the hub note.
- Works well for MOC (Map of Content) notes that aggregate atomic notes.
- Does NOT affect org-roam backlinks — transclusions don't create roam links.

### ox-hugo blog workflow (v7)
- Blog template sets `#+hugo_base_dir` pointing to Hugo project.
- `org-hugo-export-wim-to-md` (What I Mean) exports the current subtree or file.
- Hugo project lives at `~/workspace/second-brain/hugo/` — adjust if different.
- `rata-hugo-preview` starts Hugo dev server and opens browser.
- Prerequisites: `hugo` binary on `$PATH`.

### org-roam-ql query accuracy (v7)
- org-roam-ql API may differ from sketched queries. Test predicates against
  actual `org-roam-ql-search` function signature.
- Fallback: use raw `org-roam-db-query` with SQL for complex queries.
- Weekly review stale TODO detection via timestamps may need custom predicate.

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
| `flyspell` | Replaced by jinx (faster, enchant-based, vertico-integrated). |
| `verb.el` | Chose restclient.el for HTTP client workflow. |
| `code-cells.el` | Chose ein for full Jupyter notebook support. |
| `topsy.el` / `symbols-outline` | Chose breadcrumb (LSP-based header-line context). |
| `indent-bars` | Not selected — rely on tree-sitter highlighting for scope. |
| `pulsar` | Not selected — avy + evil jumps sufficient. |
| `ligature.el` | Not selected — plain text preferred. |

---

## 9. Out of Scope (Future Work)

| Item | Notes |
|------|-------|
| `jj.el` / Jujutsu UI | No mature Emacs package yet. Watch `https://github.com/bennyandresen/jujutsu.el` |
| `init-mcp.el` stable | Module exists but experimental. Enable once ecosystem stabilizes. |
| Per-project LSP config | `.dir-locals.el` patterns for LSP roots, env overrides. |
| ~~`org-roam-ql` keybindings~~ | Moved to v7 — keybinding design + query functions planned. |
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
| direnv               | **Replaced by envrc**            | No (replaced)                           |
| envrc                | Add to init-dev (replaces direnv)| Yes                                     |
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
| kubel                | Add to init-k8s                  | Yes                                     |
| kubel-evil           | Add to init-k8s                  | Yes                                     |
| diff-hl              | Add to init-dev                  | Yes                                     |
| yaml-pro             | Add to init-lang                 | Yes                                     |
| python-pytest        | Add to init-lang                 | Yes                                     |
| pkgbuild-mode        | Add to init-lang                 | Yes                                     |
| consult-flycheck     | Add to init-dev                  | Yes                                     |
| editorconfig         | Add to init-dev                  | Yes                                     |
| browse-at-remote     | Add to init-dev                  | Yes                                     |
| cargo                | Add to init-lang (v5)            | Yes                                     |
| ansible              | Add to init-lang (v5)            | Yes                                     |
| ansible-doc          | Add to init-lang (v5)            | Yes                                     |
| restclient           | Add to init-dev (v5)             | Yes                                     |
| restclient-jq        | Add to init-dev (v5)             | Yes                                     |
| ein                  | Add to init-lang (v5)            | Yes                                     |
| org-download         | Add to init-org (v5)             | Yes                                     |
| popper               | Add to init-system (v5)          | Yes                                     |
| breadcrumb           | Add to init-dev (v5)             | Yes                                     |
| jinx                 | Add to init-dev (v5, replaces flyspell) | Yes                               |
| hl-todo              | Add to init-ui (v5)              | Yes                                     |
| explain-pause-mode   | Add to init-dev (v5)             | Yes                                     |
| polymode             | Add to init-lang (v5)            | Yes                                     |
| flyspell             | **Replaced by jinx**             | No (replaced)                           |
| dashboard            | Add to init-dashboard (v6)       | Yes                                     |
| org-transclusion     | Add to init-org (v7)             | Yes                                     |
| ox-hugo              | Add to init-org (v7)             | Yes                                     |
| markdown-preview-mode | Add to init-lang (v8)           | Yes                                     |
