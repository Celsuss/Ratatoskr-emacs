;;; -*- lexical-binding: t; -*-
;;; init-org.el --- Org mode configuration

;; --- Path customizations (override before use-package org loads) ---

(defgroup rata nil
  "Ratatoskr Emacs customizations."
  :group 'convenience)

(defcustom rata-org-roam-dir (expand-file-name "~/workspace/second-brain/org-roam/")
  "Base directory for org-roam files."
  :type 'directory
  :group 'rata)

(defcustom rata-hugo-dir (expand-file-name "~/workspace/second-brain/hugo/")
  "Hugo blog directory."
  :type 'directory
  :group 'rata)

(defun rata-org-capture-fleeting ()
  "Capture a fleeting note to inbox.org."
  (interactive)
  (org-capture nil "f"))

(use-package org
  :defer t
  :after general
  :commands (org-capture org-agenda org-todo-list org-deadline)
  :hook (org-mode . auto-fill-mode)
  :config
  (setq-default fill-column 80)
  (rata-leader
   :states '(normal visual motion)
   "o"  '(:ignore t :which-key "org")
   "oc" '(org-capture :which-key "org capture")
   "oa" '(org-agenda :which-key "org agenda")
   "ot" '(org-todo-list :which-key "list all TODOs")
   "od" '(org-deadline :which-key "deadline")
   "of" '(rata-org-capture-fleeting :which-key "fleeting note"))

  ;;;; Org Agenda
  (setq org-agenda-inhibit-startup t)
  (setq org-agenda-dim-blocked-tasks nil)
  (setq org-agenda-skip-unavailable-files t)

  ;; Agenda window layout
  (setq org-agenda-window-setup 'reorganize-frame)
  (setq org-agenda-restore-windows-after-quit t)
  (setq org-agenda-window-frame-fractions '(0.8 . 0.9))

  (advice-add 'org-agenda :around
              (lambda (orig-fun &rest args)
                (let ((split-width-threshold 40)
                      (split-height-threshold nil))
                  (apply orig-fun args))))

  (setq org-agenda-prefix-format
        '((agenda . " %i %?-12t% s")
          (todo   . " %i %?-12t% s")
          (tags   . " %i %?-12t% s")
          (search . " %i %?-12t% s")))

  (setq org-agenda-files
        (list (expand-file-name "inbox.org" rata-org-roam-dir)))

  ;; Tag-based agenda inclusion: dynamically add roam files with :hastodo: tag
  (defun rata-org-roam-agenda-files ()
    "Return list of org-roam files tagged with :hastodo:."
    (when (fboundp 'org-roam-db-query)
      (mapcar #'car
              (org-roam-db-query
               [:select [nodes:file]
                        :from tags
                        :left-join nodes
                        :on (= tags:node-id nodes:id)
                        :where (= tags:tag "hastodo")
                        :group-by nodes:file]))))

  (defun rata-org-agenda-files-with-roam ()
    "Return combined agenda files: static list + roam :hastodo: files."
    (delete-dups (append org-agenda-files (rata-org-roam-agenda-files))))

  ;; Advise org-agenda to include roam :hastodo: files
  (defun rata-org-agenda-files-advice (orig-fun &rest args)
    "Advice to dynamically include roam :hastodo: files in agenda."
    (let ((org-agenda-files (rata-org-agenda-files-with-roam)))
      (apply orig-fun args)))
  (advice-add 'org-agenda :around #'rata-org-agenda-files-advice)
  (advice-add 'org-todo-list :around #'rata-org-agenda-files-advice)

  (org-super-agenda-mode)

  ;; Org habits
  (add-to-list 'org-modules 'org-habit)
  (require 'org-habit)
  (setq org-habit-graph-column 60)
  (setq org-habit-show-habits-only-for-today nil)
  (setq org-agenda-skip-scheduled-if-done nil)

  ;; Org directory
  (setq org-directory rata-org-roam-dir)

  ;; Dependency tracking
  (setq org-enforce-todo-dependencies t)
  (setq org-enforce-todo-checkbox-dependencies t)

  ;;;; Org Babel — source block execution
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((shell      . t)
     (python     . t)
     (rust       . t)
     (emacs-lisp . t)))
  (setq org-confirm-babel-evaluate
        (lambda (lang _body)
          (not (member lang '("emacs-lisp" "elisp")))))
  (setq org-babel-python-command "python3")

  ;; Capture templates
  (setq org-capture-templates
        `(("t" "TODO" entry (file ,(expand-file-name "todo.org" rata-org-roam-dir))
           "** TODO %?\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("w" "Work Task" entry (file ,(expand-file-name "work_tasks.org" rata-org-roam-dir))
           "** TODO %? :work:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("h" "Home Lab Task" entry
           (file+headline ,(expand-file-name "homelab_tasks.org" rata-org-roam-dir) "Tasks")
           "** TODO %? :homelab:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("e" "Emacs Tweak" entry (file ,(expand-file-name "emacs_tweak_tasks.org" rata-org-roam-dir))
           "** TODO %? :emacs:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("d" "Dotfiles Tweak" entry (file ,(expand-file-name "dotfiles_tweak_tasks.org" rata-org-roam-dir))
           "** TODO %? :dotfiles:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("c" "Curriculum Task" entry (file ,(expand-file-name "curriculum_tasks.org" rata-org-roam-dir))
           "** TODO %? :curriculum:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("l" "Link/Read Later" entry
           (file+headline ,(expand-file-name "reading-list.org" rata-org-roam-dir) "Reading List")
           "* TODO %a :reading:\nCaptured on: %U\n"
           :empty-lines 1
           :immediate-finish t)

          ("f" "Fleeting Note (Inbox)" entry
           (file ,(expand-file-name "inbox.org" rata-org-roam-dir))
           "** %U %?\n%i\n%a"
           :empty-lines 1))))

;; --- Evil Org (context-aware o/O for tables and items) ---
(use-package evil-org
  :after (org evil)
  :hook (org-mode . evil-org-mode)
  :config
  (evil-org-set-key-theme '(navigation insert textobjects additional calendar)))

;; --- Org Agenda Evil setup ---
;; org-agenda-mode is in evil-emacs-state-modes by default, which disables evil
;; entirely. Switch to motion state so the SPC leader and evil navigation work.
(with-eval-after-load 'org-agenda
  (evil-set-initial-state 'org-agenda-mode 'motion)
  (evil-define-key 'motion org-agenda-mode-map
    (kbd "j")   #'org-agenda-next-line
    (kbd "k")   #'org-agenda-previous-line
    (kbd "RET") #'org-agenda-switch-to
    (kbd "TAB") #'org-agenda-goto
    (kbd "t")   #'org-agenda-todo
    (kbd "s")   #'org-agenda-schedule
    (kbd "d")   #'org-agenda-deadline
    (kbd "r")   #'org-agenda-redo
    (kbd "q")   #'org-agenda-quit
    (kbd "Q")   #'org-agenda-Quit
    (kbd ".")   #'org-agenda-goto-today
    (kbd "f")   #'org-agenda-later
    (kbd "b")   #'org-agenda-earlier
    (kbd "v")   #'org-agenda-view-mode-dispatch
    (kbd "[")   #'org-agenda-earlier
    (kbd "]")   #'org-agenda-later))

;; --- org-super-agenda + Evil compatibility ---
;; org-super-agenda-header-map is a copy of org-agenda-mode-map taken at load
;; time and applied as a `keymap' text property on group-header lines.
;; Text-property keymaps have higher priority than evil's emulation maps, so
;; SPC/j/k on headers bypass evil entirely.
;; Fix: replace with an empty sparse keymap so lookups fall through to evil.
(with-eval-after-load 'org-super-agenda
  (setq org-super-agenda-header-map (make-sparse-keymap)))

;; --- ob-rust (Rust source blocks for org-babel) ---
(use-package ob-rust :ensure t :defer t)

;; --- Org Roam ---
(dolist (cmd '(org-roam-buffer-toggle org-roam-node-find org-roam-graph
               org-roam-node-insert org-roam-capture
               org-roam-dailies-capture-today org-roam-dailies-goto-today
               org-roam-dailies-goto-yesterday org-roam-dailies-goto-tomorrow
               org-roam-dailies-goto-date))
  (autoload cmd "org-roam" nil t))

(defun rata-toggle-hastodo-filetag ()
  "Toggle :hastodo: filetag on the current org-roam buffer.
When present the file is included in org-agenda via the :hastodo: query."
  (interactive)
  (unless (org-roam-file-p)
    (user-error "Not an org-roam file"))
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^#\\+filetags:.*:hastodo:" nil t)
        (progn
          (goto-char (point-min))
          (re-search-forward "^#\\+filetags:" nil t)
          (save-restriction
            (narrow-to-region (point) (line-end-position))
            (goto-char (point-min))
            (while (re-search-forward ":hastodo" nil t)
              (replace-match "")))
          (message "Removed :hastodo: — file excluded from agenda"))
      (goto-char (point-min))
      (if (re-search-forward "^#\\+filetags:\\s-*" nil t)
          (progn
            (goto-char (line-end-position))
            (unless (eq (char-before) ?:) (insert ":"))
            (insert "hastodo:")
            (message "Added :hastodo: — file included in agenda"))
        (goto-char (point-min))
        (re-search-forward "^#\\+\\(title\\|date\\|author\\):" nil t)
        (end-of-line)
        (insert "\n#+filetags: :hastodo:")
        (message "Added #+filetags: :hastodo: — file included in agenda"))))
  (save-buffer)
  (org-roam-db-update-file))

(use-package org-roam
  :after (org general)
  :custom
  (org-roam-directory (file-truename rata-org-roam-dir))
  (org-roam-completion-everywhere t)
  (org-roam-mode-sections
   (list #'org-roam-backlinks-section
         #'org-roam-reflinks-section
         #'org-roam-unlinked-references-section))
  (org-roam-capture-templates `(("d" "default" plain
                                 "%?"
                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n\n"
                                                             "* ${title}"))
                                 :unnarrowed t)

                                ("p" "project" plain
                                 "\n* TODO ${title}
One of [[id:1ae70a1c-485e-43fb-acc2-4c364510d632][my projects]].

** Goal
Describe the outcome of this project.

** Kanban Board
#+BEGIN: kanban :mirrored t
#+END:

** Tasks
*** TODO Setup Project Structure
*** TODO Define milestones
%?"

                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n"
                                                             "#+filetags: :project:${slug}:hastodo:\n"
                                                             "#+SEQ_TODO: TODO STRT WAIT | DONE\n"
                                                             "#+startup: content\n"
                                                             "\n"))
                                 :unnarrowed t)


                                ("b" "blog-post" plain
                                 "\n
One of my [[id:b0b348f1-7824-4a8c-af56-46ad9372071f][blog post]]s.

* ${title}
:properties:
:export_hugo_section: /posts/
:export_file_name:
:end:"

                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n"
                                                             "#+hugo_base_dir: ../hugo/\n"
                                                             "\n"))
                                 :unnarrowed t)

                                ("m" "meeting" plain
                                 "\n* Meeting Notes\n%?\n\n* Action Items\n** TODO \n"
                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n"
                                                             "#+filetags: :work:hastodo:\n"))
                                 :unnarrowed t)

                                ("e" "tool evaluation" plain
                                 "\n* ${title}\n\n** What it does\n%?\n\n** Pros\n- \n\n** Cons\n- \n\n** Alternatives & Comparison\n| Tool | Pros | Cons | Verdict |\n|------+------+------+---------|\n| ${title} | | | |\n| | | | |\n\n** Verdict\n/adopt · trial · reject · revisit/\n"
                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n"
                                                             "#+filetags: :tool-eval:\n"))
                                 :unnarrowed t)

                                ("T" "troubleshooting" plain
                                 "\n* Problem\n%?\n\n* Environment\n- OS: \n- Tool version: \n\n* Steps Tried\n1. \n\n* Root Cause\n\n* Solution\n"
                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org"
                                                    ,(concat "#+title: ${title}\n"
                                                             "#+author: " user-full-name "\n"
                                                             "#+date: %U\n"
                                                             "#+filetags: :troubleshooting:\n"))
                                 :unnarrowed t)))

  :config
  (rata-leader
   :states '(normal visual)
   "or"  '(:ignore t :which-key "Org roam")
   "orl" '(org-roam-buffer-toggle :which-key "toggle buffer")
   "orf" '(org-roam-node-find :which-key "find node")
   "org" '(org-roam-graph :which-key "show graph")
   "ori" '(org-roam-node-insert :which-key "insert node")
   "orc" '(org-roam-capture :which-key "capture node")
   "ord"  '(:ignore t :which-key "Org roam dailies")
   "ordc" '(org-roam-dailies-capture-today :which-key "capture today")
   "ordt" '(org-roam-dailies-goto-today :which-key "goto today")
   "ordy" '(org-roam-dailies-goto-yesterday :which-key "goto yesterday")
   "ordm" '(org-roam-dailies-goto-tomorrow :which-key "goto tomorrow")
   "ordd" '(org-roam-dailies-goto-date :which-key "goto date"))

  ;; Dailies
  (setq org-roam-dailies-directory (expand-file-name "daily" rata-org-roam-dir))
  (setq org-roam-dailies-capture-templates
        `(("d" "default" entry
           "** %<%H:%M> %?"
           :target (file+head+olp "%<%Y-%m-%d>.org"
                                  "#+title: %<%A %B %d, %Y>
#+filetags: :daily:
#+author: Jens Lordén

* Daily notes for %<%A %B %d, %Y>

* Morning Protocol
- [ ] Review Agenda (Work & Projects)
- [ ] Check email
- [ ] Top 3 Priorities for Today
  1. [ ]
  2. [ ]
  3. [ ]
- Hours slept:

* Habits
- [ ] Commit Dotfiles/Emacs Tweaks
- [ ] Clear Inbox
- [ ] Workout
- [ ] Chinese Study
- [ ] Reading
- [ ] Supplements
  - [ ] Creatine
  - [ ] Protein
  - [ ] Vitamins

* Nutrition
| Food  | Amount (g) | Kcal/100g | P/100g | Kcal (Tot) | P (Tot) | Meal         |
|-------+------------+-----------+--------+------------+---------+--------------|
|       |            |           |        |          0 |     0.0 | Breakfast    |
|       |            |           |        |          0 |     0.0 | Lunch        |
|       |            |           |        |          0 |     0.0 | Pre workout  |
|       |            |           |        |          0 |     0.0 | Post workout |
|       |            |           |        |          0 |     0.0 | Dinner       |
|       |            |           |        |          0 |     0.0 |              |
|-------+------------+-----------+--------+------------+---------+--------------|
| *Total* |            |           |        |          0 |      0. |              |
#+TBLFM: $5=($2/100)*$3;%.0f::$6=($2/100)*$4;%.1f::@>$5=vsum(@I..@II)::@>$6=vsum(@I..@II)


* Log
"
                                  ("Log"))
           :empty-lines-before 1
           :empty-lines-after 1)))

  (rata-leader
   :states '(normal visual)
   "oh" '(rata-toggle-hastodo-filetag :which-key "toggle agenda inclusion"))

  (org-roam-db-autosync-mode))

;; --- Org Roam QL ---

(defun rata-roam-orphan-notes ()
  "Show org-roam notes with zero backlinks."
  (interactive)
  (org-roam-ql-search
   '(not (backlink-count > 0))
   "Orphan notes (no backlinks)"))

(defun rata-roam-recent-notes ()
  "Show org-roam notes modified in the last 7 days."
  (interactive)
  (org-roam-ql-search
   `(file-mtime > ,(- (float-time) (* 7 24 60 60)))
   "Notes modified this week"))

(defun rata-roam-work-notes ()
  "Show all org-roam notes tagged :work:."
  (interactive)
  (org-roam-ql-search
   '(tags "work")
   "Work notes"))

(defun rata-roam-stale-todos ()
  "Show org-roam notes with TODOs older than 2 weeks."
  (interactive)
  (org-roam-ql-search
   `(and (todo) (file-mtime < ,(- (float-time) (* 14 24 60 60))))
   "Stale TODOs (>2 weeks)"))

(use-package org-roam-ql
  :after (org-roam general)
  :commands (org-roam-ql-search)
  :config
  (rata-leader
   :states '(normal visual)
   "orq"  '(:ignore t :which-key "roam queries")
   "orqo" '(rata-roam-orphan-notes  :which-key "orphan notes")
   "orqr" '(rata-roam-recent-notes  :which-key "recent notes")
   "orqw" '(rata-roam-work-notes    :which-key "work notes")
   "orqt" '(rata-roam-stale-todos   :which-key "stale TODOs")))

;; --- Org Super Agenda ---
(use-package org-super-agenda
  :after org
  :config
  (setq org-agenda-custom-commands
        '(("d" "Dashboard"
           ((agenda ""
                    ((org-agenda-overriding-header "Agenda")
                     (org-super-agenda-groups
                      '((:name "Overdue" :deadline past :face 'error :order 1)
                        (:name "Today" :scheduled today :time-grid t :deadline today :order 2)
                        (:name "Important" :priority "A" :order 3)
                        (:habit t)
                        (:name "Emacs" :tag "emacs"  :order 6)
                        (:name "Dotfiles" :tag "dotfiles" :order 7)
                        (:name "Home Lab" :tag "homelab" :order 8)
                        (:name "Curriculum" :tag "curriculum" :order 9)
                        (:name "Blog Posts" :tag "blog" :order 9)
                        (:name "Projects" :auto-property "PROJECT" :order 10)
                        (:name "Work" :tag "work" :order 11)))))
            (todo ""
                  ((org-agenda-overriding-header "Dashboard")
                   (org-super-agenda-groups
                    '((:name "Emacs" :tag "emacs"  :order 1)
                      (:name "Dotfiles" :tag "dotfiles" :order 2)
                      (:name "Home Lab" :tag "homelab" :order 3)
                      (:name "Curriculum" :tag "curriculum" :order 4)
                      (:name "Blog Posts" :tag "blog" :order 5)
                      (:name "Reading list" :tag "reading" :order 8)
                      (:name "Project ideas" :tag "project" :order 9)
                      (:name "Projects" :auto-property "PROJECT" :order 10)))))))

          ("w" "Work Focus"
           ((tags-todo "work"
                       ((org-agenda-overriding-header "Work Tasks")
                        (org-super-agenda-groups
                         '((:name "Overdue" :deadline past :face error :order 1)
                           (:name "Today" :time-grid t :scheduled today :deadline today :order 2)
                           (:name "Due Today" :deadline today :order 3)
                           (:name "Due Soon" :deadline future :order 4)
                           (:name "Important" :priority "A" :order 5)
                           (:name "Other Projects & Tasks" :order 99)))))))

          ("p" "Project Dashboard"
           ((tags "project+level=1"
                  ((org-agenda-overriding-header "Projects Overview")
                   (org-super-agenda-groups
                    '((:name "In Progress" :todo "STRT" :order 1)
                      (:name "Planning" :todo "TODO" :order 2)
                      (:name "On Hold" :todo "WAIT" :order 3)
                      (:name "Finished" :todo "DONE" :order 4)
                      (:name "Inbox / Uncategorized" :order 99)))))))

          ("h" "High Speed Habits"
           ((agenda ""
                    ((org-agenda-span 'day)
                     (org-agenda-start-day nil)
                     (org-agenda-files (list (expand-file-name "habits.org" rata-org-roam-dir)))
                     (org-agenda-start-with-log-mode t)
                     (org-agenda-log-mode-items '(closed state))
                     (org-habit-graph-column 50)
                     (org-agenda-overriding-header " ")
                     (org-super-agenda-groups
                      '((:name "Critical / Overdue" :scheduled past :order 1)
                        (:name "Morning Routine" :time-grid t :order 2)
                        (:name "Daily Goals" :scheduled today :order 3)
                        (:name "Completed Today" :log t :order 4)))))))

          ("r" "Weekly Review"
           ((tags-todo "+TIMESTAMP_IA<\"<-2w>\""
                       ((org-agenda-overriding-header "Stale TODOs (>2 weeks old)")
                        (org-super-agenda-groups
                         '((:auto-tags t)))))
            (tags "+TIMESTAMP_IA>=\"<-7d>\""
                  ((org-agenda-overriding-header "Notes Modified This Week")
                   (org-super-agenda-groups
                    '((:auto-tags t))))))))))

;; --- Org Kanban ---
(use-package org-kanban
  :after org)

;; --- Org Modern (visual enhancements) ---
(use-package org-modern
  :after org
  :config
  (global-org-modern-mode)
  (setq org-modern-agenda t))

;; --- Org Appear (reveal markup at point) ---
(use-package org-appear
  :after org
  :hook (org-mode . org-appear-mode)
  :custom
  (org-appear-autolinks t)
  (org-appear-autosubmarkers t))

;; --- Consult Org Roam ---

(defun rata-roam-search-work ()
  "Search org-roam notes filtered to :work: tag."
  (interactive)
  (consult-org-roam-search nil "work"))

(defun rata-roam-search-personal ()
  "Search org-roam notes excluding :work: tag."
  (interactive)
  (consult-org-roam-search))

(use-package consult-org-roam
  :after (org-roam consult general)
  :commands (consult-org-roam-search consult-org-roam-backlinks
             consult-org-roam-file-find)
  :config
  (consult-org-roam-mode 1)
  (rata-leader
   :states '(normal visual)
   "ors" '(consult-org-roam-search      :which-key "search roam")
   "orb" '(consult-org-roam-backlinks   :which-key "backlinks consult")
   "orF" '(consult-org-roam-file-find   :which-key "find file consult")
   "orw" '(rata-roam-search-work        :which-key "search work notes")
   "orP" '(rata-roam-search-personal    :which-key "search personal notes")))

;; --- simple-httpd (explicit recipe to disambiguate from eschulte/emacs-web-server) ---
(use-package simple-httpd
  :ensure (simple-httpd :host github :repo "skeeto/emacs-web-server"
                        :local-repo "emacs-web-server.github.skeeto"
                        :main "simple-httpd.el")
  :defer t)
;; (use-package simple-httpd
;;   :ensure (simple-httpd :host github :repo "skeeto/emacs-httpd"
;;                         :local-repo "emacs-httpd.github.skeeto"
;;                         :main "simple-httpd.el")
;; :defer t)

;; --- Org Roam UI (graph visualization) ---
(use-package org-roam-ui
  :after (org-roam general)
  :config
  (rata-leader
   :states '(normal visual)
   "oru" '(org-roam-ui-mode :which-key "roam graph UI")))

;; --- Org Download (paste/drag images) ---
(use-package org-download
  :after org
  :hook (org-mode . org-download-enable)
  :config
  (setq org-download-image-dir "./images"
        org-download-heading-lvl nil
        org-download-method 'directory))

;; --- Org Transclusion (live embedding of content) ---
(dolist (cmd '(org-transclusion-add org-transclusion-add-all
               org-transclusion-remove org-transclusion-remove-all
               org-transclusion-live-sync-start org-transclusion-mode))
  (autoload cmd "org-transclusion" nil t))

(use-package org-transclusion
  :after (org general)
  :config
  (rata-leader
   :states '(normal visual)
   "ort"  '(:ignore t :which-key "transclusion")
   "orta" '(org-transclusion-add            :which-key "add transclusion")
   "ortA" '(org-transclusion-add-all        :which-key "add all transclusions")
   "ortr" '(org-transclusion-remove         :which-key "remove transclusion")
   "ortR" '(org-transclusion-remove-all     :which-key "remove all")
   "orte" '(org-transclusion-live-sync-start :which-key "edit source")
   "ortm" '(org-transclusion-mode           :which-key "toggle mode")))

;; --- ox-hugo (org to Hugo markdown export) ---

(defun rata-hugo-preview ()
  "Start Hugo server for previewing blog posts."
  (interactive)
  (let ((default-directory rata-hugo-dir))
    (if (get-buffer "*hugo-server*")
        (browse-url "http://localhost:1313")
      (start-process "hugo-server" "*hugo-server*" "hugo" "server" "-D")
      (run-at-time 2 nil (lambda () (browse-url "http://localhost:1313"))))))

(use-package ox-hugo
  :after (ox general)
  :commands (org-hugo-export-wim-to-md)
  :config
  (rata-leader
   :states '(normal visual)
   "ob"  '(:ignore t :which-key "blog/hugo")
   "obe" '(org-hugo-export-wim-to-md :which-key "export to hugo")
   "obp" '(rata-hugo-preview         :which-key "preview post")))

;; --- Writegood Mode ---
(use-package writegood-mode
  :hook ((org-mode      . writegood-mode)
         (markdown-mode . writegood-mode))
  :config
  (rata-leader
   :states '(normal visual)
   "tw"  '(writegood-mode :which-key "writegood")))

(provide 'init-org)
