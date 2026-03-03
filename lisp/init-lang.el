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
        (dockerfile "https://github.com/camdencheek/tree-sitter-dockerfile")
        (cpp        "https://github.com/tree-sitter/tree-sitter-cpp")
        (c          "https://github.com/tree-sitter/tree-sitter-c")))

;; --- treesit-auto: auto-install grammars & remap modes ---
(use-package treesit-auto
  :if (treesit-available-p)
  :demand t
  :custom
  (treesit-auto-install 'prompt)
  :config
  (global-treesit-auto-mode))

;; --- Rust (rustic) ---
(use-package rustic
  :hook (rustic-mode . lsp-deferred)
  :custom
  (rustic-lsp-client 'lsp-mode)
  (rustic-analyzer-command '("rustup" "run" "nightly" "rust-analyzer")))

;; --- Cargo (Rust build commands) ---
(use-package cargo
  :after (rustic general)
  :hook (rustic-mode . cargo-minor-mode)
  :config
  (rata-leader
    :states '(normal visual)
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
  (setq go-tab-width 4)
  ;; Use goimports instead of gofmt (manages imports automatically)
  (setf (alist-get 'go-mode apheleia-mode-alist) 'goimports)
  (setf (alist-get 'go-ts-mode apheleia-mode-alist) 'goimports))

(use-package gotest
  :after (go-mode general)
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'go-ts-mode-map
    "mt"  '(:ignore t :which-key "test")
    "mtt" '(go-test-current-file      :which-key "test file")
    "mtf" '(go-test-current-test      :which-key "test function")
    "mtp" '(go-test-current-project   :which-key "test project")
    "mtb" '(go-test-current-benchmark :which-key "benchmark")
    "mg"  '(:ignore t :which-key "go")
    "mgr" '(go-run         :which-key "go run")
    "mgi" '(go-import-add  :which-key "add import")
    "mgI" '(go-goto-imports :which-key "goto imports")))

(use-package go-tag
  :after (go-mode general)
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'go-ts-mode-map
    "ms"  '(:ignore t :which-key "struct")
    "msa" '(go-tag-add    :which-key "add struct tags")
    "msr" '(go-tag-remove :which-key "remove struct tags")))

(use-package dap-dlv-go
  :ensure nil
  :after dap-mode)

;; --- Python ---
(use-package pyvenv
  :hook (python-ts-mode . pyvenv-mode))

(add-hook 'python-ts-mode-hook #'lsp-deferred)

;; --- Dockerfile ---
(use-package dockerfile-mode
  :defer t)

;; --- C++ / C (GDExtension / general) ---
(add-to-list 'auto-mode-alist '("\\.h\\'" . c++-ts-mode))
(add-hook 'c++-ts-mode-hook #'lsp-deferred)
(add-hook 'c-ts-mode-hook #'lsp-deferred)

(with-eval-after-load 'lsp-mode
  (setq lsp-clients-clangd-args
        '("--header-insertion=never"
          "--clang-tidy"
          "--completion-style=detailed"
          "--background-index")))

(with-eval-after-load 'apheleia
  (setf (alist-get 'c++-ts-mode apheleia-mode-alist) 'clang-format)
  (setf (alist-get 'c-ts-mode apheleia-mode-alist) 'clang-format))

;; --- DAP / LLDB (C++ debugging) ---
(with-eval-after-load 'dap-mode
  (require 'dap-lldb))

;; --- CMake ---
(use-package cmake-mode
  :mode (("CMakeLists\\.txt\\'" . cmake-mode)
         ("\\.cmake\\'" . cmake-mode))
  :after general
  :config
  (defun rata-cmake-configure ()
    "Run cmake configure, generating build/ with Unix Makefiles.
Runs from the projectile project root."
    (interactive)
    (let ((default-directory (projectile-project-root)))
      (compile "cmake -S . -B build -G 'Unix Makefiles'")))

  (defun rata-cmake-build ()
    "Build the cmake project in build/.
Runs from the projectile project root."
    (interactive)
    (let ((default-directory (projectile-project-root)))
      (compile "cmake --build build")))

  (defun rata-cmake-clean ()
    "Clean the cmake build directory without reconfiguring.
Runs from the projectile project root."
    (interactive)
    (let ((default-directory (projectile-project-root)))
      (compile "cmake --build build --target clean")))

  (defun rata-cmake-rebuild ()
    "Clean and rebuild the cmake project in one step.
Runs from the projectile project root."
    (interactive)
    (let ((default-directory (projectile-project-root)))
      (compile "cmake --build build --clean-first")))

  (rata-leader
    :states '(normal visual)
    :keymaps 'cmake-mode-map
    "mc"  '(:ignore t :which-key "cmake")
    "mcc" '(rata-cmake-configure :which-key "configure")
    "mcb" '(rata-cmake-build     :which-key "build")
    "mcl" '(rata-cmake-clean     :which-key "clean")
    "mcr" '(rata-cmake-rebuild   :which-key "rebuild")))

;; --- Terraform ---
(use-package terraform-mode
  :defer t
  :after general
  :config
  (defun rata-terraform-plan ()
    "Run `terraform plan` in the directory of the current file.
Shows the execution plan without applying changes."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform plan")))

  (defun rata-terraform-apply ()
    "Run `terraform apply` in the directory of the current file.
Applies the execution plan to the infrastructure."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform apply")))

  (defun rata-terraform-init ()
    "Run `terraform init` in the directory of the current file.
Initializes the working directory with providers and modules."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "terraform init")))

  (rata-leader
    :states '(normal visual)
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
    :states '(normal visual)
    "aD" '(docker :which-key "docker")))

;; --- Markdown ---
(use-package markdown-mode
  :defer t)

;; --- Markdown Preview ---
(use-package web-server
  :ensure (web-server :host github :repo "eschulte/emacs-web-server"
                      :local-repo "emacs-web-server.github.eschulte"
                      :main "web-server.el")
  :defer t)

(use-package markdown-preview-mode
  :after (markdown-mode general)
  :commands markdown-preview-mode
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'markdown-mode-map
    "mp"  '(:ignore t :which-key "preview")
    "mpp" '(markdown-preview-mode :which-key "preview in browser")))

;; --- DAP Mode (debugging) ---
(use-package dap-mode
  :after lsp-mode
  :config
  (dap-auto-configure-mode t)
  (rata-leader
    :states '(normal visual)
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
  :after general
  :commands (python-pytest python-pytest-file python-pytest-function
             python-pytest-repeat python-pytest-last-failed)
  :config
  (rata-leader
    :states '(normal visual)
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
    "Build the current PKGBUILD package using makepkg -sf.
Skips checksums (-s) and forces rebuilding (-f)."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "makepkg -sf")))

  (defun rata-makepkg-srcinfo ()
    "Generate .SRCINFO from the current PKGBUILD.
Required for AUR submissions."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "makepkg --printsrcinfo > .SRCINFO")))

  (defun rata-namcap-check ()
    "Run namcap linter on the current PKGBUILD file.
Reports packaging errors and policy violations."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile (format "namcap %s" (buffer-file-name)))))

  (defun rata-updpkgsums ()
    "Update checksums in the current PKGBUILD using updpkgsums.
Downloads sources and recalculates sha256sums."
    (interactive)
    (let ((default-directory (file-name-directory (buffer-file-name))))
      (compile "updpkgsums")))

  (rata-leader
    :states '(normal visual)
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
    :states '(normal visual)
    :keymaps 'ansible-key-map
    "ma"  '(:ignore t :which-key "ansible")
    "mad" '(ansible-doc :which-key "ansible doc")))

;; --- EIN (Jupyter notebooks) ---
(use-package ein
  :after general
  :commands (ein:run ein:login ein:notebooklist-open)
  :config
  (rata-leader
    :states '(normal visual)
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

;; --- Combobulate (tree-sitter structural editing) ---
(use-package combobulate
  :ensure (combobulate :host github :repo "mickeynp/combobulate")
  :after evil
  :hook ((python-ts-mode     . combobulate-mode)
         (go-ts-mode         . combobulate-mode)
         (yaml-ts-mode       . combobulate-mode)
         (json-ts-mode       . combobulate-mode)
         (typescript-ts-mode . combobulate-mode)
         (toml-ts-mode       . combobulate-mode)
         (css-mode           . combobulate-mode)
         (html-mode          . combobulate-mode))
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'combobulate-key-map
    "mS"  '(:ignore t :which-key "structural")
    "mSs" '(combobulate-avy-jump          :which-key "avy jump node")
    "mSu" '(combobulate-navigate-up       :which-key "up (parent)")
    "mSd" '(combobulate-navigate-down     :which-key "down (child)")
    "mSn" '(combobulate-navigate-next     :which-key "next sibling")
    "mSp" '(combobulate-navigate-previous :which-key "prev sibling")
    "mSk" '(combobulate-drag-up           :which-key "drag up")
    "mSj" '(combobulate-drag-down         :which-key "drag down")
    "mSt" '(combobulate                   :which-key "transient menu")))

(provide 'init-lang)
