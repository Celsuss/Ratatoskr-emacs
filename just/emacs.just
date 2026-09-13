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

# Full batch init (loads early-init + init; slow on first run due to elpaca).
# `after-init-time' is cleared first because `--batch' skips the init files, so by
# the time `-l init.el' runs Emacs has already declared init over -- and elpaca
# branches on that in six places. On its post-init path a queue is finalised as soon
# as its processed count catches up, which with `elpaca-queue-limit' set leaves the
# last throttled orders still queued while `use-package' bodies run: `nerd-icons-corfu'
# "cannot load" and `transient' is required from Emacs's built-in copy, so elpaca
# warns it "loaded before Elpaca activation". Neither happens in a real startup,
# where this variable is nil until init.el has finished; clearing it puts the harness
# on the same path the daemon takes (FAIL-0020).
batch:
    {{emacs_bin}} --init-directory {{init_dir}} --batch --eval "(setq after-init-time nil)" -l early-init.el -l init.el

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

# Rebuild every package's compiled artifacts with the Emacs that is installed now.
# This is the fix for an Emacs upgrade (FAIL-0015): macros expand at byte-compile
# time, so every .elc and .eln built by the previous Emacs is wrong for this one,
# and nothing fails loudly -- the symptom is a `void-function' for a shim compat
# deliberately stops defining. It deletes ONLY the derived artifacts (.elc, .eln)
# and recompiles from the sources already on disk; no package moves version, and
# custom.el / var/ / elpaca/sources are untouched -- that is the difference from
# `clean'. Order matters: the stale artifacts must be gone before the first
# recompile, or a fresh build reads a stale dependency and bakes the same bad call,
# and the eln wipe is not optional because elns are keyed by source hash and a bad
# one would be reused verbatim. Stop a daemon running from this checkout first.
# Same class as `clean' -- the operator runs it, never an agent (SAFETY_RULES §1).
# Works on another checkout without needing this recipe there:
#   just --justfile ~/workspace/Ratatoskr-emacs/justfile --working-directory ~/.config/emacs rebuild-packages
# `max-lisp-eval-depth' is raised because the init that drives the rebuild runs on
# a tree with no .elc at all: evil and elpaca are interpreted, every `let'/`while'
# inside an expanded `cl-loop' is an eval frame, and elpaca's activation chain is
# recursive -- Emacs 31's default of 1600 dies with `excessive-lisp-nesting' in
# `evil-initial-state' before the first package is rebuilt (FAIL-0015).
rebuild-packages:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "rebuild-packages: deleting .eln and .elc artifacts under $PWD"
    rm -rf eln-cache
    find elpaca/builds -name '*.elc' -delete
    {{emacs_bin}} --init-directory {{init_dir}} --batch \
        --eval "(setq max-lisp-eval-depth 10000)" \
        -l early-init.el -l init.el \
        -l "{{justfile_directory()}}/scripts/elpaca-rebuild.el"

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
