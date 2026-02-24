;;; -*- lexical-binding: t; -*-
;;; init-dev.el --- Development tools (LSP, flycheck, magit, vterm, etc.)

;; --- Transient (newer version required by magit, forge, gptel) ---
(use-package transient
  :demand t)
(elpaca-wait)

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
    "L"   '(:ignore t :which-key "lsp")
    "Ld"  '(lsp-find-definition :which-key "definition")
    "Lr"  '(lsp-find-references :which-key "references")
    "Ln"  '(lsp-rename :which-key "rename")
    "La"  '(lsp-execute-code-action :which-key "code action")
    "Lf"  '(lsp-format-buffer :which-key "format buffer")
    "Li"  '(lsp-find-implementation :which-key "implementation")
    "Lt"  '(lsp-find-type-definition :which-key "type definition")
    "Ls"  '(lsp-workspace-restart :which-key "restart LSP")
    "LL"  '(lsp :which-key "start LSP")))

;; --- LSP UI ---
(use-package lsp-ui
  :after lsp-mode
  :custom
  (lsp-ui-doc-enable t)
  (lsp-ui-doc-show-with-cursor t)
  (lsp-ui-sideline-enable t))

;; --- Flycheck ---
(use-package flycheck
  :after general
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
  (apheleia-global-mode t)
  (setq apheleia-remote-algorithm 'cancel))

;; --- Magit ---
(use-package magit
  :after general
  :commands (magit-status magit-blame magit-log magit-find-file magit-diff-buffer-file)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "gg"  '(magit-status :which-key "status")
    "gG"  '(consult-git-grep :which-key "git grep")
    "gs"  '(magit-status :which-key "status (alt)")
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
  :commands vterm
  :defer t)

;; --- Vterm-toggle ---
(use-package vterm-toggle
  :after general
  :commands (vterm-toggle vterm-toggle-cd)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "t"   '(:ignore t :which-key "toggle")
    "tt"  '(vterm-toggle :which-key "terminal")
    "tT"  '(vterm-toggle-cd :which-key "terminal (cd)")))

;; --- Envrc (buffer-local direnv, replaces global direnv-mode) ---
(use-package envrc
  :demand t
  :config
  (envrc-global-mode))

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
    "pk"  '(projectile-kill-buffers :which-key "kill project buffers")
    "pr"  '(projectile-replace :which-key "replace")
    "pR"  '(projectile-replace-regexp :which-key "replace regexp")))

;; --- Consult Projectile ---
(use-package consult-projectile
  :after (consult projectile)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "pf"  '(consult-projectile-find-file :which-key "find file")
    "ps"  '(consult-projectile-ripgrep :which-key "ripgrep project")))

;; --- Dirvish (enhanced dired) ---
(use-package dirvish
  :after general
  :config
  (dirvish-override-dired-mode)
  (setq dirvish-attributes '(nerd-icons file-size vc-state git-msg))
  (rata-leader
    :states '(normal visual insert emacs)
    "fd"  '(dirvish :which-key "dirvish")))

;; --- Esup (startup profiler) ---
(use-package esup
  :defer t
  :custom
  (esup-depth 0))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual insert emacs)
    "hP"  '(esup :which-key "profile startup")))

;; --- Jinx (modern spellcheck, replaces flyspell) ---
;; Requires enchant system package: pacman -S enchant
(use-package jinx
  :after general
  :demand t
  :config
  (global-jinx-mode)
  (rata-leader
    :states '(normal visual insert emacs)
    "ts" '(jinx-correct :which-key "spell correct")))

;; --- Diff-hl (git gutter indicators) ---
(use-package diff-hl
  :demand t
  :config
  (global-diff-hl-mode)
  (diff-hl-flydiff-mode)
  (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh)
  (unless (display-graphic-p)
    (diff-hl-margin-mode)))

;; --- Consult-flycheck ---
(use-package consult-flycheck
  :after (consult flycheck general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "el" '(consult-flycheck :which-key "list errors")))

;; --- Editorconfig ---
(use-package editorconfig
  :demand t
  :config
  (editorconfig-mode 1))

;; --- Browse-at-remote ---
(use-package browse-at-remote
  :after general
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "go" '(browse-at-remote :which-key "open on remote")))

;; --- Restclient (HTTP client) ---
(use-package restclient
  :mode ("\\.http\\'" . restclient-mode)
  :after general
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'restclient-mode-map
    "mr"  '(:ignore t :which-key "restclient")
    "mrr" '(restclient-http-send-current      :which-key "send request")
    "mrR" '(restclient-http-send-current-raw  :which-key "send raw")
    "mrn" '(restclient-jump-next              :which-key "next request")
    "mrp" '(restclient-jump-prev              :which-key "prev request")
    "mrc" '(restclient-copy-curl-command      :which-key "copy as curl")))

(use-package restclient-jq
  :after restclient)

;; --- Breadcrumb (LSP header-line context) ---
(use-package breadcrumb
  :after lsp-mode
  :hook (lsp-mode . breadcrumb-local-mode))

(provide 'init-dev)
