#!/usr/bin/env bash
# are-lib.sh --- shared helpers for the ARE scripts.
#
# Sourced by are-context.sh, are-audit.sh and are-verify.sh. Not executable on its own.
#
# The authoritative path -> area/risk/verify/knowledge map is the markdown table in
# .are/knowledge/MODULES.md. It is parsed here rather than duplicated into a config file,
# so there is exactly one source of truth and it stays human-readable.

ARE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARE_DIR="$ARE_REPO_ROOT/.are"
ARE_MAP="$ARE_DIR/knowledge/MODULES.md"

# --- Risk and verification level ordering -----------------------------------------

# are_risk_rank RISK -> 0..3
are_risk_rank() {
    case "$1" in
        LOW) echo 0 ;;
        MEDIUM) echo 1 ;;
        HIGH) echo 2 ;;
        CRITICAL) echo 3 ;;
        *) echo 0 ;;
    esac
}

are_risk_name() {
    case "$1" in
        0) echo LOW ;;
        1) echo MEDIUM ;;
        2) echo HIGH ;;
        3) echo CRITICAL ;;
        *) echo LOW ;;
    esac
}

are_level_rank() {
    case "$1" in
        fast) echo 0 ;;
        relevant) echo 1 ;;
        full) echo 2 ;;
        *) echo 0 ;;
    esac
}

are_level_name() {
    case "$1" in
        0) echo fast ;;
        1) echo relevant ;;
        2) echo full ;;
        *) echo fast ;;
    esac
}

# Verification level required by a risk tier. Mirrors .are/rules/VERIFICATION_RULES.md
# section 1; if that table changes, change this with it.
are_level_for_risk() {
    case "$1" in
        LOW) echo fast ;;
        MEDIUM) echo relevant ;;
        HIGH | CRITICAL) echo full ;;
        *) echo fast ;;
    esac
}

# --- The path map ------------------------------------------------------------------

# are_map_rows: emit the map as TAB-separated PATH AREA RISK VERIFY KNOWLEDGE.
# Reads only the rows of the table whose header is "| PATH | AREA | RISK | ...", so the
# surrounding prose in MODULES.md is ignored.
are_map_rows() {
    awk -F'|' '
        /^\| *PATH *\| *AREA *\| *RISK *\|/ { intable = 1; next }
        intable && /^\| *-+ *\|/            { next }
        intable && !/^\|/                   { intable = 0 }
        intable && NF >= 6 {
            for (i = 2; i <= 6; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
            if ($2 != "") { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }
        }
    ' "$ARE_MAP"
}

# are_lookup FILE: print "PATH<TAB>AREA<TAB>RISK<TAB>VERIFY<TAB>KNOWLEDGE" for the first
# map row whose PATH glob matches FILE. Prints nothing when unmapped.
are_lookup() {
    local file="$1" pattern rest
    while IFS=$'\t' read -r pattern rest; do
        # shellcheck disable=SC2053  # glob match against the map pattern is the point
        if [[ "$file" == $pattern ]]; then
            printf '%s\t%s\n' "$pattern" "$rest"
            return 0
        fi
    done < <(are_map_rows)
    return 1
}

# --- Git ---------------------------------------------------------------------------

# are_changed_files: paths changed vs HEAD, plus untracked, NUL-safe enough for this repo
# (no filenames with newlines). Deterministic retrieval; no scanning.
are_changed_files() {
    {
        git -C "$ARE_REPO_ROOT" diff --name-only HEAD -- 2>/dev/null || true
        git -C "$ARE_REPO_ROOT" diff --name-only --cached HEAD -- 2>/dev/null || true
        git -C "$ARE_REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^$/d' | sort -u
}

are_branch() {
    git -C "$ARE_REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(no git)"
}

are_head() {
    git -C "$ARE_REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "(no git)"
}
