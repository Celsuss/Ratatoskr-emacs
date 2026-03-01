;;; -*- lexical-binding: t; -*-
;;; init-dashboard.el --- Dashboard / start page

;; --- Customization ---

(defgroup rata-dashboard nil
  "Ratatoskr dashboard settings."
  :group 'convenience)

(defcustom rata-dashboard-git-repos
  '("~/workspace/Ratatoskr-emacs"
    "~/workspace/second-brain")
  "List of git repositories to show status for on the dashboard."
  :type '(repeat directory)
  :group 'rata-dashboard)

;; --- Quotes (programming wisdom + Norse mythology) ---

(defvar rata-dashboard-quotes
  '(;; Programming
    "\"Simplicity is prerequisite for reliability.\" — Edsger Dijkstra"
    "\"Premature optimization is the root of all evil.\" — Donald Knuth"
    "\"The best way to predict the future is to invent it.\" — Alan Kay"
    "\"Simplicity is the ultimate sophistication.\" — Leonardo da Vinci"
    "\"Programs must be written for people to read, and only incidentally for machines to execute.\" — Abelson & Sussman"
    "\"Talk is cheap. Show me the code.\" — Linus Torvalds"
    "\"Any fool can write code that a computer can understand. Good programmers write code that humans can understand.\" — Martin Fowler"
    "\"First, solve the problem. Then, write the code.\" — John Johnson"
    "\"Controlling complexity is the essence of computer programming.\" — Brian Kernighan"
    "\"The purpose of abstraction is not to be vague, but to create a new semantic level in which one can be absolutely precise.\" — Dijkstra"
    "\"Simple things should be simple, complex things should be possible.\" — Alan Kay"
    "\"Debugging is twice as hard as writing the code in the first place.\" — Brian Kernighan"
    "\"A language that doesn't affect the way you think about programming is not worth knowing.\" — Alan Perlis"
    "\"Simplicity — the art of maximizing the amount of work not done — is essential.\" — Agile Manifesto"
    "\"Programming is not about typing, it's about thinking.\" — Rich Hickey"
    ;; Norse mythology / Hávamál
    "\"A wise man's heart is seldom glad if he is truly wise.\" — Hávamál 55"
    "\"Cattle die, kinsmen die, you yourself will also die; but the word about you will never die, if you win a good reputation.\" — Hávamál 76"
    "\"Better a humble house than none; a man is master at home.\" — Hávamál 36"
    "\"The unwise man thinks all to know, while he sits in a sheltered nook; but he knows not one thing: what he shall answer, when men shall put him to proof.\" — Hávamál 26"
    "\"Where you recognize evil, speak out against it, and give no truces to your enemies.\" — Hávamál 127"
    "\"Ratatoskr runs up and down Yggdrasil, carrying messages between the eagle and the serpent.\" — Prose Edda"
    "\"I know that I hung on that windy tree, for nine whole nights, wounded by a spear, given to Odin, myself to myself.\" — Hávamál 138"
    "\"The foolish man lies awake all night, thinking of many things; when morning comes he is weary, and all is as bad as before.\" — Hávamál 23"
    "\"With half a loaf and an empty cup I found myself a friend.\" — Hávamál 52"
    "\"Praise not the day until evening has come; a woman until she is burnt; a sword until it is tried; a maiden until she is married; ice until it has been crossed; beer until it has been drunk.\" — Hávamál 81")
  "List of quotes for the dashboard. Mix of programming and Norse mythology.")

;; --- Custom Widget: Agenda (7-day overview) ---

