;;; -*- lexical-binding: t; -*-
;;; init-go.el --- Go language support

;; treesit-auto (init-lang.el) routes .go files to `go-ts-mode', so all
;; enablement targets that mode -- not `go-mode', whose hook would never fire.
;; The go-mode package is kept only for its helper commands (go-import-add,
;; go-goto-imports), autoloaded via :commands.
(use-package go-mode
  :commands (go-import-add go-goto-imports))

(add-hook 'go-ts-mode-hook #'lsp-deferred)

;; Use goimports instead of gofmt (manages imports automatically). Registered
;; at top level so it does not depend on go-mode's :config ever running.
(with-eval-after-load 'apheleia
  (setf (alist-get 'go-mode apheleia-mode-alist) 'goimports)
  (setf (alist-get 'go-ts-mode apheleia-mode-alist) 'goimports))

(with-eval-after-load 'go-ts-mode
  (setq go-ts-mode-indent-offset 4))

(use-package gotest
  :after general
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
  :after general
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
