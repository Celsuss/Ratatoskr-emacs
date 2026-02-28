# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run with this config
just run
# or: emacs --init-directory ~/workspace/Ratatoskr-emacs

# Run with debug-init to catch startup errors
just debug

# Run in terminal (no GUI)
just cli

# Test syntax without launching GUI
emacs --batch --eval "(load-file \"~/workspace/Ratatoskr-emacs/init.el\")"

# Test a specific module
emacs --batch --eval "(load-file \"~/workspace/Ratatoskr-emacs/lisp/init-evil.el\")"

# Clean all generated artifacts (elpa, eln-cache, etc.)
just clean

# Full reset: clean then run
just reset

# Find TODOs in .el files
just todos

# Run all tests (lint + compile + startup)
just test

# Run convention linting only (fast)
just lint

# Byte-compile all files
just compile

# Install git pre-commit hook (one-time)
just install-hooks
```

## Version Control

```bash
git status
git diff
git commit -m "description"
git log
```

## Architecture

The config follows a modular structure: `early-init.el` → `init.el` → modules in `lisp/`.

**Startup sequence:**
1. `early-init.el` — disables UI chrome, sets `gc-cons-threshold` to max before packages load
2. `init.el` — resets GC after startup, adds `lisp/` to load-path, loads `custom.el`, then requires all modules
3. Modules are loaded in order: `init-pkg` → `init-completion` → `init-ui` → `init-evil` → `init-org`

**Module responsibilities:**
- `init-pkg.el` — configures package archives (GNU ELPA, NonGNU, MELPA), initializes `package.el`, sets `use-package-always-ensure t`
- `init-ui.el` — gruvbox-dark-medium theme, relative line numbers, which-key (0.3s delay)
- `init-evil.el` — evil + evil-collection, `general.el` with `rata-leader` definer (`SPC`), winum for window navigation by number
- `init-completion.el` — orderless + vertico + marginalia + consult + embark stack
- `init-org.el` — org-agenda with org-super-agenda, org-roam, org-kanban; agenda files point to `~/workspace/second-brain/org-roam/`

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

- **Global leader:** `SPC`
- **Local leader:** `,`
- Use `general.el` with the `rata-leader` definer
- Follow Spacemacs mnemonics: `SPC b` buffers, `SPC f` files, `SPC g` git, `SPC s` search, `SPC w` windows, `SPC o` org
- Always include `:which-key` descriptions

```elisp
(rata-leader
  :states '(normal visual)
  "x"  '(:ignore t :which-key "group name")
  "xx" '(some-command :which-key "description"))
```

## Adding a New Module

1. Create `lisp/init-{category}.el` with lexical-binding header and `(provide 'init-{category})` at the end
2. Add `(require 'init-{category})` to `init.el` in the load order section
3. Use `use-package` for all external packages
4. Add keybindings to `rata-leader` groups or create new group prefixes
