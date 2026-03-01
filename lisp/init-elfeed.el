;;; -*- lexical-binding: t; -*-
;;; init-elfeed.el --- Elfeed RSS reader configuration

(defcustom rata-elfeed-feeds-file
  (expand-file-name "feeds.org" user-emacs-directory)
  "Path to the org file declaring elfeed feeds."
  :type 'file
  :group 'rata)

(defcustom rata-elfeed-views
  '(("Blogs"              . "@6-months-ago +unread +blog")
    ("Dev"                . "@6-months-ago +unread +dev")
    ("Machine Learning"   . "@6-months-ago +unread +ml")
    ("Emacs"              . "@6-months-ago +unread +emacs")
    ("Linux"              . "@6-months-ago +unread +linux")
    ("Homelab"            . "@6-months-ago +unread +homelab")
    ("FOSS"               . "@6-months-ago +unread +foss")
    ("Games"              . "@6-months-ago +unread +games")
    ("Tech Radar"         . "@6-months-ago +unread +tech_radar")
    ("News"               . "@2-weeks-ago +unread +news")
    ("Humor"              . "@6-months-ago +unread +humor")
    ("All Unread"         . "@6-months-ago +unread"))
  "Named elfeed filter views."
  :type '(alist :key-type string :value-type string)
  :group 'rata)

(defvar rata-elfeed-update-timer nil
  "Auto-update timer for elfeed. Guarded against duplicate registration.")

(defun rata-elfeed--set-filter (filter)
  "Set elfeed search FILTER string."
  (elfeed-search-set-filter filter))

(defun rata-elfeed-filter-blogs ()
  "Filter elfeed to blog posts only."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +blog"))

(defun rata-elfeed-filter-dev ()
  "Filter elfeed to dev blogs."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +dev"))

(defun rata-elfeed-filter-ml ()
  "Filter elfeed to machine learning feeds."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +ml"))

(defun rata-elfeed-filter-emacs ()
  "Filter elfeed to Emacs feeds."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +emacs"))

(defun rata-elfeed-filter-linux ()
  "Filter elfeed to Linux feeds."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +linux"))

(defun rata-elfeed-filter-homelab ()
  "Filter elfeed to homelab feeds."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +homelab"))

(defun rata-elfeed-filter-foss ()
  "Filter elfeed to FOSS feeds (emacs + linux + homelab)."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +foss"))

(defun rata-elfeed-filter-games ()
  "Filter elfeed to gaming feeds."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +games"))

(defun rata-elfeed-filter-tech-radar ()
  "Filter elfeed to tech radar feeds (DZone, InfoQ)."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread +tech_radar"))

(defun rata-elfeed-filter-news ()
  "Filter elfeed to recent news."
  (interactive) (rata-elfeed--set-filter "@2-weeks-ago +unread +news"))

(defun rata-elfeed-filter-all ()
  "Show all unread elfeed entries."
  (interactive) (rata-elfeed--set-filter "@6-months-ago +unread"))

(defun rata-elfeed-capture-link ()
  "Capture current entry as a reading-list link."
  (interactive)
  (org-capture nil "l"))

(defun rata-elfeed-start-update-timer ()
  "Start the 30-min elfeed auto-update timer (idempotent)."
  (unless (and rata-elfeed-update-timer (timerp rata-elfeed-update-timer))
    (setq rata-elfeed-update-timer
          (run-at-time nil 1800 #'elfeed-update))))

(use-package elfeed
  :ensure t
  :after general
  :commands elfeed
  :hook (elfeed-search-mode . elfeed-update)
  :hook (elfeed-search-mode . rata-elfeed-start-update-timer)
  :custom
  (elfeed-search-filter "@6-months-ago +unread -news")
  (elfeed-db-directory (expand-file-name "elfeed-db/" user-emacs-directory))
  :config
  ;; 'f' prefix: filter sub-menu shown by which-key
  (general-define-key
    :states 'normal
    :keymaps 'elfeed-search-mode-map
    "f"  '(:ignore t :which-key "filter")
    "fa" '(rata-elfeed-filter-all        :which-key "all unread")
    "fb" '(rata-elfeed-filter-blogs      :which-key "blogs (dev+ml)")
    "fd" '(rata-elfeed-filter-dev        :which-key "dev")
    "fm" '(rata-elfeed-filter-ml         :which-key "machine learning")
    "fe" '(rata-elfeed-filter-emacs      :which-key "emacs")
    "fl" '(rata-elfeed-filter-linux      :which-key "linux")
    "fh" '(rata-elfeed-filter-homelab    :which-key "homelab")
    "ff" '(rata-elfeed-filter-foss       :which-key "foss (emacs+linux+homelab)")
    "fg" '(rata-elfeed-filter-games      :which-key "games")
    "ft" '(rata-elfeed-filter-tech-radar :which-key "tech radar")
    "fn" '(rata-elfeed-filter-news       :which-key "news"))

  (evil-collection-define-key 'normal 'elfeed-show-mode-map
    "e" #'rata-elfeed-capture-link))

(rata-leader
  :states '(normal visual)
  "ar"  '(:ignore t :which-key "rss")
  "aro" '(elfeed                   :which-key "open elfeed")
  "aru" '(elfeed-update            :which-key "update feeds")
  "ars" '(elfeed-search-set-filter :which-key "set filter"))

(use-package elfeed-org
  :ensure t
  :after elfeed
  :custom
  (rmh-elfeed-org-files (list rata-elfeed-feeds-file))
  :config
  (elfeed-org))

(use-package elfeed-goodies
  :ensure t
  :after elfeed
  :config
  (setq elfeed-goodies/entry-pane-position 'right)
  (setq elfeed-goodies/entry-pane-size 0.7)
  (setq elfeed-goodies/show-mode-line nil)
  (setq elfeed-goodies/switch-to-entry-no-new-windows t)
  (elfeed-goodies/setup))

(provide 'init-elfeed)
