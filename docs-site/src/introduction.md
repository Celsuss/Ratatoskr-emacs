<p align="center"><img src="generated/logo.png" alt="Ratatoskr, the squirrel on Yggdrasil with circuit branches" width="420"></p>

# Ratatoskr Emacs

A modular, Evil-based Emacs configuration built for speed and productivity, written entirely in Emacs Lisp.

- **Modal editing first.** Evil mode with Spacemacs-style `SPC` leader keys (`,` is the local leader).
- **Modular.** `early-init.el` → `init.el` → one `lisp/init-*.el` file per concern. A module that fails to load is reported in an `*init-errors*` buffer and does not take down the rest.
- **Reproducible.** Packages come from [elpaca](https://github.com/progfolio/elpaca) with a lockfile, and every task is a `just` target.
- **AI-assisted.** gptel, ellama, aidermacs and agent-shell, plus a task loop that drives the `claude` CLI through a checklist.

New here? Read [Features](generated/features.md), then [Dependencies](generated/dependencies.md) and [Install and first run](generated/getting-started.md). Once it runs, press `SPC` and let which-key show you what is bound.

Source: <https://github.com/Celsuss/Ratatoskr-emacs>

> Most pages in the *Getting started*, *User guide* and *Reference* sections are generated from `README.org` and `init.el` when the site is built, so they match the repository.
