# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run with this config
just run

# Run with debug-init to catch startup errors
just debug

# Run in terminal (no GUI)
just cli

# Batch-load a single module to verify it parses
just load lisp/init-evil.el

# Byte-compile a single file for syntax checking
just check lisp/init-evil.el

# Full batch init (loads early-init + init; slow on first run due to elpaca)
just batch

# Run all tests (lint + compile + startup)
just test

# Run convention linting only (fast, no Emacs needed)
just lint

# Byte-compile all files
just compile

# Clean all generated artifacts (elpaca, eln-cache, etc.)
just clean

# Full reset: clean then run
just reset

# Find TODOs in .el files
just todos

# Install git pre-commit hook (one-time)
just install-hooks
```

## Architecture

The config follows a modular structure: `early-init.el` → `init.el` → modules in `lisp/`.

**Startup sequence:**
1. `early-init.el` — disables package.el (elpaca replaces it), removes UI chrome, sets `gc-cons-threshold` to max
2. `init.el` — bootstraps elpaca, resets GC after startup, adds `lisp/` to load-path, loads `custom.el`, then requires all modules via `rata-load-module`
3. Modules are loaded in strict order (dependencies matter):

```
init-pkg → init-system → init-ui → init-evil → init-completion →
init-dev → init-lang → init-rust → init-go → init-python → init-cpp →
init-cmake → init-terraform → init-just → init-docker → init-markdown →
init-yaml → init-ansible → init-jupyter → init-helm → init-pkgbuild →
init-casual → init-k8s → init-gamedev → init-snippets → init-llm →
init-irc → init-elfeed → init-persp → init-org → init-dashboard
```

**Key modules:**
- `init-pkg.el` — elpaca config, `use-package-always-ensure t`
- `init-system.el` — no-littering, exec-path-from-shell, savehist, recentf, ediff, TRAMP, shackle
- `init-ui.el` — gruvbox-dark-medium theme, relative line numbers, which-key, nerd-icons, golden-ratio
- `init-evil.el` — evil + evil-collection, `general.el` with `rata-leader` definer (`SPC`), winum; contains `(elpaca-wait)` to synchronize general + evil before downstream modules use them
- `init-completion.el` — orderless + vertico + marginalia + consult + embark + corfu
- `init-dev.el` — lsp-mode, apheleia (formatting), flycheck, magit, projectile, vterm, diff-hl
- `init-lang.el` — cross-cutting language infrastructure: tree-sitter (treesit-auto + grammar sources), dap-mode core, combobulate. Per-language config lives in dedicated `init-<lang>.el` files that load after this one.
- `init-<lang>.el` — one file per language: `init-rust`, `init-go`, `init-python`, `init-cpp`, `init-cmake`, `init-terraform`, `init-just`, `init-docker`, `init-markdown`, `init-yaml`, `init-ansible`, `init-jupyter`, `init-helm`, `init-pkgbuild`. Each contains the `use-package` forms, mode-local keybindings, and helper functions for that one language.
- `init-org.el` — org-agenda with org-super-agenda, org-roam, org-transclusion, ox-hugo

**Error handling:** `rata-load-module` wraps each require in `condition-case`. Failed modules are logged to `rata--failed-modules` and reported in the `*init-errors*` buffer at startup. With `--debug-init`, errors propagate for full backtraces.

## Coding Conventions

**Every `.el` file must begin with:**
```elisp
;;; -*- lexical-binding: t; -*-
```

**All packages must use `use-package`** with `:ensure t`. Use `:defer t` or implied deferral (`:bind`, `:hook`, `:commands`) unless startup-critical.

**Use-package structure:**
- `:init` — settings required *before* the package loads
- `:config` — settings required *after* the package loads
- `:custom` — user options (variables defined with `defcustom`)

**Naming:**
- Module files: `init-{category}.el`
- Functions/variables: `rata-{purpose}`
- Each module ends with `(provide 'init-{category})`

## Keybinding Conventions

- **Global leader:** `SPC` — **Local leader:** `,`
- Use `general.el` with the `rata-leader` definer
- Follow Spacemacs mnemonics: `SPC b` buffers, `SPC f` files, `SPC g` git, `SPC s` search, `SPC w` windows, `SPC o` org, `SPC l` layouts, `SPC L` LSP
- Always include `:which-key` descriptions
- All keybindings go in `:config` blocks with `:after general`

```elisp
(rata-leader
  :states '(normal visual)
  "x"  '(:ignore t :which-key "group name")
  "xx" '(some-command :which-key "description"))
```

## Adding a New Module

1. Create `lisp/init-{category}.el` with lexical-binding header and `(provide 'init-{category})` at the end
2. Add `(rata-load-module 'init-{category})` to `init.el` in the load order section
3. Use `use-package` for all external packages
4. Add keybindings to `rata-leader` groups or create new group prefixes
