;;; -*- lexical-binding: t; -*-
;;; init-lang.el --- Language modes and DAP

;; --- Tree-sitter grammar sources ---
(setq treesit-language-source-alist
      '((go         "https://github.com/tree-sitter/tree-sitter-go")
        (python     "https://github.com/tree-sitter/tree-sitter-python")
        (rust       "https://github.com/tree-sitter/tree-sitter-rust")
        (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
        (json       "https://github.com/tree-sitter/tree-sitter-json")
        (yaml       "https://github.com/ikatyang/tree-sitter-yaml")
        (toml       "https://github.com/tree-sitter/tree-sitter-toml")
        (dockerfile "https://github.com/camdencheek/tree-sitter-dockerfile")))

;; --- Remap major modes to tree-sitter variants ---
(setq major-mode-remap-alist
      '((python-mode     . python-ts-mode)
        (go-mode         . go-ts-mode)
        (json-mode       . json-ts-mode)
        (yaml-mode       . yaml-ts-mode)
        (toml-mode       . toml-ts-mode)
        (dockerfile-mode . dockerfile-ts-mode)))

;; --- Rust (rustic) ---
(use-package rustic
  :hook (rustic-mode . lsp-deferred)
  :custom
  (rustic-lsp-client 'lsp-mode))

;; --- Cargo (Rust build commands) ---
(use-package cargo
  :after (rustic general)
  :hook (rustic-mode . cargo-minor-mode)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'rustic-mode-map
    "mc"  '(:ignore t :which-key "cargo")
    "mcb" '(cargo-process-build       :which-key "cargo build")
    "mct" '(cargo-process-test        :which-key "cargo test")
    "mcr" '(cargo-process-run         :which-key "cargo run")
    "mcc" '(cargo-process-clippy      :which-key "cargo clippy")
    "mcd" '(cargo-process-doc         :which-key "cargo doc")
    "mcf" '(cargo-process-fmt         :which-key "cargo fmt")
    "mca" '(cargo-process-add         :which-key "cargo add")
    "mcB" '(cargo-process-bench       :which-key "cargo bench")))

;; --- Go ---
(use-package go-mode
  :hook (go-mode . lsp-deferred)
  :config
  (setq go-tab-width 4))

;; --- Python ---
(use-package pyvenv
  :config
  (pyvenv-mode t))

(add-hook 'python-ts-mode-hook #'lsp-deferred)

;; --- Dockerfile ---
(use-package dockerfile-mode
  :defer t)

;; --- Terraform ---
(use-package terraform-mode
  :defer t
  :after general
  :config
  (defun rata-terraform-plan ()
    "Run terraform plan in the current directory."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform plan")))

  (defun rata-terraform-apply ()
    "Run terraform apply in the current directory."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform apply")))

  (defun rata-terraform-init ()
    "Run terraform init in the current directory."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform init")))

  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'terraform-mode-map
    "mT"  '(:ignore t :which-key "terraform")
    "mTp" '(rata-terraform-plan  :which-key "terraform plan")
    "mTa" '(rata-terraform-apply :which-key "terraform apply")
    "mTi" '(rata-terraform-init  :which-key "terraform init")))

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

;; --- Markdown Preview ---
(use-package web-server
  :ensure (web-server :host github :repo "eschulte/emacs-web-server"
                      :main "web-server.el")
  :defer t)

(use-package markdown-preview-mode
  :after (markdown-mode general)
  :commands markdown-preview-mode
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'markdown-mode-map
    "mp"  '(:ignore t :which-key "preview")
    "mpp" '(markdown-preview-mode :which-key "preview in browser")))

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

;; --- Yaml-pro (structural YAML editing) ---
(use-package yaml-pro
  :after yaml-ts-mode
  :hook (yaml-ts-mode . yaml-pro-ts-mode))

;; --- Python-pytest ---
(use-package python-pytest
  :after (python general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'python-ts-mode-map
    "mt"  '(:ignore t :which-key "test")
    "mtt" '(python-pytest-file :which-key "test file")
    "mtf" '(python-pytest-function :which-key "test function")
    "mtr" '(python-pytest-repeat :which-key "repeat last test")
    "mtl" '(python-pytest-last-failed :which-key "last failed")
    "mtp" '(python-pytest :which-key "test project")))

;; --- Pkgbuild-mode (Arch Linux) ---
(use-package pkgbuild-mode
  :mode "/PKGBUILD$"
  :after general
  :config
  (setq pkgbuild-update-sums-on-save nil)

  ;; Custom makepkg helper functions
  (defun rata-makepkg-build ()
    "Run makepkg in the current PKGBUILD directory."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "makepkg -sf")))

  (defun rata-makepkg-srcinfo ()
    "Generate .SRCINFO from current PKGBUILD."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "makepkg --printsrcinfo > .SRCINFO")))

  (defun rata-namcap-check ()
    "Run namcap on the current PKGBUILD."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile (format "namcap %s" (buffer-file-name)))))

  (defun rata-updpkgsums ()
    "Run updpkgsums on the current PKGBUILD."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "updpkgsums")))

  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'pkgbuild-mode-map
    "mp"  '(:ignore t :which-key "pkgbuild")
    "mpb" '(rata-makepkg-build    :which-key "makepkg build")
    "mps" '(rata-makepkg-srcinfo  :which-key "gen .SRCINFO")
    "mpn" '(rata-namcap-check     :which-key "namcap lint")
    "mpu" '(rata-updpkgsums       :which-key "update sums")))

;; --- Ansible ---
(use-package ansible
  :hook ((yaml-ts-mode . ansible)
         (yaml-mode    . ansible))
  :config
  (setq ansible-vault-password-file "~/.ansible-vault-pass"))

(use-package ansible-doc
  :after (ansible general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    :keymaps 'ansible-key-map
    "ma"  '(:ignore t :which-key "ansible")
    "mad" '(ansible-doc :which-key "ansible doc")))

;; --- EIN (Jupyter notebooks) ---
(use-package ein
  :after general
  :commands (ein:run ein:login ein:notebooklist-open)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "aj"  '(:ignore t :which-key "jupyter")
    "ajr" '(ein:run                  :which-key "start jupyter")
    "ajl" '(ein:login                :which-key "login to jupyter")
    "ajn" '(ein:notebooklist-open    :which-key "notebook list")))

;; --- Polymode (YAML + Go templates for Helm) ---
(use-package polymode
  :after yaml-ts-mode
  :config
  (define-hostmode poly-yaml-hostmode
    :mode 'yaml-ts-mode)

  (define-innermode poly-go-template-innermode
    :mode 'go-ts-mode
    :head-matcher "{{[-]?"
    :tail-matcher "[-]?}}"
    :head-mode 'host
    :tail-mode 'host)

  (define-polymode poly-yaml-go-template-mode
    :hostmode 'poly-yaml-hostmode
    :innermodes '(poly-go-template-innermode)))

;; Auto-activate on Helm template files
(add-to-list 'auto-mode-alist
             '("/templates/.*\\.ya?ml\\'" . poly-yaml-go-template-mode))
(add-to-list 'auto-mode-alist
             '("\\.tpl\\'" . poly-yaml-go-template-mode))

(provide 'init-lang)
