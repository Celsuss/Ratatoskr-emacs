# Ratatoskr-emacs Agent Guidelines

This file contains build commands, code style guidelines, and architectural patterns for agentic coding agents working on this Emacs configuration.

## Commands

### Just Commands (Preferred)
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

### Emacs Commands (Manual)
```bash
# Run with this config
emacs --init-directory ~/workspace/Ratatoskr-emacs

# Recommended alias
alias emacs-dev="emacs --init-directory ~/workspace/Ratatoskr-emacs"

# Test syntax by loading init file
emacs --batch --eval "(load-file \"~/workspace/Ratatoskr-emacs/init.el\")"

# Test specific module
emacs --batch --eval "(load-file \"~/workspace/Ratatoskr-emacs/lisp/init-evil.el\")"
```

## Repository Context & Navigation

- **Primary Context Source:** Always consult `repomix-output.xml` first when you need to understand the repository structure, review module dependencies, or plan cross-file changes.
- **File Contents:** This file contains the complete, up-to-date, and packed context of all relevant code, optimized in XML format.
- **Context Refresh:** If you make significant changes or if the context seems stale, run `repomix` to regenerate the `repomix-output.xml` file before proceeding with further analysis.

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
init-casual → init-sql → init-k8s → init-gamedev → init-snippets →
init-llm → init-claude-loop → init-khoj → init-irc → init-elfeed → init-persp → init-org →
init-present → init-dashboard
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
- `init-claude-loop.el` — drives the `claude` CLI through a `- [ ]` checklist file, one headless `claude -p` process per task. Pure Elisp (no external package): `make-process` + a filter that decodes `--output-format stream-json` events into the `*claude-loop*` buffer, with the process exit code advancing the loop. The only module in the config with real async-process plumbing.
- `init-org.el` — org-agenda with org-super-agenda, org-roam, org-transclusion, ox-hugo
- `init-present.el` — reveal.js slide export via `org-re-reveal` under `SPC o p`. Decks are org-roam nodes in the flat roam root, identified by the `rata-reveal-deck-tag` (`:presentation:`) filetag rather than by directory. New decks come from the `presentation` org-roam capture template in `init-org.el` (key `r`) rather than a bespoke command; `rata-reveal-add-header` converts an existing note in place, mirroring `rata-toggle-hastodo-filetag`. `rata-reveal-export-all` finds them with an `org-roam-db-query` mirroring `rata-org-roam-agenda-files` in `init-org.el`. HTML output is redirected to `rata-reveal-export-dir` (outside org-roam) by shadowing `org-export-output-file-name`'s PUB-DIR argument, so no generated file lands in the note tree. Two `ox-html` advices make export non-interactive in this config: one suppresses `set-auto-mode` in `org-html-final-function` (it activates `mhtml-mode`, whose submodes trigger treesit-auto), the other binds `treesit-auto-install` to nil around `org-html-fontify-code` (src-block fontification otherwise prompts to install a missing grammar mid-export). Keybindings sit at top level, not in the deferred `use-package :config`, because `:after (ox general)` would leave them dead until the first manual export. reveal.js assets come from a CDN by default; `rata-reveal-install-local` clones a local copy and `rata-reveal-toggle-root` switches between them for offline presenting. Reuses the `simple-httpd` recipe declared in `init-org.el` to serve decks over HTTP.

**Error handling:** `rata-load-module` wraps each require in `condition-case`. Failed modules are logged to `rata--failed-modules` and reported in the `*init-errors*` buffer at startup. With `--debug-init`, errors propagate for full backtraces. Alternatively, use `when (file-exists-p ...)` for optional file loading and provide fallbacks for external dependencies.

## Code Style Guidelines

### File Structure
- **Mandatory:** All `.el` files must start with `;;; -*- lexical-binding: t; -*-`
- Use modular design in `lisp/` directory
- Each module should `(provide 'init-module-name)` at end
- Main `init.el` loads modules via `(rata-load-module 'init-module-name)`

### Package Management
- **Mandatory**: Use `use-package` for all external packages
- Always include `:ensure t` for automatic installation
- Use `:defer t` or implied deferral (`:bind`, `:hook`, `:commands`) unless startup-critical
- Structure:
  - `:init` — settings required *before* the package loads (pre-load)
  - `:config` — settings required *after* the package loads (post-load)
  - `:custom` — user options (variables defined with `defcustom`)

### Keybinding Conventions
- **Global Leader**: `SPC` (Space)
- **Local Leader**: `,` (Comma)
- Use `general.el` with the `rata-leader` definer pattern
- Follow Spacemacs mnemonics: `SPC b` buffers, `SPC f` files, `SPC g` git, `SPC s` search, `SPC w` windows, `SPC o` org, `SPC l` layouts, `SPC L` LSP
- Always include `:which-key` descriptions
- All keybindings go in `:config` blocks with `:after general`

```elisp
(general-create-definer rata-leader
                        :prefix "SPC")
(rata-leader
  :states '(normal visual)
  "x"  '(:ignore t :which-key "group name")
  "xx" '(some-command :which-key "description"))
```

### Naming Conventions
- Modules: `init-{category}.el` (e.g., `init-evil.el`, `init-ui.el`)
- Functions: `rata-{purpose}` or descriptive names
- Variables: `rata-{purpose}` for config-specific variables

### Import/Require Patterns
- Core modules loaded in `init.el` via `(rata-load-module 'init-category)`
- Package dependencies handled within `use-package` blocks
- Use `eval-when-compile` for compile-time dependencies

### UI/UX Principles
- Minimalist: Disable toolbars, scrollbars, menu bars by default
- Modern: Prefer Vertico/Corfu over Helm/Ivy, built-in features over external
- Vim-first: Evil mode with Spacemacs-style leader keys

### Performance Guidelines
- Set `gc-cons-threshold` to `most-positive-fixnum` during init
- Reset to reasonable value (`(* 2 1024 1024)`) after startup
- Use lazy loading (`:defer t`) wherever possible
- Native compilation support preferred

### Documentation
- Use `:which-key` descriptions for all keybindings
- Comment complex logic or non-obvious configurations
- Maintain `CONVENTIONS.md` for architectural decisions

## Adding New Modules
1. Create `lisp/init-{category}.el` with lexical-binding header
2. Follow `use-package` patterns with proper deferral
3. Add `(provide 'init-{category})` at the end
4. Add `(rata-load-module 'init-{category})` to `init.el` in the load order section
5. Add relevant keybindings to existing groups or create new ones

## Evil Mode Integration
- Set `evil-want-keybinding nil` before loading evil
- Use `evil-collection` for comprehensive Vim bindings
- Configure `evil-want-C-u-scroll t` for Vim-like scrolling
- Define keys for multiple states: `'(normal visual insert emacs)`

## Testing Your Changes
1. Load config: `emacs --init-directory ~/workspace/Ratatoskr-emacs`
2. Check for errors: `M-x toggle-debug-on-error`
3. Reload config: `SPC qr` (reload init.el binding)
4. Test keybindings with `which-key`

## Common Patterns

### Package with Keybindings
```elisp
(use-package example-package
  :defer t
  :general
  (rata-leader
    "e" '(:ignore t :which-key "example")
    "et" '(example-function :which-key "test"))
  :config
  (example-mode 1))
```

### Optional Feature
```elisp
(when (featurep 'some-feature)
  (use-package some-package
    :config
    (some-setup)))
```

### Custom Variable
```elisp
(setq rata-custom-setting t)
(use-package package
  :custom
  (package-variable rata-custom-setting))
```
