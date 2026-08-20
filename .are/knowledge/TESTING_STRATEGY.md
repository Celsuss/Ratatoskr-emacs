# Testing strategy — what each command actually proves

Source: `justfile`, `scripts/lint.sh`, `tests/run-tests.el`, `tests/claude-loop-e2e.el`,
plus observed output of every command. Confidence: HIGH.

The point of this page is the **right-hand column**. This project has decent tests; the
danger is over-reading them. Two of the five existing targets pass while genuinely broken
configurations sit in the tree.

Timings measured on this machine (Ubuntu 22.04, snap Emacs) with packages already
installed. First-ever run is minutes longer because elpaca builds everything.

---

## 1. The existing targets

| Target | Time | Proves | Does **not** prove |
|---|---|---|---|
| `just lint` | 0.5 s | lexical-binding header present; `(provide 'init-x)` matches filename; every top-level `defun`/`defvar`/`defcustom`/`defmacro` carries the `rata-` prefix | anything about behaviour. Pure text checks on 3 patterns |
| `just compile` | 24 s | each file **macro-expands and byte-compiles**, i.e. syntax and macro usage are valid | **almost nothing semantic.** Files are compiled with no package on `load-path`, so ~130 `Cannot load …` lines and hundreds of "not known to be defined" warnings are *expected*. `byte-compile-error-on-warn` is nil and the loop counts only process exit codes, so it exits 0 regardless of warnings. See [FAIL-0003](../memory/failures/FAIL-0003.md) |
| `just batch` | 70 s | `early-init.el` + `init.el` run to completion headlessly without aborting | that any module loaded. `rata-load-module` swallows failures by design, so a module can be entirely broken and `just batch` still exits 0. See [ARCHITECTURE.md](ARCHITECTURE.md) §3 |
| `just test-ert` | 78 s | **the real check.** Loads the full config, then runs the ERT suite (23 tests at bootstrap): no failed modules, every leader binding is a named `commandp`, no anonymous lambdas bound, no-littering redirects hold, and the claude-loop pure functions behave | nothing that needs a frame, a network, a credential, or a real subprocess. No integration is contacted |
| `just test-claude-loop` | 3.0 s | the claude-loop **state machine** end to end against a stub CLI under `emacs -Q`: happy path, exit-0 failures, retry-by-resume, exhaustion, wrong-box refusal, timeout + no orphan process, stdout/stderr noise, duplicate task text, wedge detection | the real `claude` CLI, its flags, or its `stream-json` schema. Everything is stubbed |
| `just test` | ~2.9 min | `lint` + `compile` + `batch` + `test-ert` | **it excludes `test-claude-loop`**, so the largest and only stateful module is outside the gate. Deliberate (the suite runs real processes and timers) but it is a gap. See [FAIL-0004](../memory/failures/FAIL-0004.md) |

## 2. The gate

`.githooks/pre-commit` runs `just test` before every commit. It is opt-in via
`just install-hooks`, which sets `core.hooksPath`.

**At ARE bootstrap `core.hooksPath` was unset — the gate was not active.** See
[FAIL-0005](../memory/failures/FAIL-0005.md). There is no CI, so the hook is the only
automated gate that exists.

## 3. ARE's risk-based levels

`scripts/are-verify.sh` composes the targets above. It adds no test framework.

| Level | Composition | Time | Use when |
|---|---|---|---|
| `fast` | `lint` + `test-claude-loop` + `are-audit` | ~4 s | mid-work; docs; any LOW-risk change; **the session-start hook** |
| `relevant` | `fast` + `compile` + `test-ert` | ~1.8 min | MEDIUM-risk; any `lisp/` change |
| `full` | `relevant` + `batch` (i.e. all of `just test`) | ~3 min | HIGH/CRITICAL; startup path; `justfile`; before ending any session that changed Elisp |

`fast` deliberately includes `test-claude-loop`, which `just test` omits: it needs no
packages, takes 3 s, and covers the CRITICAL area. That inversion is intentional.

## 4. Coverage gaps — stated so nobody claims otherwise

| Area | Status | Why |
|---|---|---|
| Elisp syntax, conventions, module load, keybinding integrity | **covered** | `lint` + `test-ert` |
| claude-loop state machine | **covered** | `claude-loop-e2e.el` |
| Interactive behaviour, GUI, frames, faces, popups | NOT TESTED | needs a display |
| Every network integration (Ollama, Khoj, Snowflake, GitHub, IRC, feeds, CDN) | NOT TESTED | needs network + credentials + homelab |
| External binaries (`lsp` servers, formatters, `kubectl`, `hugo`, `claude`) | NOT TESTED | not installed in the test environment; deferred loading hides their absence |
| The real `claude` CLI contract | NOT TESTED | stubbed on purpose |
| `terraform plan/apply`, `kubel` operations | NOT TESTED **and must stay that way** | see [../rules/SAFETY_RULES.md](../rules/SAFETY_RULES.md) |
| org-roam / second-brain read-write paths | NOT TESTED | operates on the operator's real notes; no fixture exists |
| Package version reproducibility | NOT TESTED | no committed lockfile |
| Daemon mode (`exec-path-from-shell` path) | NOT TESTED | the one code path gated on `(daemonp)` |

## 5. Where to add a test

Match the existing structure; do not introduce a framework.

| Kind of thing | Put it in |
|---|---|
| A pure function's behaviour | `tests/run-tests.el` as an `ert-deftest` |
| An invariant about the loaded config (a variable, a hook, a binding) | `tests/run-tests.el` — it has the full config loaded |
| claude-loop state-machine behaviour | `tests/claude-loop-e2e.el`, as a new numbered section using `rata-e2e--check` |
| A textual convention across files | `scripts/lint.sh` |
| A repo-wide invariant that needs no Emacs (docs drift, map coverage, gitignore traps) | `scripts/are-audit.sh` |
