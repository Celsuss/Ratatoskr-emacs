# just/deps-debian.just — system dependencies on Debian, Ubuntu and derivatives.
#
# Reached through `just install-deps'; runnable directly on a derivative whose
# /etc/os-release does not say "debian"/"ubuntu".
#
# Two things differ from the Arch recipe by necessity, not taste:
#
#   * apt's language tooling lags badly on an LTS (Ubuntu 22.04 ships gopls 0.1.9
#     from 2022), so the language toolchains install their own: `go install',
#     `bun'/`npm', `rustup'. apt is used for what apt is actually good at.
#   * Debian renames binaries. `fd-find' installs `fdfind', not `fd'; nothing in
#     Emacs knows that. The shim section below is not optional decoration — a
#     package installed under a name nothing calls is a missing dependency
#     (L-033).
#
# Nothing here adds a third-party apt repository or pipes a downloaded script into
# a shell. Those change what the machine trusts, and they are printed as
# instructions instead.

# Install system dependencies (Debian/Ubuntu: apt-get + language toolchains)
install-deps-debian:
    #!/usr/bin/env bash
    set -euo pipefail

    # apt's job: OS-level libraries, build tooling and TeX. Wanted whether or not
    # some binary happens to be around, so presence is decided by dpkg.
    # Deliberately NOT here: gopls, prettier, pyright, delve, hugo,
    # rust-analyzer — see the header.
    apt_pkgs=(
        # Native-module build deps: vterm needs cmake + libtool, jinx compiles
        # against libenchant. Arch gets these from base-devel; Debian does not.
        build-essential cmake libtool-bin pkg-config
        enchant-2 libenchant-2-dev
        # Org LaTeX math preview. Debian has no texlive-binextra; dvisvgm is its
        # own package. wrapfig/capt-of -> latex-extra, ulem -> plain-generic.
        texlive-latex-base texlive-latex-recommended
        texlive-latex-extra texlive-plain-generic
    )

    # pkg|binary, for tools where a *different* install of the same tool is common
    # and apt's copy would be redundant at best. `docker.io' is why this list
    # exists and not a refinement: this host runs `docker-ce' from Docker's own
    # repo, and `apt-get install docker.io' would offer to REMOVE it. Skipping on
    # the binary also stops apt's ancient black shadow-installing under a pipx one.
    apt_tools=(
        "git|git"
        "ripgrep|rg"
        "fd-find|fd"
        "shfmt|shfmt"
        "editorconfig|editorconfig"
        "python3-pytest|pytest"
        "black|black"
        "docker.io|docker"
        "terraform|terraform"
        "kubectl|kubectl"
        "default-jdk|java"
        "leiningen|lein"
        "dvisvgm|dvisvgm"
    )

    # How to get the things apt on this release cannot provide.
    declare -A hints=(
        [terraform]="HashiCorp apt repo — https://developer.hashicorp.com/terraform/install"
        [kubectl]="sudo snap install kubectl --classic   (or the pkgs.k8s.io apt repo)"
        [hugo]="sudo snap install hugo, or the .deb from https://github.com/gohugoio/hugo/releases (needs the *extended* build)"
        [shfmt]="go install mvdan.cc/sh/v3/cmd/shfmt@latest"
        [mu]="brew install mu      (apt's maildir-utils is 1.6 on jammy -- predates the mu4e API init-mail.el uses)"
        [mbsync]="brew install isync   (apt's 1.4 lacks the TLSType keyword mbsyncrc.example uses)"
        [protonmail-bridge]="flatpak install flathub ch.protonmail.protonmail-bridge   (paid Proton plan; then log in once with --cli)"
    )

    # --- apt packages, filtered by what this release actually has ---------------
    # Availability is checked rather than assumed: an LTS and a current release
    # disagree about this list (jammy has no kubectl and no prettier at all), and
    # hardcoding release names would rot. A package with no candidate is reported,
    # not silently dropped.
    missing_apt=()
    unavailable=()

    want_apt() {
        local pkg="$1" candidate
        dpkg -s "$pkg" &>/dev/null && return 0
        candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
        if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
            unavailable+=("$pkg")
        else
            missing_apt+=("$pkg")
        fi
    }

    for pkg in "${apt_pkgs[@]}"; do
        want_apt "$pkg"
    done

    for entry in "${apt_tools[@]}"; do
        pkg="${entry%%|*}"
        bin="${entry#*|}"
        if command -v "$bin" &>/dev/null; then
            continue
        fi
        want_apt "$pkg"
    done

    if [ ${#missing_apt[@]} -gt 0 ]; then
        echo "Missing apt packages: ${missing_apt[*]}"
        sudo apt-get install "${missing_apt[@]}"
    else
        echo "All available apt packages already installed."
    fi

    # --- Debian binary-name shims ----------------------------------------------
    # A package whose binary is named something nothing calls is not installed.
    mkdir -p "$HOME/.local/bin"
    shim() {
        local want="$1" have="$2"
        if command -v "$want" &>/dev/null; then
            return 0
        fi
        if command -v "$have" &>/dev/null; then
            ln -sf "$(command -v "$have")" "$HOME/.local/bin/$want"
            echo "Shimmed: ~/.local/bin/$want -> $(command -v "$have")  (Debian names it '$have')"
        fi
    }
    shim fd fdfind
    shim pytest pytest-3
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "WARN: ~/.local/bin is not on PATH, so the shims above are invisible to Emacs." ;;
    esac

    # --- Go tooling (apt's is years old) ---------------------------------------
    go_tools=(
        "gopls|golang.org/x/tools/gopls@latest"
        "staticcheck|honnef.co/go/tools/cmd/staticcheck@latest"
        "gomodifytags|github.com/fatih/gomodifytags@latest"
        "dlv|github.com/go-delve/delve/cmd/dlv@latest"
    )
    if command -v go &>/dev/null; then
        for entry in "${go_tools[@]}"; do
            bin="${entry%%|*}"
            mod="${entry#*|}"
            if command -v "$bin" &>/dev/null; then
                continue
            fi
            echo "go install $mod"
            go install "$mod" || echo "WARN: $bin failed to install." >&2
        done
    else
        echo "SKIP: go is not on PATH, so gopls/staticcheck/gomodifytags/dlv are not installed."
        echo "      Install Go from https://go.dev/dl/ (apt's golang lags), then re-run."
    fi

    # --- Node tooling (apt has no prettier or pyright at all) ------------------
    node_pkgs=(
        "prettier|prettier"
        "pyright|pyright"
    )
    wanted_node=()
    for entry in "${node_pkgs[@]}"; do
        bin="${entry%%|*}"
        command -v "$bin" &>/dev/null || wanted_node+=("${entry#*|}")
    done
    if [ ${#wanted_node[@]} -gt 0 ]; then
        if command -v bun &>/dev/null; then
            echo "bun install -g ${wanted_node[*]}"
            bun install -g "${wanted_node[@]}" || echo "WARN: node tooling failed to install." >&2
        elif command -v npm &>/dev/null; then
            echo "npm install -g ${wanted_node[*]}"
            npm install -g "${wanted_node[@]}" || echo "WARN: node tooling failed to install." >&2
        else
            echo "SKIP: neither bun nor npm on PATH, so these are not installed: ${wanted_node[*]}"
        fi
    fi

    # --- Mail: mu (mu4e) and isync (mbsync) for init-mail.el -------------------
    # Neither comes from apt on an LTS: jammy's maildir-utils is 1.6, which
    # predates `mu4e-search' and the 1.10+ API the module is written against,
    # and its isync 1.4 rejects the TLSType keyword in mbsyncrc.example. Homebrew
    # has both current and puts the mu4e elisp beside the binary, which is
    # exactly where init-mail.el looks for it. Without brew they go to the
    # manual section below with the same instruction.
    mail_missing=()
    command -v mu     &>/dev/null || mail_missing+=(mu)
    command -v mbsync &>/dev/null || mail_missing+=(isync)
    if [ ${#mail_missing[@]} -gt 0 ] && command -v brew &>/dev/null; then
        echo "brew install ${mail_missing[*]}"
        brew install "${mail_missing[@]}" || echo "WARN: mail tooling failed to install." >&2
    fi

    # --- ACP adapters (npm/bun on every distro) --------------------------------
    just _deps-acp

    # --- Rust toolchain --------------------------------------------------------
    just _deps-rustup

    # --- What is left for you --------------------------------------------------
    # Everything above either installed or said why not. This is the residue: it
    # needs a decision about the machine's trust (a new apt repo, a snap, a
    # downloaded binary), which a recipe should not make on its own.
    # An apt package with no candidate is only a problem if the binary is also
    # absent: on this host `kubectl` and `terraform-ls` came from linuxbrew and
    # `cmake` from ~/.local/bin, and telling the operator to snap-install a tool
    # they already have is noise that trains them to skip this section. For these
    # the package name and the binary name coincide.
    manual=()
    for pkg in "${unavailable[@]}"; do
        command -v "$pkg" &>/dev/null || manual+=("$pkg")
    done
    command -v hugo &>/dev/null || manual+=("hugo")
    command -v rustup &>/dev/null || manual+=("rustup")
    command -v mu &>/dev/null || manual+=("mu")
    command -v mbsync &>/dev/null || manual+=("mbsync")
    # Bridge is a Flatpak, so it is never on PATH: ask flatpak, then the native name.
    if ! flatpak info ch.protonmail.protonmail-bridge &>/dev/null \
       && ! command -v protonmail-bridge &>/dev/null; then
        manual+=("protonmail-bridge")
    fi

    if [ ${#manual[@]} -gt 0 ]; then
        echo ""
        echo "Not installed — needs a choice about this machine:"
        for pkg in "${manual[@]}"; do
            hint="${hints[$pkg]:-}"
            if [ "$pkg" = "rustup" ]; then
                hint="https://rustup.rs — then re-run for rust-analyzer, clippy and rustfmt"
            fi
            if [ -n "$hint" ]; then
                printf '  %-12s %s\n' "$pkg" "$hint"
            else
                printf '  %-12s (no apt candidate on this release)\n' "$pkg"
            fi
        done
    fi

    echo ""
    echo "Done. 'just check-deps' reports what is actually on PATH."
