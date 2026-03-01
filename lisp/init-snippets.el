;;; -*- lexical-binding: t; -*-
;;; init-snippets.el --- Yasnippet and templates

(defun rata-insert-date-today ()
  "Insert today's date as an active org timestamp."
  (interactive)
  (org-insert-time-stamp (current-time)))

(defun rata-insert-date-pick ()
  "Open org calendar picker and insert the chosen date as an active timestamp."
  (interactive)
  (org-time-stamp nil))

(use-package yasnippet
  :after general
  :config
  (setq yas-snippet-dirs
        (list (expand-file-name "snippets" user-emacs-directory)
              'yas-installed-snippets-dir))
  (yas-global-mode 1)
  (rata-leader
    :states '(normal visual)
    "i"   '(:ignore t :which-key "insert")
    "is"  '(yas-insert-snippet :which-key "snippet")
    "in"  '(yas-new-snippet :which-key "new snippet")
    "id"  '(:ignore t :which-key "date")
    "idt" '(rata-insert-date-today :which-key "today")
    "idd" '(rata-insert-date-pick  :which-key "pick date")))

(use-package yasnippet-snippets
  :after yasnippet)

(use-package yatemplate
  :after yasnippet
  :config
  (yatemplate-fill-alist))

(provide 'init-snippets)
