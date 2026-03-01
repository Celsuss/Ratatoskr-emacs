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
    :states '(normal visual)
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
  :hook (lsp-mode . lsp-ui-mode)
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
  ;; Fix: org-lint returns propertized strings for line numbers (designed for
  ;; tabulated-list display). flycheck passes them raw to flycheck-error-new-at
  ;; which expects a number-or-marker. Redefine the checker to convert first.
  (with-eval-after-load 'org
    (flycheck-define-generic-checker 'org-lint
      "An Org mode syntax checker using `org-lint'."
      :start (lambda (checker callback)
               (condition-case err
                   (let ((errors
                          (delq nil
                                (mapcar
                                 (lambda (e)
                                   (pcase e
                                     (`(,_n [,line ,_trust ,desc ,_checker])
                                      (flycheck-error-new-at
                                       (string-to-number line) nil 'info desc
                                       :checker checker))
                                     (_
                                      (flycheck-error-new-at
                                       1 nil 'warning
                                       (format "Unexpected org-lint format: %S" e)
                                       :checker checker))))
                                 (org-lint)))))
                     (funcall callback 'finished errors))
                 (error (funcall callback 'errored
                                 (error-message-string err)))))
      :modes '(org-mode)
      :enabled #'flycheck-org-lint-available-p
      :verify (lambda (_)
                (let ((org-version (when (require 'org nil 'no-error)
                                     (org-version))))
                  (list (flycheck-verification-result-new
                         :label "Org-lint available"
                         :message (if (fboundp 'org-lint)
                                      (format "yes (Org %s)" org-version)
                                    "no")
                         :face (if (fboundp 'org-lint) 'success 'warning))))))))

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
    :states '(normal visual)
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
    :states '(normal visual)
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
    :states '(normal visual)
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
    :states '(normal visual)
    "pS"  '(projectile-switch-project :which-key "switch project")
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
    :states '(normal visual)
    "pf"  '(consult-projectile-find-file :which-key "find file")
    "ps"  '(consult-projectile-ripgrep :which-key "ripgrep project")))

;; --- Dirvish (enhanced dired) ---
(use-package dirvish
  :after general
  :config
  (dirvish-override-dired-mode)
  (setq dirvish-attributes '(nerd-icons file-size vc-state git-msg))
  (rata-leader
    :states '(normal visual)
    "fd"  '(dirvish :which-key "dirvish")))

;; --- Esup (startup profiler) ---
(use-package esup
  :defer t
  :custom
  (esup-depth 0))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "hP"  '(esup :which-key "profile startup")))

;; --- Jinx (modern spellcheck, replaces flyspell) ---
;; Requires enchant system package: pacman -S enchant
(use-package jinx
  :after general
  :demand t
  :if (executable-find "enchant-2")
  :config
  (global-jinx-mode)
  (rata-leader
    :states '(normal visual)
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
  :after (consult flycheck))

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
    :states '(normal visual)
    "go" '(browse-at-remote :which-key "open on remote")))

;; --- Restclient (HTTP client) ---
(use-package restclient
  :mode ("\\.http\\'" . restclient-mode)
  :after general
  :config
  (rata-leader
    :states '(normal visual)
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
