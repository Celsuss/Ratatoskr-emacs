;;; -*- lexical-binding: t; -*-
;;; init-lang.el --- Language modes and DAP

;; --- Rust (rustic) ---
(use-package rustic
  :hook (rustic-mode . lsp-deferred)
  :custom
  (rustic-lsp-client 'lsp-mode))

;; --- Go ---
(use-package go-mode
  :hook (go-mode . lsp-deferred)
  :config
  (setq go-tab-width 4))

;; --- Python ---
(use-package pyvenv
  :config
  (pyvenv-mode t))

(add-hook 'python-mode-hook #'lsp-deferred)

;; --- Dockerfile ---
(use-package dockerfile-mode
  :defer t)

;; --- Terraform ---
(use-package terraform-mode
  :defer t)

;; --- Just ---
(use-package just-mode
  :defer t)

;; --- Docker management ---
(use-package docker
  :after general
  :commands docker
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "aD" '(docker :which-key "docker")))

;; --- Markdown ---
(use-package markdown-mode
  :defer t)

;; --- DAP Mode (debugging) ---
(use-package dap-mode
  :after lsp-mode
  :config
  (dap-auto-configure-mode t)
  (rata-leader
    :states '(normal visual insert emacs)
    "d"   '(:ignore t :which-key "debug")
    "dd"  '(dap-debug :which-key "debug")
    "dn"  '(dap-next :which-key "next")
    "di"  '(dap-step-in :which-key "step in")
    "do"  '(dap-step-out :which-key "step out")
    "dc"  '(dap-continue :which-key "continue")
    "db"  '(dap-breakpoint-toggle :which-key "toggle breakpoint")
    "dB"  '(dap-breakpoint-condition :which-key "conditional breakpoint")
    "dr"  '(dap-ui-repl :which-key "REPL")
    "dq"  '(dap-disconnect :which-key "disconnect")))

(provide 'init-lang)
