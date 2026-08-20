# Ratatoskr-emacs Agent Guidelines

This file contains build commands, code style guidelines, and architectural patterns for agentic coding agents working on this Emacs configuration.

## MANDATORY — Autonomous Reliability Engineering (ARE)

**This section is not optional and applies to every session, whether or not the operator mentions ARE.**

This repository runs ARE: a thin reliability layer over the existing `just` targets and test
suites. Entry point: **`.are/INDEX.md`**. Operating manual: **`.are/SYSTEM.md`**.

### Every session, in order

1. **Read `.are/INDEX.md` before changing anything.** It is short and points at everything else.
2. **Generate task context before coding:**
   ```sh
   just are-context "what you are about to do"
   ```
   It reads git state, maps the changed paths through `.are/knowledge/MODULES.md`, and writes
   `.are/generated/CURRENT_CONTEXT.md` with the risk tier, the affected areas, the specific
   knowledge pages to open, and the relevant failure records. **Open only what it names.**
3. **Apply risk-based verification depth** (`.are/rules/RISK_RULES.md`,
   `.are/rules/VERIFICATION_RULES.md`):

   | Risk | Required |
   |---|---|
   | LOW | `just are-verify fast` (~4 s) |
   | MEDIUM | `just are-verify relevant` (~1.8 min) |
   | HIGH | `just are-verify full` (~3 min) |
   | CRITICAL | `full` + a new case in `tests/claude-loop-e2e.el` + operator approval |

4. **Run full verification before ending any session that changed code.** A session that
   touched a `.el` file may not end below `just are-verify relevant`.
5. **Report PASS / FAIL / NOT TESTED per area.** Never report PASS for a command you did not
   run. `just compile` proves syntax only; `just batch` exiting 0 does *not* mean modules
   loaded. Integrations (Ollama, Khoj, Snowflake, GitHub, IRC, feeds, the real `claude` CLI)
   are **always NOT TESTED** — nothing in `tests/` contacts a network service.
6. **Self-improve before closing — on every task, not only on failures.** Work through
   `.are/SYSTEM.md` §3: a failure record, a lesson, a decision, a missing path-map row, a
   check that would have caught it sooner, or a stale knowledge line to correct. Apply the
   cheap ones immediately. Prefer an executable test over prose. The repository must be
   harder to break than it was when the session started.

### Efficient context use — a requirement, not a preference

- Start from `.are/generated/CURRENT_CONTEXT.md` and the tables in `.are/knowledge/MODULES.md`.
- Prefer deterministic retrieval (`git diff --name-only`, `grep`, the path map) over scanning.
- **Do not** load the whole knowledge base, re-derive the architecture, or re-read unchanged
  files "to confirm".
- **Do not read `SPEC.md` whole** — 2408 lines, drifted, historical intent only. `grep` it.
- Prefer running a test over reasoning about whether behaviour changed.

### Before anything destructive

`.are/rules/SAFETY_RULES.md` lists what is never done autonomously here: `just clean` /
`reset` / `update`, git commits and history, `~/.authinfo.gpg`, anything under
`~/workspace/second-brain/`, `terraform apply`, mutating `kubectl`, and widening the
claude-loop's permissions. `lisp/init-claude-loop.el` is the only CRITICAL area — it runs a
headless agent with `--permission-mode acceptEdits` and an operator-supplied shell command.

### Known open items (do not rediscover these)

