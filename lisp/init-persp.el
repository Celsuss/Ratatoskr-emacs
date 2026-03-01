;;; -*- lexical-binding: t; -*-
;;; init-persp.el --- Workspace management with persp-mode

(use-package persp-mode
  :after general
  :demand t
  :custom
  (persp-auto-resume-time -1)
  :config
  (persp-mode 1)

  ;; Helper: switch to layout by 0-based index; create on demand if slot is empty
  (defun rata-persp-switch-to-index (idx)
    "Switch to layout at 0-based IDX. If no layout exists there, prompt and create one."
    (interactive "nLayout index: ")
    (let ((names (persp-names)))
      (if (< idx (length names))
          (persp-switch (nth idx names))
        (let ((name (read-string (format "New layout name for slot %d: " (1+ idx)))))
          (unless (string-empty-p name)
            (persp-add-new name)
            (persp-switch name))))))

  ;; Dynamic label helper for transient descriptions
  (defun rata-persp-layout-label (n)
    "Return transient description for 1-based layout slot N.
Active layout is shown as [Name]; others as Name; empty slots as -."
    (let* ((names (persp-names))
           (idx   (1- n))
           (name  (and (< idx (length names)) (nth idx names)))
           (cur   (safe-persp-name (get-current-persp))))
      (cond
       ((null name)        "-")
       ((string= name cur) (format "[%s]" name))
       (t                  name))))

  ;; Generate rata-persp-switch-1 … rata-persp-switch-9 (keys 1–9, indices 0–8)
  (dotimes (n 9)                        ; n = 0..8, key-number = n+1
    (let ((sym (intern (format "rata-persp-switch-%d" (1+ n))))
          (idx n))
      (fset sym (lambda ()
                  (interactive)
                  (rata-persp-switch-to-index idx)))
      (put sym 'function-documentation
           (format "Switch to layout at slot %d (0-based index %d)." (1+ n) n))))

  ;; Layouts transient state
  (transient-define-prefix rata-layouts-transient ()
    "Layouts Transient State — SPC l l"
    :transient-suffix 'transient--do-stay
    :transient-non-suffix 'transient--do-warn
    ["Navigate"
     :class transient-row
     ("n" "next"          persp-next)
     ("p" "prev"          persp-prev)
     ("l" "switch (name)" persp-switch)]
    ["Layouts"
     :class transient-row
     ("1" (lambda () (rata-persp-layout-label 1)) rata-persp-switch-1)
     ("2" (lambda () (rata-persp-layout-label 2)) rata-persp-switch-2)
     ("3" (lambda () (rata-persp-layout-label 3)) rata-persp-switch-3)
     ("4" (lambda () (rata-persp-layout-label 4)) rata-persp-switch-4)
     ("5" (lambda () (rata-persp-layout-label 5)) rata-persp-switch-5)
     ("6" (lambda () (rata-persp-layout-label 6)) rata-persp-switch-6)
     ("7" (lambda () (rata-persp-layout-label 7)) rata-persp-switch-7)
     ("8" (lambda () (rata-persp-layout-label 8)) rata-persp-switch-8)
     ("9" (lambda () (rata-persp-layout-label 9)) rata-persp-switch-9)]
    ["Manage"
     :class transient-row
     ("N" "new"    persp-add-new)
     ("k" "kill"   persp-kill)
     ("r" "rename" persp-rename)]
    ["Buffers"
     :class transient-row
     ("a" "add buffer"    persp-add-buffer)
     ("b" "switch buffer" persp-switch-to-buffer)]
    ["Persist"
     :class transient-row
     ("s" "save"    persp-save-state-to-file)
     ("R" "restore" persp-load-state-from-file)]
    [("q" "quit" transient-quit-one :transient nil)])

  (rata-leader
    :states '(normal visual)
    "l"   '(:ignore t :which-key "layouts")
    "ll"  '(rata-layouts-transient :which-key "layouts transient state")
    "lL"  '(persp-switch :which-key "switch layout")
    "ln"  '(persp-add-new :which-key "new layout")
    "lk"  '(persp-kill :which-key "kill layout")
    "lr"  '(persp-rename :which-key "rename layout")
    "la"  '(persp-add-buffer :which-key "add buffer")
    "lb"  '(persp-switch-to-buffer :which-key "switch to buffer")
    "ls"  '(persp-save-state-to-file :which-key "save layouts")))

(provide 'init-persp)
