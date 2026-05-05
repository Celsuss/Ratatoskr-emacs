;;; -*- lexical-binding: t; -*-
;;; init-python.el --- Python language support

(use-package pyvenv
  :hook (python-ts-mode . pyvenv-mode))

(add-hook 'python-ts-mode-hook #'lsp-deferred)

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

(provide 'init-python)
