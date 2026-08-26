;;; -*- lexical-binding: t; -*-
;;; init-elfeed.el --- Elfeed RSS reader configuration

(defcustom rata-elfeed-feeds-file
  (expand-file-name "feeds.org" user-emacs-directory)
  "Path to the org file declaring elfeed feeds."
  :type 'file
  :group 'rata)

(defcustom rata-elfeed-views
  ;; (KEY SLUG LABEL FILTER).  Single source of truth: the commands and the
  ;; `f'-prefix keys are both generated from this list, so a new view is one
  ;; row here and nothing else.  KEY nil means "no key" — the view is still a
  ;; command and still shows up in `rata-elfeed-filter-view'.
  ;;
  ;; Every +tag here must exist in `rata-elfeed-feeds-file'; a tag that matches
  ;; nothing yields an empty entry list with no error, which is why
  ;; `rata-test-elfeed-view-tags-exist-in-feeds-org' checks the contract.
  '(;; Domain — these tags are the section headings of feeds.org.
    ("a" "all"        "All Unread"        "@6-months-ago +unread")
    ("b" "blogs"      "Blogs"             "@6-months-ago +unread +blog")
    ("d" "dev"        "Dev"               "@6-months-ago +unread +dev")
    ("m" "ml"         "Machine Learning"  "@6-months-ago +unread +ml")
    ("D" "data"       "Data & MLOps"      "@6-months-ago +unread +data")
    ("e" "emacs"      "Emacs"             "@6-months-ago +unread +emacs")
    ("l" "linux"      "Linux"             "@6-months-ago +unread +linux")
    ("h" "homelab"    "Homelab"           "@6-months-ago +unread +homelab")
    ("f" "foss"       "FOSS"              "@6-months-ago +unread +foss")
    ("g" "games"      "Games"             "@6-months-ago +unread +games")
    ("t" "tech-radar" "Tech Radar"        "@6-months-ago +unread +tech_radar")
    ("n" "news"       "News"              "@2-weeks-ago +unread +news")
    ("s" "security"   "Security"          "@6-months-ago +unread +security")
    ("H" "humor"      "Humor"             "@6-months-ago +unread +humor")
    ;; Cadence and reading effort.  The time window is part of the view: a
    ;; firehose is only useful fresh, a slow burner is worth a year of backlog.
    ("F" "firehose"   "Firehose"          "@3-days-ago +unread +firehose")
    ("S" "slow"       "Slow Burners"      "@1-year-ago +unread +slow")
    ("L" "deep"       "Long-form"         "@1-year-ago +unread +deep")
    ;; Content type.
    ("c" "corp"       "Corp Eng Blogs"    "@6-months-ago +unread +corp")
    ("r" "release"    "Releases"          "@3-months-ago +unread +release")
    ("A" "aggregator" "Aggregators"       "@2-weeks-ago +unread +aggregator")
    (nil "comic"      "Comics"            "@1-month-ago +unread +comic")
    ;; Topic — cuts across sections, which is the whole point.
    ("i" "llm"        "AI & LLM"          "@6-months-ago +unread +llm")
    ("k" "k8s"        "Kubernetes"        "@6-months-ago +unread +k8s")
    (nil "rust"       "Rust"              "@1-year-ago +unread +rust")
    (nil "python"     "Python"            "@1-year-ago +unread +python")
    (nil "golang"     "Go"                "@1-year-ago +unread +golang")
    (nil "databases"  "Databases"         "@1-year-ago +unread +databases")
    (nil "systems"    "Systems"           "@1-year-ago +unread +systems")
    (nil "kernel"     "Kernel"            "@6-months-ago +unread +kernel")
    (nil "devops"     "DevOps"            "@6-months-ago +unread +devops")
    (nil "sre"        "SRE & Ops"         "@1-year-ago +unread +sre")
    (nil "networking" "Networking"        "@1-year-ago +unread +networking")
    (nil "selfhost"   "Self-hosting"      "@6-months-ago +unread +selfhost")
    (nil "hardware"   "Hardware"          "@1-month-ago +unread +hardware")
    (nil "distro"     "Distros"           "@1-month-ago +unread +distro")
    (nil "research"   "Research"          "@1-year-ago +unread +research"))
  "Elfeed filter views, as (KEY SLUG LABEL FILTER).
KEY is appended to the `f' prefix in `elfeed-search-mode-map', or nil for
a view reachable only through `rata-elfeed-filter-view'.  SLUG names the
generated command `rata-elfeed-filter-SLUG'; it is spelled out rather
than derived from LABEL so that the command names stay greppable."
  :type '(repeat (list (choice (const :tag "No key" nil) string)
                       (string :tag "Command slug")
                       (string :tag "Label")
                       (string :tag "Filter")))
  :group 'rata)

(defvar rata-elfeed-update-timer nil
  "Auto-update timer for elfeed. Guarded against duplicate registration.")

(defun rata-elfeed--set-filter (filter)
  "Set elfeed search FILTER string."
  (elfeed-search-set-filter filter))

(defun rata-elfeed--view-symbol (slug)
  "Return the command symbol for view SLUG."
  (intern (format "rata-elfeed-filter-%s" slug)))

(defun rata-elfeed-define-view-commands ()
  "Define `rata-elfeed-filter-SLUG' for every `rata-elfeed-views' entry.
Called at load time, not from a `use-package' :config block, so the
commands satisfy `commandp' whether or not elfeed itself has loaded."
  (pcase-dolist (`(,_key ,slug ,label ,filter) rata-elfeed-views)
    (defalias (rata-elfeed--view-symbol slug)
      (lambda () (interactive) (rata-elfeed--set-filter filter))
      (format "Filter elfeed to %s.\n\nFilter: %s" label filter))))

(defun rata-elfeed-bind-view-keys ()
  "Bind the keyed `rata-elfeed-views' under `f' in `elfeed-search-mode-map'.
Must run after elfeed loads — the keymap does not exist before that."
  (let ((args (list "f"  '(:ignore t :which-key "filter")
                    "fv" '(rata-elfeed-filter-view :which-key "pick view..."))))
    (pcase-dolist (`(,key ,slug ,label ,_filter) rata-elfeed-views)
      (when key
        (setq args (nconc args (list (concat "f" key)
                                    (list (rata-elfeed--view-symbol slug)
                                          :which-key (downcase label)))))))
    (apply #'general-define-key
           :states 'normal
           :keymaps 'elfeed-search-mode-map
           args)))

(defun rata-elfeed-filter-view ()
  "Pick an elfeed view from `rata-elfeed-views' by name.
The escape hatch for the views that have no key — the `f' prefix does
not have to grow every time the tag vocabulary does."
  (interactive)
  (let ((table (mapcar (lambda (v) (cons (nth 2 v) (nth 3 v))) rata-elfeed-views)))
    (rata-elfeed--set-filter
     (cdr (assoc (completing-read "Elfeed view: " table nil t) table)))))

(rata-elfeed-define-view-commands)

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
  :commands (elfeed elfeed-update elfeed-search-set-filter)
  :hook (elfeed-search-mode . elfeed-update)
  :hook (elfeed-search-mode . rata-elfeed-start-update-timer)
  :custom
  (elfeed-search-filter "@6-months-ago +unread -news")
  (elfeed-db-directory (expand-file-name "elfeed-db/" user-emacs-directory))
  :config
  ;; 'f' prefix: filter sub-menu shown by which-key.  Scoped to
  ;; elfeed-search-mode-map, so :config is the right place — the keymap does
  ;; not exist until the package loads.
  (rata-elfeed-bind-view-keys)

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
