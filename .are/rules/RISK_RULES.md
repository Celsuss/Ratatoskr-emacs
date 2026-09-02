# Risk rules

Classify every change before implementing it. The tier decides verification depth
([VERIFICATION_RULES.md](VERIFICATION_RULES.md)) and whether approval is needed
([SAFETY_RULES.md](SAFETY_RULES.md)).

`just are-context` prints the tier for you by looking the changed paths up in
[../knowledge/MODULES.md](../knowledge/MODULES.md). **The tier is the maximum over all
changed paths.** Override upward freely; overriding downward needs a stated reason.

---

## The tiers

### CRITICAL — approval required before it lands

- Anything in `lisp/init-claude-loop.el` that touches a safety guard listed in
  [../knowledge/CLAUDE_LOOP.md](../knowledge/CLAUDE_LOOP.md) §2: the `$HOME` root refusal,
  checkbox disambiguation, `result`-event classification, EOF flush, attempt bounds, epoch
  staleness, or the read-only git baseline.
- Widening what the headless agent may do: adding to `rata-claude-loop-extra-args`,
  changing `--permission-mode`, removing `rata-claude-loop-max-tasks`, or defaulting
  `rata-claude-loop-task-budget-usd` to unbounded where it was bounded.
- Adding any command that performs a destructive external operation without confirmation
  (see SAFETY_RULES §2).
- Rewriting git history, or anything touching `~/.authinfo.gpg` handling.

### HIGH

- `init.el`, `early-init.el`, `lisp/init-pkg.el` — the startup path. An error here costs
  the operator their editor.
- `lisp/init-evil.el` — contains the `(elpaca-wait)` that every later module's keybindings
  depend on (invariant I1).
- `lisp/init-system.el` — `no-littering`, `auth-source`, backups, autosave, TRAMP.
- `lisp/init-sql.el` — corporate identity and a live warehouse connection.
- `justfile`, `scripts/lint.sh`, `scripts/are-*.sh`, `tests/*`, `.githooks/*` — **the
  verification system itself.** Weakening a check is worse than the bug it would have
  caught, because it is silent.
- Anything in `lisp/init-claude-loop.el` that is not CRITICAL.

### MEDIUM

- Any other `lisp/init-*.el` that has real logic, state, network reach, or writes outside
  the repo: `init-org`, `init-present`, `init-dev`, `init-completion`, `init-ui`,
  `init-dashboard`, `init-persp`, `init-llm`, `init-khoj`, `init-irc`, `init-elfeed`,
  `init-lang`, `init-gamedev`, `init-k8s`, `init-ansible`.
- `feeds.org` — a data file that is also `init-elfeed.el`'s input contract. A renamed
  tag makes a filter view return zero entries, and dropping the root `:elfeed:` tag
  hides all 94 feeds; neither raises an error. Guarded by
  `rata-test-elfeed-*` in `tests/run-tests.el`, which is why the tier is MEDIUM and
  not HIGH. See L-025.
- `AGENTS.md`, `CLAUDE.md`, `.are/*`, `.claude/*`, `.gitignore` — instructions and
  packaging. Wrong here means every future session is wrong.

### LOW

- A single-language leaf module (`init-rust`, `init-go`, `init-python`, `init-cpp`,
  `init-cmake`, `init-terraform`, `init-just`, `init-docker`, `init-markdown`,
  `init-yaml`, `init-jupyter`, `init-helm`, `init-pkgbuild`, `init-casual`,
  `init-snippets`, `init-mcp`).
- `snippets/`, `README.org`, `SPEC.md`, `LICENSE`, `logo.png`.
- **Not `feeds.org`.** It looks like a data file, but its org tags are the input
  contract of `init-elfeed.el` and every way of breaking them is silent — see the
  MEDIUM entry above and L-025.

## Escalators — apply on top of the path tier

Raise one tier if the change:

- adds or alters a `make-process` / `start-process` / `call-process` / `compile` call, or
  any string that reaches a shell;
- adds a keybinding that can modify state outside Emacs;
- reads or writes anything under `~/workspace/second-brain/` (the operator's notes);
- transmits buffer contents to a non-local service;
- touches `.gitignore`, or creates a file that a `.gitignore` rule could swallow;
- removes, skips, or loosens an existing test, lint check or audit check;
- changes module load order in `init.el`;
- moves keybindings into a deferred `use-package :config` block (invariant I2 — three
  modules carry explicit workarounds for this, see [../memory/LESSONS.md](../memory/LESSONS.md)).

## De-escalator

Lower one tier (never below LOW) only if **all** hold: the change is confined to comments
or docstrings; no form is added, removed or reordered; and `just are-verify fast` passes.
Say so explicitly in the report.
