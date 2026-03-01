;;; -*- lexical-binding: t; -*-
;;; init-elfeed.el --- Elfeed RSS reader configuration

(defcustom rata-elfeed-feeds-file
  (expand-file-name "feeds.org" user-emacs-directory)
  "Path to the org file declaring elfeed feeds."
  :type 'file
  :group 'rata)

(use-package elfeed
  :ensure t
  :defer t
  :custom
  (elfeed-search-filter "@2-weeks-ago +unread")
  (elfeed-db-directory (expand-file-name "elfeed-db/" user-emacs-directory)))

(use-package elfeed-org
  :ensure t
  :after elfeed
  :custom
  (rmh-elfeed-org-files (list rata-elfeed-feeds-file))
  :config
  (elfeed-org))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "ar"  '(:ignore t :which-key "rss")
    "aro" '(elfeed :which-key "open elfeed")
    "aru" '(elfeed-update :which-key "update feeds")
    "ars" '(elfeed-search-set-filter :which-key "set filter")))

(provide 'init-elfeed)
