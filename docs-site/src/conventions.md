# Conventions

The authoritative guide is [`AGENTS.md`](https://github.com/Celsuss/Ratatoskr-emacs/blob/master/AGENTS.md) in the repository. The short version:

## Files

- Every `.el` file starts with `;;; -*- lexical-binding: t; -*-`, has a `;;; init-x.el --- description` header line (the [module index](generated/modules.md) shows it), and ends with `(provide 'init-x)`.
- Modules are named `init-<category>.el`; functions and variables are `rata-<purpose>`.

## Packages

- Use `use-package` for every external package and defer where you can (`:bind`, `:hook`, `:commands`).
- `:init` runs before the package loads, `:config` after, `:custom` sets user options.
- Never `require` a package inside `eval-when-compile`: modules are loaded as source, so it runs on every startup.

## Keybindings

- Global leader is `SPC`, local leader is `,`, defined with `general.el` and the `rata-leader` definer. Always give a which-key description.
- **Put global leader keys at the top level inside `(with-eval-after-load 'general ...)`, not in a deferred `use-package`'s `:config`.** `:config` only runs once the package loads, so a key defined there may not exist until something else loads the package.
- Follow Spacemacs mnemonics: `SPC b` buffers, `SPC f` files, `SPC g` git, `SPC s` search, `SPC w` windows, `SPC o` org, `SPC l` layouts, `SPC L` LSP.

## Performance

`gc-cons-threshold` is maxed during init and reset afterwards; lazy-load everything that is not needed at startup.

## Checking your change

```sh
just lint                  # conventions, fast
just check lisp/init-x.el  # byte-compile one file
just test                  # lint + compile + startup
just are-verify relevant   # risk-based verification, see Reliability (ARE)
```
