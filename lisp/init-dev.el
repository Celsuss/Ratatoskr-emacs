;;; -*- lexical-binding: t; -*-
;;; init-dev.el --- Development tools (LSP, flycheck, magit, vterm, etc.)

;; --- LSP Mode ---
(use-package lsp-mode
  :commands (lsp lsp-deferred)
  :custom
  (lsp-prefer-flymake nil)
  (lsp-enable-on-type-formatting nil)
  (lsp-before-save-edits nil)
  (lsp-enable-file-watchers nil)
  (lsp-completion-provider :none)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "l"   '(:ignore t :which-key "lsp")
    "ld"  '(lsp-find-definition :which-key "definition")
    "lr"  '(lsp-find-references :which-key "references")
    "ln"  '(lsp-rename :which-key "rename")
    "la"  '(lsp-execute-code-action :which-key "code action")
    "lf"  '(lsp-format-buffer :which-key "format buffer")
    "li"  '(lsp-find-implementation :which-key "implementation")
    "lt"  '(lsp-find-type-definition :which-key "type definition")
    "ls"  '(lsp-workspace-restart :which-key "restart LSP")
    "ll"  '(lsp :which-key "start LSP")))

;; --- LSP UI ---
(use-package lsp-ui
  :after lsp-mode
  :custom
  (lsp-ui-doc-enable t)
  (lsp-ui-doc-show-with-cursor t)
  (lsp-ui-sideline-enable t))

;; --- Flycheck ---
(use-package flycheck
  :config
  (global-flycheck-mode)
  (setq flycheck-display-errors-delay 0.3)
  (rata-leader
    :states '(normal visual insert emacs)
    "en"  '(flycheck-next-error :which-key "next error")
    "ep"  '(flycheck-previous-error :which-key "prev error")))

;; --- Apheleia (format on save) ---
(use-package apheleia
  :config
  (apheleia-global-mode t))

;; --- Magit ---
(use-package magit
  :after general
  :commands (magit-status magit-blame magit-log magit-find-file magit-diff-buffer-file)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "gs"  '(magit-status :which-key "status")
    "gb"  '(magit-blame :which-key "blame")
    "gl"  '(magit-log :which-key "log")
    "gf"  '(magit-find-file :which-key "find file")
    "gd"  '(magit-diff-buffer-file :which-key "diff buffer")))

;; --- Forge (GitHub PRs/Issues) ---
;; Requires ~/.authinfo.gpg: machine api.github.com login USER^forge password TOKEN
(use-package forge
  :after magit
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "gF"  '(forge-list-pullreqs :which-key "pull requests")
    "gI"  '(forge-list-issues :which-key "issues")))

;; --- Vterm ---
(use-package vterm
  :after general
  :commands vterm
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "t"   '(:ignore t :which-key "toggle")
    "tt"  '(vterm :which-key "terminal")))

;; --- Direnv ---
(use-package direnv
  :config
  (direnv-mode))

;; --- Projectile ---
(use-package projectile
  :after general
  :config
  (projectile-mode +1)
  (rata-leader
    :states '(normal visual insert emacs)
    "pp"  '(projectile-switch-project :which-key "switch project")
    "pb"  '(consult-project-buffer :which-key "project buffer")
    "pt"  '(projectile-run-project-tests :which-key "run tests")
    "pk"  '(projectile-kill-buffers :which-key "kill project buffers")))

;; --- Consult Projectile ---
(use-package consult-projectile
  :after (consult projectile)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "pf"  '(consult-projectile-find-file :which-key "find file")
    "ps"  '(consult-projectile-ripgrep :which-key "ripgrep project")))

(provide 'init-dev)
