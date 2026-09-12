# just/deps-arch.just — system dependencies on Arch and its derivatives.
#
# Reached through `just install-deps'; runnable directly on a derivative whose
# /etc/os-release does not say "arch". NOT TESTED from the Ubuntu checkout — there
# is no pacman there, so any change here is unverified until run on Arch.

# Install system dependencies (Arch Linux: pacman + yay)
install-deps-arch:
    #!/usr/bin/env bash
    set -euo pipefail

    pacman_pkgs=(
        # Core tools
        git ripgrep fd enchant shfmt editorconfig-core-c
        # Language servers & formatters
        python-black prettier gopls pyright go-tools
        # Dev tools
        rustup python-pytest terraform kubectl docker hugo delve
        # SQL client (ejc-sql drives JDBC via a Clojure nREPL)
        jdk-openjdk leiningen
        # Org LaTeX math preview (latex + dvisvgm + org preamble packages:
        # wrapfig/capt-of -> latexextra, ulem -> plaingeneric)
        texlive-binextra texlive-latex texlive-latexrecommended
        texlive-latexextra texlive-plaingeneric
        # Mail (init-mail.el): isync provides mbsync. protonmail-bridge is in
        # [extra], not the AUR. It needs a paid Proton plan and a Secret Service
        # keychain (gnome-keyring); after install, log in once with
        # `protonmail-bridge --cli'. mu itself is AUR-only, below.
        isync protonmail-bridge
    )

    # The ACP adapters are NOT here: they are npm/bun packages, and the AUR entry
    # that used to stand in for the Claude one named an abandoned third party's
    # package whose bin was not even the expected name (FAIL-0014). `_deps-acp'
    # installs both, the same way on every distro.
    # mu is not in the official repos (archlinux.org has no `mu' package; the
    # last binary was dropped from [extra]). The AUR `mu' is current (1.14.3,
    # the version D-021 pins on the Ubuntu host) and installs the matching mu4e
    # elisp under /usr/share/emacs/site-lisp/mu4e, which rata-mail-mu4e-dir
    # finds beside the binary. `maildir-utils' in the AUR is the same upstream
    # abandoned at 1.6.2 (2021) -- do not use it.
    aur_pkgs=(gomodifytags mu)

    # --- Pacman packages ---
    missing_pacman=()
    for pkg in "${pacman_pkgs[@]}"; do
        if ! pacman -Q "$pkg" &>/dev/null; then
            missing_pacman+=("$pkg")
        fi
    done

    if [ ${#missing_pacman[@]} -gt 0 ]; then
        echo "Missing pacman packages: ${missing_pacman[*]}"
        sudo pacman -S "${missing_pacman[@]}"
    else
        echo "All pacman packages already installed."
    fi

    # --- AUR packages ---
    if command -v yay &>/dev/null; then
        missing_aur=()
        for pkg in "${aur_pkgs[@]}"; do
            if ! yay -Q "$pkg" &>/dev/null; then
                missing_aur+=("$pkg")
            fi
        done

        if [ ${#missing_aur[@]} -gt 0 ]; then
            echo "Missing AUR packages: ${missing_aur[*]}"
            yay -S "${missing_aur[@]}"
        else
            echo "All AUR packages already installed."
        fi
    else
        echo "SKIP: yay is not on PATH, so these AUR packages are not installed: ${aur_pkgs[*]}"
    fi

    # --- ACP adapters (npm/bun, not pacman) ---
    just _deps-acp

    # --- Rust toolchain (rustup, not pacman — avoids binary conflicts) ---
    just _deps-rustup

    echo ""
    echo "Done. 'just check-deps' reports what is actually on PATH."
