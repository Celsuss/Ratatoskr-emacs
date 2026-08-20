# Architecture

Source: `early-init.el`, `init.el`, `lisp/*.el`, read directly. Confidence: HIGH.

`AGENTS.md` §Architecture already lists every module and what it does, and it is
accurate as of commit `1d38bd8` (verified: its load-order list matches `init.el`
line for line). **This page does not repeat it.** It records the invariants that
`AGENTS.md` states as prose and that a change can silently violate.

---

## 1. Startup sequence

```
early-init.el   package.el off · frame chrome off · gc-cons-threshold = most-positive-fixnum
                native-comp async jobs capped at 2
      ↓
init.el         emacs-startup-hook resets GC to 16 MB
                elpaca bootstrap (clone + byte-compile + autoloads on first run)
                elpaca-use-package-mode
                (elpaca-wait)                     ← bootstrap queue drains here
                load-path += lisp/
                custom.el loaded if present
                35 × (rata-load-module 'init-…)   ← strict order, see below
                (elpaca-wait)                     ← everything installed before startup hooks
      ↓
emacs-startup-hook  rata-report-init-errors → *init-errors* buffer if anything failed
```

## 2. Invariants — a change that breaks one of these is at least HIGH risk

| # | Invariant | Where it lives | How it fails |
|---|---|---|---|
| I1 | `general` and `evil` are loaded before any module that binds keys | the `(elpaca-wait)` at `lisp/init-evil.el:203` | remove or move it and every later `rata-leader` form binds into nothing — silently, with no error |
| I2 | Keybindings must not sit in a **deferred** `use-package :config` block if they are the entry point to that package | `AGENTS.md`; worked around explicitly in `init-sql.el` and `init-present.el` | the leader key stays unbound until the package happens to load, i.e. forever |
| I3 | Module load order is a dependency order, not a preference | `init.el` §6 | `init-lang` must precede every `init-<lang>`; `init-org` must precede `init-present` |
| I4 | Every module is `require`d through `rata-load-module`, never bare `require` | `init.el` | a bare `require` that fails aborts the rest of init instead of being logged |
| I5 | A failing module must degrade, not abort | `rata-load-module`'s `condition-case` | with `--debug-init` errors deliberately propagate; that is the debugging path, not a bug |
| I6 | Nothing generated may land in the repo | `no-littering` in `init-system.el` + `.gitignore` | backups/auto-saves/state appear as untracked files and get swept into a commit |
| I7 | Every `lisp/init-*.el` is either loaded by `init.el` or knowingly unloaded | `init.el`; enforced by `rata-test-init-loads-every-module` | a module is added, never wired in, and quietly does nothing |

Currently the only knowingly-unloaded module is `lisp/init-mcp.el` (commented out in
`init.el` as experimental). Verified: no other orphans.

## 3. Error handling

`rata-load-module` wraps each `require` in `condition-case`, pushes
`(module . error-string)` onto `rata--failed-modules`, and `rata-report-init-errors`
renders that list into an `*init-errors*` buffer on `emacs-startup-hook`.

**This is a reliability feature with a verification consequence:** a broken module does
not fail startup. `just batch` will exit 0 with a module missing. The thing that actually
catches it is `rata-test-no-failed-modules` in `tests/run-tests.el`, which asserts
`rata--failed-modules` is empty. Never conclude "startup is fine" from `just batch` alone.

## 4. Background work

There is no job queue. All asynchronous work is Emacs timers and subprocesses:

| What | Where | Notes |
|---|---|---|
| elfeed refresh, every 1800 s | `lisp/init-elfeed.el:97` | network; guarded against duplicate registration |
| `gcmh` adaptive GC, 5 s idle | `lisp/init-system.el` | |
| `super-save` autosave, 10 s idle | `lisp/init-system.el` | writes operator buffers to disk |
| `auto-revert`, notify-based | `lisp/init-system.el` | exists so external edits (Claude Code) show up |
| claude-loop timeouts, kill grace, trampoline steps | `lisp/init-claude-loop.el` | epoch-guarded; see [CLAUDE_LOOP.md](CLAUDE_LOOP.md) |
| hugo server, godot editor, reveal.js server | `init-org.el`, `init-gamedev.el`, `init-present.el` | `start-process` / `make-process` |

Only `init-claude-loop.el` has a state machine. Everything else is fire-and-forget.

## 5. Conventions

Owned by `AGENTS.md`. Enforced mechanically by `scripts/lint.sh`:
lexical-binding header, `(provide 'init-<name>)` matching the filename, `rata-` prefix on
every top-level `defun`/`defvar`/`defcustom`/`defmacro`. Anything `lint.sh` does not check
is convention by review only.
