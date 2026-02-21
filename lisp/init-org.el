;;; -*- lexical-binding: t; -*-
;;; init-org.el --- Org mode configuration

(use-package org
  :defer t
  :after general
  :config
  (rata-leader
   :states '(normal visual insert emacs)
   "o"  '(:ignore t :which-key "org")
   "oc" '(org-capture :which-key "org capture")
   "oa" '(org-agenda :which-key "org agenda")
   "ot" '(org-todo-list :which-key "list all TODOs"))

  ;;;; Org Agenda
  (setq org-agenda-inhibit-startup t)
  (setq org-agenda-dim-blocked-tasks nil)
  (setq org-agenda-skip-unavailable-files t)

  ;; Agenda window layout
  (setq org-agenda-window-setup 'reorganize-frame)
  (setq org-agenda-restore-windows-after-quit t)
  (setq org-agenda-window-frame-fractions '(0.8 . 0.9))

  (defadvice org-agenda (around split-vertically activate)
    (let ((split-width-threshold 40)
          (split-height-threshold nil))
      ad-do-it))

  (setq org-agenda-prefix-format
        '((agenda . " %i %?-12t% s")
          (todo   . " %i %?-12t% s")
          (tags   . " %i %?-12t% s")
          (search . " %i %?-12t% s")))

  (setq org-agenda-files '("~/workspace/second-brain/org-roam/todo.org"
                           "~/workspace/second-brain/org-roam/work_tasks.org"
                           "~/workspace/second-brain/org-roam/homelab_tasks.org"
                           "~/workspace/second-brain/org-roam/emacs_tweak_tasks.org"
                           "~/workspace/second-brain/org-roam/dotfiles_tweak_tasks.org"
                           "~/workspace/second-brain/org-roam/curriculum_tasks.org"
                           "~/workspace/second-brain/org-roam/projects/"
                           "~/workspace/second-brain/org-roam/habits.org"))
  (org-super-agenda-mode)

  ;; Org habits
  (add-to-list 'org-modules 'org-habit)
  (require 'org-habit)
  (setq org-habit-graph-column 60)
  (setq org-habit-show-habits-only-for-today nil)
  (setq org-agenda-skip-scheduled-if-done nil)

  ;; Org directory
  (setq org-directory "~/workspace/second-brain/org-roam/")

  ;; Dependency tracking
  (setq org-enforce-todo-dependencies t)
  (setq org-enforce-todo-checkbox-dependencies t)

  ;; Capture templates
  (setq org-capture-templates
        '(("t" "TODO" entry (file "~/workspace/second-brain/org-roam/todo.org")
           "** TODO %?\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("w" "Work Task" entry (file "~/workspace/second-brain/org-roam/work_tasks.org")
           "** TODO %? :work:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("h" "Home Lab Task" entry (file+headline "~/workspace/second-brain/org-roam/homelab_tasks.org" "Tasks")
           "** TODO %? :homelab:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("e" "Emacs Tweak" entry (file "~/workspace/second-brain/org-roam/emacs_tweak_tasks.org")
           "** TODO %? :emacs:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("d" "Dotfiles Tweak" entry (file "~/workspace/second-brain/org-roam/dotfiles_tweak_tasks.org")
           "** TODO %? :dotfiles:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("c" "Curriculum Task" entry (file "~/workspace/second-brain/org-roam/curriculum_tasks.org")
           "** TODO %? :curriculum:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ("l" "Link/Read Later" entry
           (file+headline "~/workspace/second-brain/org-roam/reading-list.org" "Reading List")
           "* TODO %a :reading:\nCaptured on: %U\n"
           :empty-lines 1
           :immediate-finish t))))

