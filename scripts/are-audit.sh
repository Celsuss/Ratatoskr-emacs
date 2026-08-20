#!/usr/bin/env bash
# are-audit.sh --- repo-wide ARE reliability audit.
#
#   ./scripts/are-audit.sh
#   just are-audit
#
# Looks wider than the current diff. Every check here is deterministic, needs no Emacs and
# no network, and exists because something was actually found during the ARE bootstrap or
# because a failure record asked for it. Runs in about a second.
#
# Exit status: 0 if no errors (warnings do not fail); 1 if any error.
#
# Output style follows scripts/lint.sh: "=== Check: name ===" plus FAIL/WARN lines.

set -euo pipefail

# shellcheck source=scripts/are-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/are-lib.sh"

errors=0
warnings=0

fail() { echo "FAIL: $*"; errors=$((errors + 1)); }
warn() { echo "WARN: $*"; warnings=$((warnings + 1)); }

cd "$ARE_REPO_ROOT"

echo "ARE audit — $ARE_REPO_ROOT (branch $(are_branch) @ $(are_head))"
echo

# --- Check: are-structure ---------------------------------------------------------
# The ARE system must be intact before any other check means anything.
echo "=== Check: are-structure ==="
for required in \
    .are/INDEX.md \
    .are/SYSTEM.md \
    .are/config.yaml \
    .are/knowledge/MODULES.md \
    .are/memory/FAILURE_INDEX.md \
    .are/memory/LESSONS.md \
    .are/memory/DECISIONS.md \
    .are/rules/RISK_RULES.md \
    .are/rules/VERIFICATION_RULES.md \
    .are/rules/SAFETY_RULES.md
do
    [ -f "$required" ] || fail "missing ARE file: $required"
done

# --- Check: map-covers-modules ----------------------------------------------------
# From FAIL-0006's sibling concern: an unmapped path produces incomplete task context, so
# a new module must come with a path-map row.
echo "=== Check: map-covers-modules ==="
for f in lisp/init-*.el init.el early-init.el; do
    [ -e "$f" ] || continue
    if ! are_lookup "$f" >/dev/null; then
        fail "$f has no row in .are/knowledge/MODULES.md (add one: path | area | risk | verify | knowledge)"
    fi
done

# --- Check: map-rows-resolve ------------------------------------------------------
# A map row pointing at a knowledge page that does not exist sends future sessions
# nowhere.
echo "=== Check: map-rows-resolve ==="
while IFS=$'\t' read -r pattern _area risk verify know; do
    case "$risk" in
        LOW | MEDIUM | HIGH | CRITICAL) ;;
        *) fail "map row '$pattern' has invalid RISK '$risk'" ;;
    esac
    case "$verify" in
        fast | relevant | full) ;;
        *) fail "map row '$pattern' has invalid VERIFY '$verify'" ;;
    esac
    if [ -n "$know" ] && [ ! -f ".are/$know" ]; then
        fail "map row '$pattern' points at missing knowledge page .are/$know"
    fi
done < <(are_map_rows)

