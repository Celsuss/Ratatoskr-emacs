;;; -*- lexical-binding: t; -*-
;;; init-snippets.el --- Yasnippet and templates

(use-package yasnippet
  :after general
  :config
  (yas-global-mode 1)
  (rata-leader
    :states '(normal visual insert emacs)
    "i"   '(:ignore t :which-key "insert")
    "is"  '(yas-insert-snippet :which-key "snippet")
    "in"  '(yas-new-snippet :which-key "new snippet")))

(use-package yasnippet-snippets
  :after yasnippet)

(use-package yatemplate
  :after yasnippet
  :config
  (yatemplate-fill-alist))

(provide 'init-snippets)
