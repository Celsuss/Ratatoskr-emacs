#!/usr/bin/env bash
# are-session-start.sh --- SessionStart hook: run fast verification, inject the result.
#
# Wired up in .claude/settings.json. Runs `are-verify fast --quiet` (~4 s, no packages
# needed, no network) and emits the Claude Code hook JSON that injects the summary into the
# session, so a pre-existing regression is the first thing any session sees rather than
# something discovered after an hour of work and misattributed to that hour's edits.
#
# Always exits 0: a failing verification is information for the session, not a reason to
# stop it from starting. The FAIL text is what carries the signal.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 0

if output="$(./scripts/are-verify.sh fast --quiet 2>&1)"; then
    verdict="clean"
else
    verdict="FAILING"
fi

context="$(printf '%s\n' \
    "ARE is active in this repository. Entry point: .are/INDEX.md — read it before changing code." \
    "" \
    "Fast verification at session start ($verdict):" \
    "" \
    "$output" \
    "" \
    "Required of this session (.are/rules/VERIFICATION_RULES.md):" \
    "  1. Run 'just are-context \"<task>\"' before coding; it prints the risk tier and the" \
    "     exact knowledge to read. Do not read the knowledge base wholesale." \
    "  2. Verify at the depth the tier demands. Any session that changed a .el file must" \
    "     end with at least 'just are-verify relevant'." \
    "  3. Report PASS / FAIL / NOT TESTED per area. Integrations are always NOT TESTED." \
    "  4. Before closing, apply the self-improvement checklist in .are/SYSTEM.md section 3.")"

jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
