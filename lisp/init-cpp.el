;;; -*- lexical-binding: t; -*-
;;; init-cpp.el --- C / C++ language support (GDExtension / general)

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

(provide 'init-cpp)
