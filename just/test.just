# just/test.just — linting and test suites.
#
# `compile' and `batch' live in just/emacs.just; imports are flat, so `test'
# depending on them across files resolves normally.

# Run convention linting (fast, no Emacs needed)
lint:
    ./scripts/lint.sh

# Run ERT tests (keybinding safety + module health + no-littering)
test-ert:
    {{emacs_bin}} --init-directory {{init_dir}} --batch \
        -l ert \
        -l tests/run-tests.el

# Render the "w" work agenda over org fixtures and assert on the visible lines.
# Separate from `test-ert': it puts org-super-agenda on load-path by hand, because
# elpaca never activates an `:after org' package in batch. Fixtures live in
# temporary-file-directory — this touches nothing under second-brain.
test-work-agenda:
    {{emacs_bin}} --init-directory {{init_dir}} --batch \
        -l ert \
        -l tests/work-agenda-render.el

# Runs real processes and timers, so it is kept out of `test'.
# Drive the claude-loop state machine against a stub CLI (no API calls).
# It IS in `are-verify fast': it needs no packages and takes 3s. See FAIL-0004.
test-claude-loop:
    RATA_ROOT={{init_dir}} {{emacs_bin}} -Q --batch -l tests/claude-loop-e2e.el

# Run all tests (lint + compile + startup + ERT)
# Left exactly as it was on purpose — README, AGENTS.md and habit refer to it.
# The pre-commit gate runs `are-verify full', which is a superset. See DECISIONS D-004.
test: lint compile batch test-ert test-work-agenda
