# Environments

Source: `justfile`, `init-system.el`, filesystem and `git` inspection. Confidence: HIGH.

There is no dev/staging/production ladder — this is a desktop configuration. What varies
is **how Emacs is launched**, and **which checkout is running**. Both have bitten this
repo already.

---

## 1. Launch modes

| Mode | Command | Differences that matter |
|---|---|---|
| GUI | `just run` | the normal case; frame chrome disabled in `early-init.el` |
| Terminal | `just cli` (`-nw`) | no GUI frame; `corfu-terminal` exists for this; nerd-icons need a patched font in the terminal too |
| Batch / headless | `just batch`, `just test-ert`, `just compile` | **no frame, no interaction.** Anything that prompts, or that calls `set-auto-mode` on generated HTML, hangs or errors. `init-present.el` carries two `ox-html` advices specifically to keep export non-interactive |
| Daemon | `emacs --daemon` + `emacsclient` | **`exec-path-from-shell-initialize` runs only when `(daemonp)`** (`init-system.el`). In every other mode Emacs inherits the shell environment it was launched from. A `PATH`-dependent tool that works in the GUI can be missing in the daemon and vice versa |
| Stub-CLI harness | `just test-claude-loop` (`-Q`) | `-Q` means **no config at all**: no elpaca, no packages, no user init. The e2e suite loads only `lisp/init-claude-loop.el`. That is why it runs in 3 s |

`emacs --batch` implies `noninteractive`; `just compile` additionally runs with **no
package on `load-path`**. See [TESTING_STRATEGY.md](TESTING_STRATEGY.md).

## 2. The two checkouts — active drift

Verified 2026-08-19:

| Path | Role | Branch | HEAD | State |
|---|---|---|---|---|
| `/home/jens/.config/emacs` | **live config** — XDG default, what Emacs actually loads | `dev` | `1d38bd8` | 6 modified/untracked paths |
| `/home/jens/workspace/Ratatoskr-emacs` | second checkout of the same remote | `dev` | `ecdd05e` | clean, 4 commits behind |

Both have remote `git@github.com:Celsuss/Ratatoskr-emacs.git`. Neither is a symlink to
the other.

**The documentation points at the stale one.** `README.org` §Clone says
`git clone … ~/workspace/Ratatoskr-emacs` and §Run says
`emacs --init-directory ~/workspace/Ratatoskr-emacs`; `AGENTS.md` §Emacs Commands says the
same; `rata-dashboard-git-repos` in `lisp/init-dashboard.el:11` watches
`~/workspace/Ratatoskr-emacs`. So the dashboard reports git status for a checkout the
operator is not editing, and anyone following the README edits a copy that is not loaded.

Recorded as [FAIL-0001](../memory/failures/FAIL-0001.md). Not auto-fixed: choosing which
path is canonical is the operator's call, and `just run` (which uses `init_dir := "."`)
is correct from either directory, so nothing is broken today — only misleading.

**Operational rule:** before trusting any file path in `README.org`, `AGENTS.md` or
`SPEC.md`, confirm which checkout you are in with `git rev-parse --show-toplevel`.

## 3. Runtime state that is not in the repo

`no-littering` redirects generated state to `var/` and `etc/`, both `.gitignore`d.
Independently significant, none of it under version control:

| Path | Contents | Notes |
|---|---|---|
| `elpaca/` | every package source + build | rebuildable; `just clean` deletes it, costs minutes |
| `eln-cache/`, `tree-sitter/` | native-comp and grammar artifacts | rebuildable |
| `var/`, `etc/` | recentf, history, persp, tramp, elfeed db, SQL scratch | **operator state, not rebuildable** |
| `custom.el` | `customize` output | gitignored; loaded before modules |
| `~/workspace/second-brain/` | org-roam notes, hugo site | the operator's actual data; no test here touches it |
| `~/.authinfo.gpg` | credentials | see [SECRETS_AND_SENSITIVE_DATA.md](SECRETS_AND_SENSITIVE_DATA.md) |

`just clean` removes `elpaca eln-cache auto-save-list transient elpa` and `custom.el
history`. It does **not** remove `var/` or `etc/`, so operator state survives — but
`custom.el` does not. Treat `just clean` / `just reset` as destructive-but-recoverable and
never run either to "fix" a test failure. See [../rules/SAFETY_RULES.md](../rules/SAFETY_RULES.md).

## 4. Machine assumptions

**Two machines, two package managers.** The operator's desktop is Arch; the host this was
bootstrapped on is **Ubuntu 22.04.5** (`ID=ubuntu`, `ID_LIKE=debian`) with no `pacman` and no
`yay` on `PATH`. `just install-deps` used to be Arch-only, so it had never been run here and
its package list was aspirational on this machine — which is one of the three things that
made FAIL-0014 possible.

Since 2026-09-03 it reads `/etc/os-release` and dispatches: `install-deps-arch`
(pacman + yay) or `install-deps-debian` (apt-get + `go install` / `bun` / `rustup`). The
family match uses `ID` **and** `ID_LIKE`, so derivatives resolve (Manjaro → arch, Mint → ubuntu),
and it checks that the matched package manager is actually on `PATH` before using it — "os-release
says arch" and "pacman exists" are different claims. An unrecognised distro prints the required
binaries and exits 1; the two per-OS targets stay public so an odd derivative can force one.

What a Debian family host gets from apt is deliberately narrower than what Arch gets from
pacman: apt's language tooling is years old on an LTS (jammy ships gopls 0.1.9 from 2022, and
has no `prettier` or `kubectl` at all), so the toolchains install their own. Debian also
*renames binaries* — `fd-find` installs `fdfind`, `python3-pytest` installs `pytest-3` — and
the recipe symlinks both into `~/.local/bin` under the names Emacs calls. Verified on this
host: `/etc/os-release`, `apt-cache policy` over the whole list, `command -v`.

**`just check-deps` is the only claim about the machine you are on.** It resolves each
dependency *binary* and prints its path; on this host that shows tools arriving from apt,
linuxbrew, cargo, bun and `~/.local/bin` at once. A dependency list read as an inventory is
what FAIL-0014 was made of.

The `justfile` picks the Emacs binary from `/usr/bin/emacs`, then `/snap/bin/emacs`, then
`PATH`, overridable with `EMACS_BIN`. Here `/usr/bin/emacs` does not exist and it resolves
to `/snap/bin/emacs` (a snap wrapper). Consequence: Emacs runs under snap confinement, so
external tools, fonts and `$HOME`-relative paths are the snap's view of them, not
necessarily the shell's. If a subprocess works in a terminal but not in Emacs, suspect this
before suspecting the module.
