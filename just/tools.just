# just/tools.just — repomix (packed repo context for coding agents).
#
# repomix-output.xml is a generated artifact: gitignored, per-machine, and
# regenerated on demand. It is a *navigation* aid — the authoritative map of
# this config is .are/knowledge/MODULES.md plus `just are-context'.

# Set up repomix on this machine (one-time): check prerequisites, then first pack
install-repomix:
    #!/usr/bin/env bash
    set -euo pipefail

    # No global npm install is required: `npx --yes' fetches repomix on demand
    # and caches it. A globally installed binary is used when present.
    if command -v repomix &>/dev/null; then
        echo "Using repomix from PATH: $(command -v repomix)"
    elif command -v npx &>/dev/null; then
        echo "No repomix binary on PATH; will run it through npx (node $(node --version))."
        echo "For a faster start-up: npm install -g repomix"
    else
        echo "FAIL: neither repomix nor npx found. Install Node.js first" >&2
        echo "      (Arch: sudo pacman -S nodejs npm, Debian/Ubuntu: sudo apt-get install nodejs npm, or use nvm)." >&2
        exit 1
    fi

    [ -f repomix.config.json ] \
        && echo "Config present: repomix.config.json" \
        || { echo "FAIL: repomix.config.json is missing from the repo." >&2; exit 1; }

    git check-ignore -q repomix-output.xml \
        && echo "Output is gitignored: repomix-output.xml" \
        || echo "WARN: repomix-output.xml is not gitignored — add it to .gitignore."

    just repomix

# Regenerate repomix-output.xml (run after significant changes)
repomix:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v repomix &>/dev/null; then
        repomix
    elif command -v npx &>/dev/null; then
        npx --yes repomix
    else
        echo "FAIL: repomix unavailable. Run 'just install-repomix' for the prerequisites." >&2
        exit 1
    fi
