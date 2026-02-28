#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
errors=0

# --- Check 1: lexical-binding header ---
echo "=== Checking lexical-binding headers ==="
for f in "$REPO_ROOT"/init.el "$REPO_ROOT"/early-init.el "$REPO_ROOT"/lisp/init-*.el; do
    first_line=$(head -1 "$f")
    if [[ "$first_line" != *"lexical-binding: t"* ]]; then
        echo "FAIL: $f missing lexical-binding header"
        errors=$((errors + 1))
    fi
done

# --- Check 2: provide form matches filename ---
echo "=== Checking provide forms ==="
for f in "$REPO_ROOT"/lisp/init-*.el; do
    basename=$(basename "$f" .el)
    if ! grep -q "^(provide '$basename)" "$f"; then
        echo "FAIL: $f missing (provide '$basename)"
        errors=$((errors + 1))
    fi
done

# --- Check 3: rata- prefix on definitions ---
echo "=== Checking rata- prefix convention ==="
for f in "$REPO_ROOT"/init.el "$REPO_ROOT"/lisp/init-*.el; do
    # Find defun/defvar/defcustom that don't use rata- prefix
    # Skip early-init.el (no custom definitions expected)
    while IFS= read -r line; do
        echo "FAIL: $f: definition missing rata- prefix: $line"
        errors=$((errors + 1))
    done < <(grep -nE '^\(def(un|var|custom|macro) ' "$f" \
        | grep -vE '\(def(un|var|custom|macro) rata-' \
        | grep -vE '\(def(un|var|custom|macro) elpaca-' \
        || true)
done

# --- Summary ---
if [ "$errors" -gt 0 ]; then
    echo ""
    echo "LINT FAILED: $errors error(s) found"
    exit 1
else
    echo ""
    echo "All lint checks passed."
fi
