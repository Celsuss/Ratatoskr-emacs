;;; -*- lexical-binding: t; -*-
;;; init-lang.el --- Cross-cutting language infrastructure (tree-sitter, DAP, combobulate)

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
