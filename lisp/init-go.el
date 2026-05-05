;;; -*- lexical-binding: t; -*-
;;; init-go.el --- Go language support

(use-package go-mode
  :hook (go-mode . lsp-deferred)
  :commands (go-import-add go-goto-imports)
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

(provide 'init-go)