(defun rata-dashboard--agenda-entries ()
  "Return a list of (DATE-STRING . ENTRIES) for the next 7 days."
  (require 'org-agenda)
  (let* ((today (calendar-current-date))
         (results '()))
    (dotimes (i 7)
      (let* ((date (calendar-gregorian-from-absolute
                    (+ (calendar-absolute-from-gregorian today) i)))
             (files (org-agenda-files nil 'ifmode))
             (entries (apply #'org-agenda-get-day-entries files date
                             '(:scheduled :deadline :timestamp)))
             (day-name (if (= i 0) "Today"
                         (if (= i 1) "Tomorrow"
                           (format-time-string "%A %b %d"
                                               (encode-time 0 0 0
                                                            (nth 1 date)
                                                            (nth 0 date)
                                                            (nth 2 date)))))))
        (push (cons day-name entries) results)))
    (nreverse results)))

(defun rata-dashboard-insert-agenda (_list-size)
  "Insert a 7-day agenda overview widget into the dashboard."
  (dashboard-insert-heading "Week Agenda:"
                            nil
                            (when (display-graphic-p)
                              (nerd-icons-octicon "nf-oct-calendar"
                                                  :height 1.2
                                                  :v-adjust 0.0
                                                  :face 'dashboard-heading)))
  (insert "\n")
  (let ((agenda-data (condition-case nil
                         (rata-dashboard--agenda-entries)
                       (error nil))))
    (if (null agenda-data)
        (insert "    No agenda data available.\n")
      (dolist (day agenda-data)
        (let ((day-name (car day))
              (entries (cdr day)))
          (insert (propertize (format "  %s" day-name)
                              'face 'font-lock-keyword-face)
                  "\n")
          (if entries
              (dolist (entry entries)
                (let ((text (org-no-properties
                             (or (get-text-property 0 'txt entry) entry))))
                  (insert (format "    %s\n" (string-trim text)))))
            (insert "    (no items)\n"))))))
  (insert "\n"))

;; --- Custom Widget: Org-roam Stats ---

(defun rata-dashboard--roam-stats ()
  "Return (TOTAL-NOTES . MODIFIED-THIS-WEEK) from org-roam."
  (condition-case nil
      (progn
        (require 'org-roam)
        (require 'org-roam-db)
        (let* ((total (caar (org-roam-db-query
                             "SELECT count(*) FROM nodes WHERE level = 0")))
               (roam-dir (expand-file-name org-roam-directory))
               (week-ago (time-subtract (current-time) (days-to-time 7)))
               (modified 0))
          (when (file-directory-p roam-dir)
            (dolist (file (directory-files-recursively roam-dir "\\.org$"))
              (let ((mtime (file-attribute-modification-time
                            (file-attributes file))))
                (when (time-less-p week-ago mtime)
                  (cl-incf modified)))))
          (cons (or total 0) modified)))
    (error (cons 0 0))))

(defun rata-dashboard-insert-roam-stats (_list-size)
  "Insert org-roam statistics widget into the dashboard."
  (dashboard-insert-heading "Org-roam:"
                            nil
                            (when (display-graphic-p)
                              (nerd-icons-octicon "nf-oct-book"
                                                  :height 1.2
                                                  :v-adjust 0.0
                                                  :face 'dashboard-heading)))
  (insert "\n")
  (let ((stats (rata-dashboard--roam-stats)))
    (insert (format "    Total notes: %d\n" (car stats)))
    (insert (format "    Modified this week: %d\n" (cdr stats))))
  (insert "\n"))

;; --- Custom Widget: Git Status ---

(defun rata-dashboard--git-repo-status (repo-path)
  "Return status string for REPO-PATH: dirty, clean, or not-found."
  (let ((expanded (expand-file-name repo-path)))
    (if (not (file-directory-p (expand-file-name ".git" expanded)))
        "not a git repo"
      (let ((output (with-temp-buffer
                      (let ((default-directory expanded))
                        (call-process "git" nil t nil
                                      "status" "--porcelain")
                        (buffer-string)))))
        (if (string-empty-p (string-trim output))
            "clean"
          "dirty")))))

(defun rata-dashboard-insert-git-status (_list-size)
  "Insert git status widget for hardcoded repos into the dashboard."
  (dashboard-insert-heading "Git Status:"
                            nil
                            (when (display-graphic-p)
                              (nerd-icons-octicon "nf-oct-git_branch"
                                                  :height 1.2
                                                  :v-adjust 0.0
                                                  :face 'dashboard-heading)))
  (insert "\n")
  (dolist (repo rata-dashboard-git-repos)
    (let* ((name (file-name-nondirectory (directory-file-name repo)))
           (status (rata-dashboard--git-repo-status repo))
           (face (cond
                  ((string= status "clean") 'success)
                  ((string= status "dirty") 'warning)
                  (t 'shadow))))
      (insert (format "    %-25s " name)
              (propertize status 'face face)
              "\n")))
  (insert "\n"))

;; --- Custom Widget: Random Roam Note ---

(defvar rata-dashboard--random-note-cache nil
  "Cached random roam note; list of (id title file), refreshed each session.")

(defun rata-dashboard-insert-random-note (_list-size)
  "Insert a random org-roam note widget for serendipitous rediscovery.
Result is cached per session; reset by `dashboard-after-initialize-hook'."
  (dashboard-insert-heading "Rediscover:"
                            nil
                            (when (display-graphic-p)
                              (nerd-icons-octicon "nf-oct-light_bulb"
                                                  :height 1.2
                                                  :v-adjust 0.0
                                                  :face 'dashboard-heading)))
  (insert "\n")
  (unless rata-dashboard--random-note-cache
    (setq rata-dashboard--random-note-cache
          (condition-case nil
              (progn
                (require 'org-roam)
                (require 'org-roam-db)
                (car (org-roam-db-query
                      [:select [id title file]
                       :from nodes
                       :where (= level 0)
                       :order-by (random)
                       :limit 1])))
            (error nil))))
  (let ((node rata-dashboard--random-note-cache))
    (if node
        (let* ((title (nth 1 node))
               (file (nth 2 node)))
          (insert "    ")
          (insert-text-button title
                              'action (lambda (_btn)
                                        (find-file file))
                              'follow-link t
                              'face 'font-lock-string-face)
          (insert "\n"))
      (insert "    (org-roam not available)\n")))
  (insert "\n"))

;; Reset the cache on each new dashboard session so a fresh note is picked
(add-hook 'dashboard-after-initialize-hook
          (lambda () (setq rata-dashboard--random-note-cache nil)))

;; --- Dashboard Package ---

(use-package dashboard
  :ensure t
  :demand t
  :config
  ;; Register custom widgets
  (add-to-list 'dashboard-item-generators
               '(rata-agenda . rata-dashboard-insert-agenda))
  (add-to-list 'dashboard-item-generators
               '(rata-roam-stats . rata-dashboard-insert-roam-stats))
  (add-to-list 'dashboard-item-generators
               '(rata-git-status . rata-dashboard-insert-git-status))
  (add-to-list 'dashboard-item-generators
               '(rata-random-note . rata-dashboard-insert-random-note))

  ;; Banner / logo (fall back to built-in if logo.png is missing)
  (setq dashboard-startup-banner
        (let ((logo (expand-file-name "logo.png" user-emacs-directory)))
          (if (file-exists-p logo) logo 'official))
        dashboard-banner-logo-title "Ratatoskr Emacs"
        dashboard-image-banner-max-height 200
        dashboard-image-extra-props '(:mask heuristic))

  ;; Layout
  (setq dashboard-center-content t
        dashboard-vertically-center-content nil
        dashboard-projects-backend 'projectile)

  ;; Icons
  (setq dashboard-display-icons-p t
        dashboard-icon-type 'nerd-icons
        dashboard-set-heading-icons t
        dashboard-set-file-icons t)

  ;; Sections
  (setq dashboard-items '((projects    . 5)
                          (bookmarks   . 5)
                          (rata-agenda . 1)
                          (rata-roam-stats . 1)
                          (rata-random-note . 1)
                          (rata-git-status . 1)))

  ;; Navigator buttons (quick actions)
  (setq dashboard-navigator-buttons
        `(((,(nerd-icons-octicon "nf-oct-file" :height 1.0 :v-adjust 0.0)
            " Find File" ""
            (lambda (&rest _) (call-interactively #'find-file)))
           (,(nerd-icons-octicon "nf-oct-project" :height 1.0 :v-adjust 0.0)
            " Projects" ""
            (lambda (&rest _) (call-interactively #'projectile-switch-project)))
           (,(nerd-icons-octicon "nf-oct-calendar" :height 1.0 :v-adjust 0.0)
            " Agenda" ""
            (lambda (&rest _) (org-agenda nil "d")))
           (,(nerd-icons-octicon "nf-oct-pencil" :height 1.0 :v-adjust 0.0)
            " Capture" ""
            (lambda (&rest _) (call-interactively #'org-capture))))))

  ;; Quote as init-info (below banner)
  (setq dashboard-init-info
        (nth (random (length rata-dashboard-quotes)) rata-dashboard-quotes))

  ;; Footer: startup time + package count
  (setq dashboard-set-footer t
        dashboard-footer-messages
        (list (format "Emacs loaded in %s with %d packages"
                      (emacs-init-time "%.2fs")
                      (length package-activated-list))))

  ;; Refresh on revisit
  (setq dashboard-force-refresh t)

  ;; Evil navigation
  (evil-set-initial-state 'dashboard-mode 'normal)

  ;; Keybinding to open dashboard
  (rata-leader
    :states '(normal visual)
    "bh" '(dashboard-open :which-key "home (dashboard)"))

  (dashboard-setup-startup-hook))

(provide 'init-dashboard)
