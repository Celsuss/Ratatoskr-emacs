# just/test.just — linting and test suites.
#
# `compile' and `batch' live in just/emacs.just; imports are flat, so `test'
# depending on them across files resolves normally.

# Run convention linting (fast, no Emacs needed)
lint:
    ./scripts/lint.sh

# Run ERT tests (keybinding safety + module health + no-littering)
# stdin is /dev/null on purpose: a load-time prompt (vterm's "Compile
# vterm-module?") then errors out instead of hanging on a socket (FAIL-0022).
test-ert:
    {{emacs_bin}} --init-directory {{init_dir}} --batch \
        -l ert \
        -l tests/run-tests.el < /dev/null

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
test-claude-loop:
    RATA_ROOT={{init_dir}} {{emacs_bin}} -Q --batch -l tests/claude-loop-e2e.el

# The claude-loop agent-shell (ACP) backend, end to end against a scripted stub
# ACP agent (tests/fake-claude-acp, python3).  Loads agent-shell, acp and
# shell-maker from elpaca/builds, so it is run by hand, not part of `test'.
test-claude-loop-acp:
    RATA_ROOT={{init_dir}} {{emacs_bin}} -Q --batch -l tests/claude-loop-acp-e2e.el

# Run all tests (lint + compile + startup + ERT)
test: lint compile batch test-ert test-work-agenda