# --- Check: failure-index-complete ------------------------------------------------
# A record nobody can find from the index may as well not exist.
echo "=== Check: failure-index-complete ==="
if [ -d .are/memory/failures ]; then
    for rec in .are/memory/failures/*.md; do
        [ -e "$rec" ] || continue
        id="$(basename "$rec" .md)"
        grep -q "$id" .are/memory/FAILURE_INDEX.md \
            || fail "$id is not listed in .are/memory/FAILURE_INDEX.md"
    done
fi

# --- Check: are-files-committable -------------------------------------------------
# L-009: git check-ignore silently reports nothing for tracked paths, so --no-index is
# required. A .gitignore rule that swallows an ARE file would make ARE invisible to every
# other checkout.
echo "=== Check: are-files-committable ==="
while IFS= read -r p; do
    [ -n "$p" ] || continue
    # *.local.* is per-checkout config that is *supposed* to be ignored
    # (.claude/settings.local.json is ignored by the user's global gitignore).
    case "$p" in
        *.local.json | *.local.yaml | *.local.yml) continue ;;
    esac
    if rule="$(git check-ignore -v --no-index "$p" 2>/dev/null)"; then
        case "$p" in
            # An uncommittable file under .are/, .claude/ or scripts/ breaks ARE for every
            # other checkout — that is a failure. Under docs/ it is a heads-up: `docs/*` is
            # excluded wholesale and that may well be deliberate. See DECISIONS.md D-006.
            docs/*) warn "$p is ignored by git ($rule) — it will not reach version control" ;;
            *) fail "$p would be ignored by git ($rule)" ;;
        esac
    fi
done < <(find .are .claude scripts docs -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.json' -o -name 'are-*.sh' \) 2>/dev/null)

# --- Check: no-auto-approve -------------------------------------------------------
# SAFETY_RULES section 2: SPC m T a already runs `terraform apply` through `compile`. It
# cannot self-approve today only because there is no TTY. Adding an auto-approve flag
# anywhere would turn a near-miss into a live destructive keybinding.
echo "=== Check: no-auto-approve ==="
if hits="$(grep -rnE '(compile|shell-command|start-process|make-process|call-process)[^)]*(-auto-approve|--force|[^-]-force|--yes|[[:space:]]-y[[:space:]"])' \
    --include='*.el' lisp/ init.el 2>/dev/null)"; then
    if [ -n "$hits" ]; then
        echo "$hits"
        fail "an auto-approve / force flag reaches a subprocess — see .are/rules/SAFETY_RULES.md s2"
    fi
fi

# --- Check: gate-covers-tests -----------------------------------------------------
# FAIL-0004: a test target that no gate runs is decoration.
#
# `just are-verify` delegates to scripts/are-verify.sh, so the justfile recipe body cannot
# show reachability — the script is where the steps actually are. (The first version of
# this check grepped the justfile recipe and reported two false failures. L-008.)
echo "=== Check: gate-covers-tests ==="
if [ -f justfile ] && [ -f scripts/are-verify.sh ]; then
    for target in $(grep -oE '^test-[a-z-]+:' justfile | tr -d ':'); do
        if ! grep -q "just $target\b" scripts/are-verify.sh; then
            fail "justfile target '$target' is not run by scripts/are-verify.sh, so no gate covers it (see FAIL-0004)"
        fi
    done
fi

# --- Check: docs-paths -----------------------------------------------------------
# FAIL-0001: README.org and AGENTS.md tell the reader to run a checkout that is not this
# one. Loud instead of invisible; it does not decide which path is canonical.
echo "=== Check: docs-paths ==="
for doc in README.org AGENTS.md; do
    [ -f "$doc" ] || continue
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        expanded="${p/#\~/$HOME}"
        if [ "$expanded" != "$ARE_REPO_ROOT" ] && [ "$expanded" != "." ]; then
            warn "$doc says --init-directory $p, but this checkout is $ARE_REPO_ROOT (FAIL-0001)"
        fi
        # Strip trailing markup (org's =...=, markdown's `...`, punctuation) before
        # comparing, or the same path is reported once per quoting style.
    done < <(grep -ohE '\-\-init-directory[= ]+[^ )"'"'"']+' "$doc" 2>/dev/null \
        | sed -E 's/--init-directory[= ]+//; s/[`=,.;:)]+$//' | sort -u)
done

# --- Check: hooks-installed ------------------------------------------------------
# FAIL-0005: warn, do not fail. A fresh clone has not been set up and is not broken.
echo "=== Check: hooks-installed ==="
hooks_path="$(git config --get core.hooksPath || true)"
if [ "$hooks_path" != ".githooks" ]; then
    warn "core.hooksPath is '${hooks_path:-unset}', so .githooks/pre-commit does not run. There is no CI either. Fix: just install-hooks (FAIL-0005)"
fi

# --- Check: stray-files ----------------------------------------------------------
# FAIL-0007: nothing noticed an accidental untracked file. Warning only — work in progress
# is normal.
echo "=== Check: stray-files ==="
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
        *.el | *.md | *.org | *.sh | *.yaml | *.yml | *.json | *.png | snippets/*) continue ;;
    esac
    warn "unexpected untracked file: '$p' (FAIL-0007)"
done < <(git ls-files --others --exclude-standard 2>/dev/null || true)

# --- Check: knowledge-line-refs --------------------------------------------------
# The knowledge pages cite source lines as `symbol`, `:NNN`. Those drift the moment
# anyone inserts a defun above them, and a citation that points at the wrong line is
# worse than none: it sends a session to read something else and be confident about it.
# Every reference found stale on the run that added this check — all fifteen of them.
# Scoped to CLAUDE_LOOP.md, the only page using the convention; extend the loop below
# when another page adopts it.
echo "=== Check: knowledge-line-refs ==="
knowledge_page=".are/knowledge/CLAUDE_LOOP.md"
knowledge_source="lisp/init-claude-loop.el"
if [ -f "$knowledge_page" ] && [ -f "$knowledge_source" ]; then
    while IFS= read -r match; do
        [ -n "$match" ] || continue
        symbol=$(printf '%s' "$match" | sed -n 's/^`\([^`]*\)`.*/\1/p')
        line=$(printf '%s' "$match" | sed -n 's/.*`:\([0-9]*\)`.*/\1/p')
        [ -n "$symbol" ] && [ -n "$line" ] || continue
        if ! sed -n "${line}p" "$knowledge_source" | grep -qF "$symbol"; then
            fail "$knowledge_page cites $symbol at :$line, which is not there"
        fi
    done < <(grep -oP '`(rata-claude-loop[^`]*)`[^`]*?`:(\d+)`' "$knowledge_page" || true)
fi

# --- Check: no-committed-secrets -------------------------------------------------
# Not a secret scanner. It asserts the one property that matters here: credentials are
# referenced, never inlined.
echo "=== Check: no-committed-secrets ==="
if hits="$(grep -rniE '(password|passwd|secret|api[-_]?key|token)[[:space:]]*(=|:|"|[[:space:]])[[:space:]]*"[A-Za-z0-9_/+=-]{16,}"' \
    --include='*.el' lisp/ init.el early-init.el 2>/dev/null)"; then
    if [ -n "$hits" ]; then
        echo "$hits"
        fail "a literal credential appears to be committed — see .are/rules/SAFETY_RULES.md s3"
    fi
fi

# --- Check: context-freshness ----------------------------------------------------
echo "=== Check: context-freshness ==="
ctx=".are/generated/CURRENT_CONTEXT.md"
if [ ! -f "$ctx" ]; then
    warn "$ctx does not exist yet — run: just are-context"
elif [ -n "$(find lisp init.el early-init.el -newer "$ctx" -print -quit 2>/dev/null)" ]; then
    warn "$ctx is older than a changed source file — run: just are-context"
fi

# --- Summary ---------------------------------------------------------------------
echo
if [ "$errors" -gt 0 ]; then
    echo "ARE AUDIT FAILED: $errors error(s), $warnings warning(s)"
    exit 1
fi
if [ "$warnings" -gt 0 ]; then
    echo "ARE audit passed with $warnings warning(s)."
else
    echo "ARE audit passed."
fi
