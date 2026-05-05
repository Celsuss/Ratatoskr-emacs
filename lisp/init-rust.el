;;; -*- lexical-binding: t; -*-
;;; init-rust.el --- Rust language support

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

(provide 'init-rust)
