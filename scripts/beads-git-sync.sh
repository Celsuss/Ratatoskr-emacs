#!/usr/bin/env bash
# Shared by the versioned Git hooks and `just pull'.
set -euo pipefail

# Dolt's Git transport may itself invoke hooks.  Never recurse into bd.
[[ "${RATA_BEADS_SYNC_ACTIVE:-}" != 1 ]] || exit 0
action=${1:?Expected push or pull}
case "$action" in
    push)
        # Only the project's origin publishes tasks; leave other remotes alone.
        [[ "${2:-}" == origin ]] || exit 0
        ;;
    pull) ;;
    *) echo "beads: unknown sync action: $action" >&2; exit 1 ;;
esac

# Internal Dolt Git repositories can be bare and have no project task store.
[[ "$(git rev-parse --is-bare-repository)" == false ]] || exit 0
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
if [[ ! -d .beads ]]; then
    echo "beads: no task workspace. Run 'bd bootstrap' before syncing this checkout." >&2
    exit 1
fi
if ! command -v bd >/dev/null 2>&1; then
    echo "beads: bd is required for task sync. Install Beads and run 'bd bootstrap'." >&2
    exit 1
fi

# Git exports repository/index paths to hooks.  bd's nested Git operations must
# discover their own repositories, rather than accidentally using the code repo.
while IFS= read -r git_variable; do
    unset "$git_variable"
done < <(git rev-parse --local-env-vars)
export RATA_BEADS_SYNC_ACTIVE=1

if [[ "$action" == push ]]; then
    echo "beads: synchronizing tasks with origin before code push..." >&2
    # Pull/merge before pushing so another machine's task edits are retained.
    if bd sync --remote origin </dev/null; then
        exit 0
    else
        sync_status=$?
        echo "beads: task sync failed; code push blocked. Resolve the error and retry." >&2
        exit "$sync_status"
    fi
else
    echo "beads: pulling tasks from origin..." >&2
    if bd dolt pull --remote origin </dev/null; then
        exit 0
    else
        sync_status=$?
        echo "beads: task pull failed. Code may already be updated; retry 'bd dolt pull --remote origin'." >&2
        exit "$sync_status"
    fi
fi
