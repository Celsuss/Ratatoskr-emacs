# just/deps.just — system dependency installation, dispatched by distro family.
#
# The per-OS bodies live in just/deps-arch.just and just/deps-debian.just.
# `os_id' and `os_like' come from /etc/os-release in the root justfile.
#
# L-033: a dependency list is not an inventory. `install-deps' is a statement about
# what *should* be present; only `just check-deps' says what *is*, and it does it by
# resolving the binary — not the package name, which is a different namespace
# (FAIL-0014).

# Install system dependencies for this machine (detects the distro family)
install-deps:
    #!/usr/bin/env bash
    set -euo pipefail

    id="{{ os_id }}"
    like="{{ os_like }}"

    # Family first, then package manager. "os-release says arch" and "pacman exists"
    # are different claims, and failing on the second with `pacman: not found' is a
    # worse error than saying so.
    case "$id $like" in
        *arch*)
            command -v pacman &>/dev/null \
                || { echo "FAIL: /etc/os-release says '$id' (an Arch family) but pacman is not on PATH." >&2; exit 1; }
            exec just install-deps-arch
            ;;
        *debian*|*ubuntu*)
            command -v apt-get &>/dev/null \
                || { echo "FAIL: /etc/os-release says '$id' (a Debian family) but apt-get is not on PATH." >&2; exit 1; }
            exec just install-deps-debian
            ;;
    esac

    # Unrecognised. Say what is needed rather than guessing a package manager.
    if [ "{{ os() }}" = "macos" ]; then
        echo "macOS is not automated here — no recipe exists that has ever been run on it."
    else
        echo "Unrecognised distro: ID='$id' ID_LIKE='$like'."
    fi
    echo ""
    echo "Force a family explicitly if yours is a derivative:"
    echo "    just install-deps-arch      (pacman + yay)"
    echo "    just install-deps-debian    (apt-get)"
    echo ""
    echo "Or install the binaries by hand — 'just check-deps' lists them and what each is for."
    exit 1

# The two ACP adapters agent-shell launches. Deliberately shared by both OS
# recipes and deliberately NOT a distro package: they belong to npm/bun, and the
# AUR entry that used to stand in for one of them named an abandoned third-party
# package (FAIL-0014). bun first, so they land next to `pi' on PATH rather than
# under an nvm-versioned npm prefix — which is how they are installed on the
# Ubuntu host today.
[private]
_deps-acp:
    #!/usr/bin/env bash
    set -euo pipefail
    # binary|package. Only a MISSING binary is installed: the two adapters share
    # `@agentclientprotocol/sdk' and zod at incompatible versions, and a working
    # pair depends on how npm/bun happened to nest them (INTEGRATIONS.md s1).
    # Reinstalling one to no purpose is how that arrangement gets broken.
    adapters=(
        "claude-agent-acp|@agentclientprotocol/claude-agent-acp"
        "pi-acp|pi-acp"
    )

    wanted=()
    for entry in "${adapters[@]}"; do
        bin="${entry%%|*}"
        command -v "$bin" &>/dev/null || wanted+=("${entry#*|}")
    done

    if [ ${#wanted[@]} -eq 0 ]; then
        echo "Both ACP adapters already on PATH."
        exit 0
    fi

    if command -v bun &>/dev/null; then
        installer=(bun install -g)
    elif command -v npm &>/dev/null; then
        installer=(npm install -g)
    else
        echo "SKIP: neither bun nor npm on PATH, so these are not installed: ${wanted[*]}"
        echo "      They are what 'SPC a i c c' and 'SPC a i c p' launch. Install bun or node, then:"
        echo "        bun install -g ${wanted[*]}"
        exit 0
    fi

    for pkg in "${wanted[@]}"; do
        echo "Installing $pkg with: ${installer[*]}"
        "${installer[@]}" "$pkg" || \
            echo "WARN: $pkg failed to install — the agent-shell key for it will not start." >&2
    done

# Rust toolchain bits, identical on every distro: rustup owns them, not the
# distro package manager (installing rust-analyzer twice conflicts).
[private]
_deps-rustup:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v rustup &>/dev/null; then
        echo "SKIP: rustup is not on PATH. Install it from https://rustup.rs, then re-run."
        exit 0
    fi
    rustup toolchain install nightly 2>/dev/null || true
    rustup component add rust-analyzer --toolchain nightly 2>/dev/null || true
    rustup component add clippy 2>/dev/null || true
    rustup component add rustfmt --toolchain nightly 2>/dev/null || true

# Report which dependency binaries are actually present on THIS host
check-deps:
    #!/usr/bin/env bash
    # Informational: always exits 0. A laptop without terraform is not a broken
    # checkout, and ARE reports integrations as NOT TESTED by design — this is not
    # wired into `are-verify'.
    set -uo pipefail

    # binary|feature that degrades without it
    deps=(
        "git|magit, projectile, vc"
        "rg|consult-ripgrep, projectile search"
        "fd|file finding (Debian names the binary fdfind)"
        "enchant-2|jinx spellcheck"
        "shfmt|apheleia shell formatting"
        "editorconfig|editorconfig-mode"
        "pyright|Python LSP"
        "gopls|Go LSP"
        "rust-analyzer|Rust LSP (rustup component, nightly toolchain)"
        "terraform-ls|Terraform LSP"
        "black|apheleia Python formatting"
        "prettier|apheleia web/markdown/yaml formatting"
        "pytest|python-pytest.el (Debian names the binary pytest-3)"
        "staticcheck|Go linting (go-tools)"
        "gomodifytags|Go struct tag editing"
        "dlv|dap-go debugging"
        "kubectl|kubel, k8s tooling"
        "docker|docker.el, dockerfile tooling"
        "hugo|init-blog.el export and preview"
        "terraform|SPC m T, terraform-mode commands"
        "java|ejc-sql (JDBC)"
        "lein|ejc-sql (Clojure nREPL)"
        "latex|org LaTeX math preview"
        "dvisvgm|org LaTeX math preview (SVG backend)"
        "cmake|vterm and jinx native modules"
        "claude|init-claude-loop.el"
        "claude-agent-acp|agent-shell, SPC a i c c"
        "pi-acp|agent-shell, SPC a i c p"
    )

    present=0
    missing=0
    echo "Dependency binaries on $(hostname) ({{ os_id }}):"
    echo ""
    for entry in "${deps[@]}"; do
        bin="${entry%%|*}"
        why="${entry#*|}"
        if path="$(command -v "$bin" 2>/dev/null)"; then
            printf '  %-18s %s\n' "$bin" "$path"
            present=$((present + 1))
        else
            printf '  %-18s MISSING — %s\n' "$bin" "$why"
            missing=$((missing + 1))
        fi
    done

    # rust-analyzer is commonly installed as a rustup component that is reachable
    # through the toolchain but not on PATH; say so rather than reporting absence.
    if ! command -v rust-analyzer &>/dev/null && command -v rustup &>/dev/null; then
        if ra="$(rustup which --toolchain nightly rust-analyzer 2>/dev/null)"; then
            echo ""
            echo "  note: rust-analyzer is not on PATH but the nightly toolchain has it:"
            echo "        $ra"
        fi
    fi

    # The blog export needs the extended build (SCSS); the plain one fails at render.
    if command -v hugo &>/dev/null && ! hugo version 2>/dev/null | grep -q extended; then
        echo ""
        echo "  note: this hugo is NOT the extended build — SCSS themes will fail to render."
    fi

    echo ""
    echo "$present present, $missing missing. 'just install-deps' installs what it can for {{ os_id }}."
    echo "A missing binary degrades one feature; it never breaks startup (every consumer is deferred)."
