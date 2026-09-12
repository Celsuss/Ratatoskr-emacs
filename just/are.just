# just/are.just — ARE (Autonomous Reliability Engineering) entry points.
# Entry point: .are/INDEX.md   Operating manual: .are/SYSTEM.md

# Generate task context from git state + the ARE path map (.are/generated/CURRENT_CONTEXT.md)
are-context task="":
    ./scripts/are-context.sh "{{task}}"

# Repo-wide reliability audit — looks wider than the current diff
are-audit:
    ./scripts/are-audit.sh

# Renumber the knowledge pages' source-line citations after moving code around.
# The audit reports them stale; this fixes them. Run it before `are-audit', not instead.
are-fix-refs:
    ./scripts/are-fix-line-refs.sh

# Risk-based verification: fast (~4s) | relevant (~1.8min) | full (~3min)
are-verify level="fast":
    ./scripts/are-verify.sh {{level}}

# Show the ARE entry point
are:
    @echo "ARE entry point:      .are/INDEX.md"
    @echo "Operating manual:     .are/SYSTEM.md"
    @echo "Path map:             .are/knowledge/MODULES.md"
    @echo "Failure index:        .are/memory/FAILURE_INDEX.md"
    @echo ""
    @echo "  just are-context ['task']   generate task context before coding"
    @echo "  just are-verify fast        ~4s   LOW risk / mid-work"
    @echo "  just are-verify relevant    ~2min MEDIUM risk / any lisp change"
    @echo "  just are-verify full        ~3min HIGH+CRITICAL / end of session"
    @echo "  just are-audit              ~1s   repo-wide checks"
    @echo "  just are-fix-refs           renumber knowledge source-line citations"

# Configure git to use .githooks/ for hooks (one-time setup)
install-hooks:
    git config core.hooksPath .githooks
    @echo "Git hooks installed from .githooks/"
