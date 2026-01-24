;; ~/.config/emacs-from-scratch/lisp/init-org.el

;; Add keybindings to rata-leader (SPC)
;; (rata-leader
;;  :states 'normal
;;  "t"  '(:ignore t :which-key "tools")
;;  "tc" '(calc :which-key "calculator")
;;  "td" '(dired :which-key "dired"))

(use-package org
  :defer t
  :init
  (rata-leader
   :states '(normal visual insert emacs)
   "o"  '(:ignore t :which-key "org")
   "oc" '(org-capture :which-key "org capture"))
  :config
  ;;;; Org Agenda
  ;; Inhibit time-consuming startup processes for background agenda files.
  (setq org-agenda-inhibit-startup t)
  ;; Disable dimming of blocked tasks, which can be slow.
  (setq org-agenda-dim-blocked-tasks nil)
  ;; Skip deleted files
  (setq org-agenda-skip-unavailable-files t)

  ;; Make buffer horizontal
  (setq org-agenda-window-setup 'reorganize-frame) ;; 'reorganize-frame 'other-window 'current-window
  (setq org-agenda-restore-windows-after-quit t)
  (setq org-agenda-window-frame-fractions '(0.8 . 0.9))

  (defadvice org-agenda (around split-vertically activate)
    (let (
          (split-width-threshold 40)    ; or whatever width makes sense for you
          (split-height-threshold nil)) ; but never horizontally
      ad-do-it))

  ;; Default was: " %i %-12:c%?-12t% s" (The %c is the filename)
  (setq org-agenda-prefix-format
        '((agenda . " %i %?-12t% s")
          (todo   . " %i %?-12t% s")
          (tags   . " %i %?-12t% s")
          (search . " %i %?-12t% s")))

  ;; (setq org-agenda-files (directory-files-recursively org-directory "\\\\.org$"))
  ;; (setq org-agenda-files (directory-files-recursively "~/workspace/second-brain/" "\.org$"))
  (setq org-agenda-files '("~/workspace/second-brain/org-roam/todo.org"
                           "~/workspace/second-brain/org-roam/work_tasks.org"
                           "~/workspace/second-brain/org-roam/homelab_tasks.org"
                           "~/workspace/second-brain/org-roam/emacs_tweak_tasks.org"
                           "~/workspace/second-brain/org-roam/dotfiles_tweak_tasks.org"
                           "~/workspace/second-brain/org-roam/curriculum_tasks.org"
                           "~/workspace/second-brain/org-roam/projects/"
                           "~/workspace/second-brain/org-roam/habits.org"))
  (org-super-agenda-mode)

  ;; --- Org habits ---
  (add-to-list 'org-modules 'org-habit)
  (require 'org-habit)
  (setq org-habit-graph-column 60)
  (setq org-habit-show-habits-only-for-today nil)
  ;; Allow completed habits to stay visible in the agenda log for satisfaction
  (setq org-habit-show-habits-only-for-today nil)
  (setq org-agenda-skip-scheduled-if-done nil)

  ;; Use a dedicated directory for all org files
  (setq org-directory "~/workspace/second-brain/org-roam/")

  ;; Enable advanced dependency tracking
  (setq org-enforce-todo-dependencies t)
  (setq org-enforce-todo-checkbox-dependencies t)

  ;; Org capture templates
  (setq org-capture-templates
        '(
          ("t" "TODO" entry (file "~/workspace/second-brain/org-roam/todo.org")
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
           :immediate-finish t)

          ;; ("i" "Inbox" entry (file "~/workspace/second-brain/org-roam/inbox.org")
          ;;  "** TODO %? :inbox:\n  :PROPERTIES:\n  :CREATED: %U\n  :END:")

          ;; ("p" "Project Task" entry (file "~/workspace/second-brain/org-roam/projects.org")
          ;;  "* TODO %? :project:\\n  :PROPERTIES:\\n  :PROJECT: %(completing-read \\"Project: \\" (org-get-outline-path t))\\n  :CREATED: %U\\n  :END:")
          ))
  )

;; (use-package org-roam
;;   :ensure t
;;   :custom
;;   (org-roam-directory (file-truename "/path/to/org-files/"))
;;   :bind (("C-c n l" . org-roam-buffer-toggle)
;;          ("C-c n f" . org-roam-node-find)
;;          ("C-c n g" . org-roam-graph)
;;          ("C-c n i" . org-roam-node-insert)
;;          ("C-c n c" . org-roam-capture)
;;          ;; Dailies
;;          ("C-c n j" . org-roam-dailies-capture-today))
;;   :config
;;   ;; If you're using a vertical completion framework, you might want a more informative completion interface
;;   (setq org-roam-node-display-template (concat "${title:*} " (propertize "${tags:10}" 'face 'org-tag)))
;;   (org-roam-db-autosync-mode)
;;   ;; If using org-roam-protocol
;;   (require 'org-roam-protocol))


;; ============================================================================
;; Org-roam Configuration
;; ============================================================================

;; (global-set-key (kbd "C-c n f") 'org-roam-node-find)
;; (global-set-key (kbd "C-c n i") 'org-roam-node-insert)
;; (global-set-key (kbd "C-c n l") 'org-roam-buffer-toggle)
;; (global-set-key (kbd "C-c n p") 'org-roam-alias-add)
;; (global-set-key (kbd "C-c n a") 'org-id)
;; (global-set-key (kbd "C-c n I") 'org-id-get-create)
(use-package org-roam
  :after org
  :init
  (rata-leader
   :states '(normal visual insert emacs)
   "or"  '(:ignore t :which-key "Org roam")
   "orl" '(org-roam-buffer-toggle :which-key "toggle buffer")
   "orf" '(org-roam-node-find :which-key "find node")
   "org" '(org-roam-graph :which-key "show graph")
   "ori" '(org-roam-node-insert :which-key "insert node")
   "orc" '(org-roam-capture :which-key "capture node")
   "orj" '(org-roam-dailies-capture-today :which-key "journal today"))
  :custom
  ;; Set the directory for roam notes, can be the same as org-directory
  (org-roam-directory (file-truename org-directory))
  (org-roam-completion-everywhere t)

  ;; Configure the display of the backlinks buffer
  (org-roam-mode-sections
   (list #'org-roam-backlinks-section
         #'org-roam-reflinks-section
         #'org-roam-unlinked-references-section))

  ;; Configure org-roam-capture-template
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
                                 :unnarrowed t)
                                ))

  :config
  ;; Configure org-roam-dailies
  (setq org-roam-dailies-directory "~/workspace/second-brain/org-roam/daily")

  (setq org-roam-dailies-capture-templates
        `(("d" "default" entry
           "** %<%H:%M> %?"
           ;; :target (file+head ,(expand-file-name "%<%Y-%m-%d>.org" org-roam-dailies-directory)
           :target (file+head+olp "%<%Y-%m-%d>.org"
                                  "#+title: %<%A %B %d, %Y>
#+filetags: :daily:
#+author: Jens

* Daily notes for %<%A %B %d, %Y>

* Morning Protocol
- [ ] 📅 Review Agenda (Work & Projects)
- [ ] 📧 Check email
- [ ] 🎯 Top 3 Priorities for Today
  1. [ ]
  2. [ ]
  3. [ ]
- 💤 Hours slept:

* Habits
- [ ] 💾 Commit Dotfiles/Emacs Tweaks
- [ ] 📥 Clear Inbox
- [ ] 🏋️ Workout
- [ ] 🇨🇳 Chinese Study
- [ ] 📚 Reading
- [ ] 💊 Supplements
  - [ ] ⚡ Creatine
  - [ ] 🥤 Protein
  - [ ] 🍊 Vitamins

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
                                  ;; -------------------------------------------------
                                  ;; Target: Place entries under "* Log"
                                  ;; -------------------------------------------------
                                  ("Log"))
           :empty-lines-before 1
           :empty-lines-after 1)))

  )

;; (spacemacs/set-leader-keys "aordc" 'org-roam-dailies-capture-today)



(use-package org-roam-ql
  :after org-roam)


;; ============================================================================
;; Advanced Org Agenda
;; ============================================================================
(use-package org-super-agenda
  :after org
  :config
  ;; org-agenda-dashboards
  (setq org-agenda-custom-commands
        '(("d" "🎯 Dashboard"
           ((agenda ""
                    ((org-agenda-overriding-header "✅ Agenda")
                     (org-super-agenda-groups
                      ;; This uses the main "Action Dashboard" configuration defined earlier
                      '((:name "🔥 Overdue" :deadline past :face 'error :order 1)
                        (:name "🎯 Today" :scheduled today :time-grid t :deadline today :order 2)
                        (:name "❗ Important" :priority "A" :order 3)
                        (:habit t)
                        (:name "🔧 Emacs" :tag "emacs"  :order 6)
                        (:name "🔧 Dotfiles" :tag "dotfiles" :order 7)
                        (:name "🔬 Home Lab" :tag "homelab" :order 8)
                        (:name "🔬 Curriculum" :tag "curriculum" :order 9)
                        (:name "✍️ Blog Posts" :tag "blog" :order 9)
                        (:name "🚀 Projects" :auto-property "PROJECT" :order 10)
                        (:name "🏢 Work" :tag "work" :order 11)
                        ))))
            (todo ""
                  ((org-agenda-overriding-header "✅ Dashboard")
                   (org-super-agenda-groups
                    '(
                      (:name "🔧 Emacs" :tag "emacs"  :order 1)
                      (:name "🔧️ Dotfiles" :tag "dotfiles" :order 2)
                      (:name "🔬 Home Lab" :tag "homelab" :order 3)
                      (:name "🔬 Curriculum" :tag "curriculum" :order 4)
                      (:name "🔬 Blog Posts" :tag "blog" :order 5)
                      (:name "📥 Reading list" :tag "reading" :order 8)
                      (:name "🚀 Project ideas" :tag "project" :order 9)
                      (:name "🚀 Projects" :auto-property "PROJECT" :order 10)
                      ))))))

          ("w" "🏢 Work Focus"
           ((tags-todo "work"
                       ((org-agenda-overriding-header "✅ Work Tasks")
                        (org-super-agenda-groups
                         '(
                           (:name " ⚠️ Overdue" :deadline past :face error :order 1)
                           (:name "🎯 Today" :time-grid t :scheduled today :deadline today :order 2)
                           (:name "Due Today" :deadline today :order 3)
                           (:name "Due Soon" :deadline future :order 4)
                           (:name " ⚡ Important" :priority "A" :order 5)
                           ;; Catch-all for any other work tasks
                           (:name "🚀 Other Projects & Tasks" :order 99)
                           ))))))

          ("p" "🚀 Project Dashboard"
           ((tags "project+level=1"
                  ((org-agenda-overriding-header "🚀 Projects Overview")
                   (org-super-agenda-groups
                    '(
                      (:name "🚀 In Progress"
                             :todo "STRT"
                             :order 1)

                      (:name "✨ Planning"
                             :todo "TODO"
                             :order 2)

                      (:name "⏸ On Hold"
                             :todo "WAIT"
                             :order 3)

                      (:name "✅ Finished"
                             :todo "DONE"
                             :order 4)

                      (:name "📂 Inbox / Uncategorized"
                             :order 99)
                      ))))))

          ("h" "⚡ High Speed Habits"
           ((agenda ""
                    ((org-agenda-span 'day)      ;; Show only today
                     (org-agenda-start-day nil)  ;; Start from today

                     ;; Force this view to ONLY look at your habits file
                     (org-agenda-files '("~/workspace/second-brain/org-roam/habits.org"))

                     (org-agenda-start-with-log-mode t)
                     (org-agenda-log-mode-items '(closed state))

                     ;; Visual Tweaks
                     (org-habit-graph-column 50) ;; Move graph to the right to align nicely
                     (org-agenda-overriding-header " ") ;; Remove default date header for cleanliness

                     ;; Grouping
                     (org-super-agenda-groups
                      '((:name "🚨 Critical / Overdue"
                               :scheduled past
                               :order 1)
                        (:name "📅 Morning Routine"
                               :time-grid t   ;; Keep time-specific habits here
                               :order 2)
                        (:name "✨ Daily Goals"
                               :scheduled today
                               :order 3)
                        (:name "✅ Completed Today"
                               :log t
                               :order 4)
                        ))))))
          ))
  )


;; --- Org-transclusion ---
;; (use-package org-transclusion
;;   :ensure t
;;   :after org
;;   ;; :bind (("C-c n t" . org-transclusion-add)
;;   ;;        ("C-c n T" . org-transclusion-mode))
;;   :config
;;   ;; Visual tweaks to make transcluded blocks look distinct in Gruvbox
;;   (set-face-attribute 'org-transclusion-fringe nil :foreground "#b8bb26" :background nil)
;;   (set-face-attribute 'org-transclusion-source-inline nil :foreground "#fabd2f" :height 0.8))

;; --- Org kanban ---
(use-package org-kanban
  :ensure t
  :after org)

(provide 'init-org)
