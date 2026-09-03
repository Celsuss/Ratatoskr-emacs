# just/emacs.just — running, loading and byte-compiling this config.
#
# Imported flat into the root justfile: `emacs_bin', `init_dir', `trash_dirs' and
# `trash_files' are defined there and visible here.

# Launch Emacs with the current config
run:
    {{emacs_bin}} --init-directory {{init_dir}}

# Launch Emacs with --debug-init to catch startup errors
debug:
    {{emacs_bin}} --init-directory {{init_dir}} --debug-init

# Launch in terminal mode (no GUI)
cli:
    {{emacs_bin}} --init-directory {{init_dir}} -nw

# Byte-compile a single .el file for syntax checking (removes .elc after)
check file:
    {{emacs_bin}} --init-directory {{init_dir}} --batch --eval "(byte-compile-file \"{{file}}\")" ; rm -f "{{file}}c"

# Batch-load a single module to verify it parses
load file:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l "{{file}}"

# Full batch init (loads early-init + init; slow on first run due to elpaca)
batch:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l early-init.el -l init.el

# Batch init, failing on load-order warnings that a green exit code hides
# (FAIL-0012). This is what `are-verify full' runs, not plain `batch'.
batch-strict:
    ./scripts/check-startup.sh

# Byte-compile all .el files to catch errors
compile:
    #!/usr/bin/env bash
    set -euo pipefail
    errors=0
    for f in init.el lisp/init-*.el; do
        echo "Compiling $f..."
        if ! {{emacs_bin}} --init-directory {{init_dir}} --batch \
            --eval "(setq byte-compile-error-on-warn nil)" \
            -f batch-byte-compile "$f" 2>&1; then
            errors=$((errors + 1))
        fi
    done
    # Clean up .elc files (we don't want them in the repo)
    find . -name "*.elc" -not -path "./elpaca/*" -delete 2>/dev/null || true
    if [ "$errors" -gt 0 ]; then
        echo "COMPILE FAILED: $errors file(s) had errors"
        exit 1
    fi
    echo "All files compiled successfully."

# Delete all compiled artifacts, packages, and history
clean:
    @echo "Cleaning runtime artifacts..."
    rm -rf {{trash_dirs}}
    rm -f {{trash_files}}
    find . -name "*.elc" -not -path "./elpaca/*" -delete 2>/dev/null || true
    @echo "Clean slate ready."

# Full reset: clean then run
reset: clean run

# Search for TODOs in .el files (ignores build dirs)
todos:
    @grep -rn --color=always "TODO" . \
        --include="*.el" \
        --exclude-dir={elpaca,straight,var,etc,eln-cache,.git,auto-save-list,tree-sitter} \
        || echo "No TODOs found!"

# Install nerd-icons fonts (one-time setup)
install-fonts:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l early-init.el -l init.el --eval "(nerd-icons-install-fonts t)"

# Install tree-sitter grammars from treesit-language-source-alist
install-grammars:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l early-init.el -l init.el --eval "(mapc (lambda (src) (treesit-install-language-grammar (car src))) treesit-language-source-alist)"

# Generate elpaca lockfile
lock:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l early-init.el -l init.el --eval "(elpaca-lock)"

# Update all packages and regenerate lockfile
update:
    {{emacs_bin}} --init-directory {{init_dir}} --batch -l early-init.el -l init.el --eval "(progn (elpaca-update-all) (elpaca-lock))"