;; --- Org Roam ---
(use-package org-roam
  :after (org general)
  :custom
  (org-roam-directory (file-truename "~/workspace/second-brain/org-roam/"))
  (org-roam-completion-everywhere t)
  (org-roam-mode-sections
   (list #'org-roam-backlinks-section
         #'org-roam-reflinks-section
         #'org-roam-unlinked-references-section))
  (org-roam-capture-templates '(("d" "default" plain
                                 "%?"
                                 :if-new (file+head "%<%Y%m%d%H%M%S>-${slug}.org" "#+title: ${title}\n#+author: Jens Lordén\n#+date: %U\n\n* ${title}")
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

                                 :if-new (file+head "projects/%<%Y%m%d%H%M%S>-${slug}.org"
                                                    "#+title: ${title}
#+author: Jens Lordén
#+date: %U
#+filetags: :project:${slug}:
#+SEQ_TODO: TODO STRT WAIT | DONE
#+startup: content
\n
")
                                 :unnarrowed t)


                                ("b" "blog-post" plain
                                 "\n
One of my [[id:b0b348f1-7824-4a8c-af56-46ad9372071f][blog post]]s.

* ${title}
:properties:
:export_hugo_section: /posts/
:export_file_name:
:end:"

                                 :if-new (file+head "blog-posts/%<%Y%m%d%H%M%S>-${slug}.org"
                                                    "#+title: ${title}
#+author: Jens Lordén
#+date: %U
#+hugo_base_dir: ../hugo/
\n
")
                                 :unnarrowed t)))

  :config
  (rata-leader
   :states '(normal visual insert emacs)
   "or"  '(:ignore t :which-key "Org roam")
   "orl" '(org-roam-buffer-toggle :which-key "toggle buffer")
   "orf" '(org-roam-node-find :which-key "find node")
   "org" '(org-roam-graph :which-key "show graph")
   "ori" '(org-roam-node-insert :which-key "insert node")
   "orc" '(org-roam-capture :which-key "capture node")
   "ord"  '(:ignore t :which-key "Org roam dailies")
   "ordc" '(org-roam-dailies-capture-today :which-key "journal today"))

  ;; Dailies
  (setq org-roam-dailies-directory "~/workspace/second-brain/org-roam/daily")
  (setq org-roam-dailies-capture-templates
        `(("d" "default" entry
           "** %<%H:%M> %?"
           :target (file+head+olp "%<%Y-%m-%d>.org"
                                  "#+title: %<%A %B %d, %Y>
#+filetags: :daily:
#+author: Jens

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

  (org-roam-db-autosync-mode))

;; --- Org Roam QL ---
(use-package org-roam-ql
  :after org-roam)

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
                     (org-agenda-files '("~/workspace/second-brain/org-roam/habits.org"))
                     (org-agenda-start-with-log-mode t)
                     (org-agenda-log-mode-items '(closed state))
                     (org-habit-graph-column 50)
                     (org-agenda-overriding-header " ")
                     (org-super-agenda-groups
                      '((:name "Critical / Overdue" :scheduled past :order 1)
                        (:name "Morning Routine" :time-grid t :order 2)
                        (:name "Daily Goals" :scheduled today :order 3)
                        (:name "Completed Today" :log t :order 4))))))))))

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
(use-package consult-org-roam
  :after (org-roam consult general)
  :config
  (consult-org-roam-mode 1)
  (rata-leader
    :states '(normal visual insert emacs)
    "ors" '(consult-org-roam-search      :which-key "search roam")
    "orb" '(consult-org-roam-backlinks   :which-key "backlinks consult")
    "orF" '(consult-org-roam-file-find   :which-key "find file consult")))

;; --- Org Roam UI (graph visualization) ---
(use-package org-roam-ui
  :after (org-roam general)
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "oru" '(org-roam-ui-mode :which-key "roam graph UI")))

;; --- Writegood Mode ---
(use-package writegood-mode
  :hook ((org-mode      . writegood-mode)
         (markdown-mode . writegood-mode))
  :config
  (rata-leader
    :states '(normal visual insert emacs)
    "tw"  '(writegood-mode :which-key "writegood")))

(provide 'init-org)
