#!/usr/bin/env bash
# check-startup.sh --- run a batch init and fail on load-order warnings.
#
#   ./scripts/check-startup.sh
#   just batch-strict
#
# `just batch' only proves that init ran to completion: Emacs exits 0 with a
# warning buffer full of load-order damage. That is how FAIL-0012 shipped —
# `lisp/init-dialogic.el' carried `(eval-when-compile (require (quote org)))',
# which is a *load-time* require for an interpreted file, so init pulled Emacs's
# built-in Org before elpaca activated the newer one. Every org package then
# warned about the version mismatch, the text was printed in the middle of
# `just are-verify full', and the report still said PASS on batch-startup
# because the exit code was 0.
#
# So this wrapper reads the output as well as the status. Patterns are the class
# of failure, not the one instance: elpaca warns "<pkg> loaded before Elpaca
# activation" for any package a module requires too early.

set -uo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

out=$(just batch 2>&1)
status=$?
printf '%s\n' "$out"

if [ "$status" -ne 0 ]; then
    echo "check-startup: batch init exited $status" >&2
    exit "$status"
fi

# One pattern per line. Fixed strings, matched with grep -F.
patterns=(
    "loaded before Elpaca activation"
    "Org version mismatch"
)

bad=0
for pat in "${patterns[@]}"; do
    if printf '%s\n' "$out" | grep -qF -- "$pat"; then
        echo "check-startup: FAIL — startup emitted: $pat" >&2
        bad=1
    fi
done

if [ "$bad" -ne 0 ]; then
    cat >&2 <<'EOF'

A module required a package at load time instead of deferring it. Look for a
`require' that runs when the module is *loaded* — including one inside
`eval-when-compile', which is plain `progn' in an interpreted file, and the
modules in lisp/ are loaded as source. Declare the symbols with `defvar' /
`declare-function' instead of requiring the feature. See FAIL-0012 and L-028.
EOF
    exit 1
fi

echo "check-startup: no load-order warnings."