`.are/memory/FAILURE_INDEX.md` has the full list. The live ones:
two checkouts of this repo exist and the docs below point at the stale one (FAIL-0001);
`core.hooksPath` is unset so the pre-commit gate is off and there is no CI (FAIL-0005).

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
- `init-claude-loop.el` — drives the `claude` CLI through a `- [ ]` checklist file, one headless `claude -p` process per task. Pure Elisp (no external package): `make-process` + a filter that decodes `--output-format stream-json` events into the `*claude-loop*` buffer. The only module in the config with real async-process plumbing, and the only one with its own state machine, so it has conventions of its own:
  - **Control flow is a trampoline, not a callback chain.** Sentinels and timers only record an outcome and call `rata-claude-loop--later`; every transition then runs from a zero-delay timer at top level. Errors signalled inside a sentinel are demoted to a `*Messages*` line, and marking a checkbox calls `save-buffer` and `org-todo` (arbitrary hook code) — neither belongs in a process callback. `rata-claude-loop--guard` turns any error into a visible halt.
  - **Staleness is handled by `:epoch`**, an integer bumped on every spawn and every stop. Callbacks and timers capture the epoch they were created under and no-op on mismatch; one check covers the child, the stderr pipe, the timeout timer, the grace-period kill and the pending step timer. `:outcome` is write-once per attempt so a timeout's verdict survives the kill it causes.
  - **Success is decided from the `result` event, never the exit code alone** (`rata-claude-loop--classify`). `claude -p` exits 0 for a task that gave up and for one whose edits were all silently denied. `:pending` must be flushed at EOF — the CLI does not newline-terminate its last line, and that line carries the result event.
  - **Failures retry by resuming the session** (`--resume` with the captured `session_id`), bounded by `rata-claude-loop-max-attempts`. `--resume` inherits no configuration, so `rata-claude-loop--common-args` exists to re-pass every flag.
  - **Checkboxes are matched by text, not line number**, and an ambiguous match halts rather than ticking the wrong box.
  - Its output buffer derives from `special-mode`, which is in none of evil's state lists — so buffer-local keys go through `evil-define-key*` (the function form; `evil-define-key` is a macro and would compile to a broken function call), not plain `define-key`.
  - **A failed task does not have to end the run.** `rata-claude-loop-on-task-failure`
    is `halt` (default, right when you are watching), `skip` (mark the box `[-]`, record
    it, continue — right when you are not) or `ask`. A box that cannot be marked
    unambiguously halts whatever the policy says: an open box is handed straight back as
    the next task, so skipping without marking would run it forever. A single-task run
    always halts.
  - **Spend is accumulated, not merely displayed.** `--max-budget-usd` is per invocation,
    so with retries and fifty tasks it bounds nothing useful.
    `rata-claude-loop-run-budget-usd` is the run-level cap, checked in
    `rata-claude-loop--advance` — between tasks, never mid-task, because the task in
    flight has already been paid for and cutting it off before its verify and its
    checkbox wastes that spend rather than saving it.
  - **The prompt carries the detail written under the task**, not just the checklist
    line: indented lines under a Markdown checkbox, the entry body of an Org TODO
    (drawers and planning lines dropped). Read once, when the task starts, so a resumed
    retry cannot be answering a description that has since been edited.
  - **Every run is journalled** as JSON lines under `rata-claude-loop-journal-directory`.
    The state machine lives in memory; the session ids are the one thing a restart cannot
    recompute and the only way back into a task by hand. A journal write failure disables
    journalling and reports once — it can never stop a run.
  - **The verify command is baselined before the first task** (`rata-claude-loop-verify-baseline`).
    A gate that is already red says nothing about a task, and every task would spend its
    retries being told to fix a break it inherited. The baseline's output is deliberately
    discarded rather than kept as retry feedback.
  - Tests: pure functions in `tests/run-tests.el`; the state machine in `tests/claude-loop-e2e.el` via `just test-claude-loop`, against a stub CLI with no API calls.
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
- **Global leader keys go at top level in `(with-eval-after-load 'general …)`, never inside a
  deferred `use-package`'s `:config`.** `:config` runs when the *package* loads, not when the
  module loads, so a leader key written there does not exist until something happens to pull
  the package in — and for a package reached only through its own keybinding, that is never.
  `:commands` autoloads make the command callable from `M-x`; they do nothing for the key.
  This cost `SPC p f` entirely and left 86 other leader keys dead at startup — see
  [`FAIL-0009`](.are/memory/failures/FAIL-0009.md) and L-011 in `.are/memory/LESSONS.md`.
  The one exception is a binding scoped with `:keymaps` to a mode whose activation loads the
  package anyway (the local-leader `,`/`m`-prefix bindings in the `init-<lang>.el` files).
- Regression check: `rata-test-keybindings-live-after-init` in `tests/run-tests.el` resolves a
  curated set of keys against a fully initialised Emacs. Add a key there when you add an
  entry point you would notice being dead.

```elisp
(general-create-definer rata-leader
                        :prefix "SPC")

;; Global leader keys — top level, so they exist from startup.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "x"  '(:ignore t :which-key "group name")
    "xx" '(some-command :which-key "description")))
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
