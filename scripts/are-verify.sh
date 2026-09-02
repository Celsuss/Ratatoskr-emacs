#!/usr/bin/env bash
# are-verify.sh --- risk-based verification driver.
#
#   ./scripts/are-verify.sh [fast|relevant|full]
#   just are-verify [fast|relevant|full]
#
# Composes the project's existing `just` targets into three levels. It adds no test
# framework and re-implements nothing; if a step is wrong, fix it in the justfile.
#
# Each step prints what it PROVES and what it does NOT prove, next to its result. That is
# deliberate: L-003 — a green check whose scope is not stated will be over-read. The
# summary table is meant to be pasted straight into a session report.
#
# Levels (rules/VERIFICATION_RULES.md s1):
#   fast      LOW risk, mid-work, docs, session-start hook   ~4 s, no packages needed
#   relevant  MEDIUM risk, any lisp/ change                  ~1.8 min
#   full      HIGH / CRITICAL, startup path, end of session  ~3 min

set -uo pipefail   # not -e: a failing step must still be reported, not abort the run

# shellcheck source=scripts/are-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/are-lib.sh"

LEVEL="fast"
QUIET=0
for arg in "$@"; do
    case "$arg" in
        fast | relevant | full) LEVEL="$arg" ;;
        -q | --quiet) QUIET=1 ;;   # summary only — used by the session-start hook
        *)
            echo "usage: $0 [fast|relevant|full] [--quiet]" >&2
            exit 2
            ;;
    esac
done

cd "$ARE_REPO_ROOT"

failed=0
results=()

# run STEP_NAME PROVES -- COMMAND...
run() {
    local name="$1" proves="$2" status
    shift 3   # name, proves, the literal --
    if [ "$QUIET" -eq 1 ]; then
        if "$@" >/dev/null 2>&1; then status=PASS; else status=FAIL; fi
    else
        echo
        echo "=============================================================="
        echo "  $name"
        echo "  proves: $proves"
        echo "=============================================================="
        if "$@"; then status=PASS; else status=FAIL; fi
    fi
    results+=("$name|$status|$proves")
    [ "$status" = FAIL ] && failed=$((failed + 1))
    return 0
}

if [ "$QUIET" -eq 0 ]; then
    echo "ARE verification — level: $LEVEL"
    echo "checkout: $ARE_REPO_ROOT  branch: $(are_branch) @ $(are_head)"
fi

# --- fast: no packages required, ~4 s -------------------------------------------
run "lint" "3 textual conventions (lexical-binding, provide, rata- prefix)" -- \
    ./scripts/lint.sh

run "claude-loop-e2e" "the CRITICAL module's state machine, vs a stub CLI" -- \
    just test-claude-loop

run "are-audit" "repo-wide ARE invariants, docs drift, gate state, hygiene" -- \
    ./scripts/are-audit.sh

# --- relevant: needs packages installed ------------------------------------------
if [ "$LEVEL" != "fast" ]; then
    run "compile" "syntax and macro expansion ONLY (no packages on load-path; FAIL-0003)" -- \
        just compile

    run "ert" "the ERT suite against the fully loaded config" -- \
        just test-ert

    run "work-agenda" "the \"w\" agenda's rendered output, over org fixtures" -- \
        just test-work-agenda
fi

# --- full -------------------------------------------------------------------------
if [ "$LEVEL" = "full" ]; then
    run "batch-startup" "init completes with no load-order warning; NOT that modules loaded (ERT)" -- \
        just batch-strict
fi

# --- Report -----------------------------------------------------------------------
if [ "$QUIET" -eq 1 ]; then
    # Compact form for the session-start hook: one line per step, then the verdict.
    echo "ARE fast verification ($LEVEL) — $(are_branch) @ $(are_head)"
    for r in "${results[@]}"; do
        IFS='|' read -r name result _proves <<<"$r"
        printf '  %-18s %s\n' "$name" "$result"
    done
    if [ "$failed" -gt 0 ]; then
        echo "REGRESSION: $failed step(s) failing BEFORE you changed anything."
        echo "Investigate before starting work; do not attribute it to your own edits."
        echo "Detail: just are-verify $LEVEL"
        exit 1
    fi
    echo "OK. Note: 'fast' loads no packages — module health is NOT TESTED until"
    echo "'just are-verify relevant'. Entry point: .are/INDEX.md"
    exit 0
fi

echo
echo "=============================================================="
echo "  ARE VERIFICATION REPORT — level: $LEVEL"
echo "=============================================================="
printf '%-18s %-6s %s\n' "AREA" "RESULT" "SCOPE"
printf '%-18s %-6s %s\n' "------------------" "------" "-----------------------------------"
for r in "${results[@]}"; do
    IFS='|' read -r name result proves <<<"$r"
    printf '%-18s %-6s %s\n' "$name" "$result" "$proves"
done

echo
echo "NOT TESTED at any level — do not report these as PASS:"
echo "  integrations   every network service (Ollama, Khoj, Snowflake, GitHub, IRC, feeds)"
echo "  binaries       lsp servers, formatters, kubectl, hugo, the real claude CLI"
echo "  gui            interactive behaviour, frames, faces, popups (headless)"
echo "  operator-data  org-roam / second-brain read-write paths. Exception: the \"w\""
echo "                 agenda is rendered over fixtures by the work-agenda step"
echo "  daemon         the exec-path-from-shell path gated on (daemonp)"
if [ "$LEVEL" = "fast" ]; then
    echo "  modules        NOT loaded at this level — 'fast' loads no packages."
    echo "                 A broken module is invisible here. Use 'relevant' before"
    echo "                 claiming anything about module health."
fi

echo
if [ "$failed" -gt 0 ]; then
    echo "RESULT: FAIL — $failed step(s) failed at level '$LEVEL'."
    echo "Separate pre-existing failures from ones you caused: git stash, re-run, git stash pop."
    exit 1
fi
echo "RESULT: PASS — all steps passed at level '$LEVEL'."
echo "This is not 'everything works'. Read the NOT TESTED list above before reporting."
