;;; -*- lexical-binding: t; -*-
;;; rata-beads.el --- Read-only Beads dashboard using Magit sections

;;; Commentary:
;; Inspect the current project's tasks through bd's JSON interface.  The CLI
;; owns database discovery (including .beads/redirect); never read its store.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'magit-section)

(declare-function evil-define-key* "evil-core")

(defgroup rata-beads nil
  "Inspect Beads tasks."
  :group 'tools :prefix "rata-beads-")

(defcustom rata-beads-executable "bd"
  "Beads executable, resolved when opening or refreshing the dashboard."
  :type 'string :group 'rata-beads)

(defcustom rata-beads-timeout 30
  "Seconds before a Beads query is stopped."
  :type 'natnum :group 'rata-beads)

(defvar-local rata-beads--view "open")
(defvar-local rata-beads--id nil)
(defvar-local rata-beads--process nil)
(defvar-local rata-beads--generation 0)

(defclass rata-beads-root (magit-section) ())
(defclass rata-beads-status (magit-section) ())
(defclass rata-beads-issue (magit-section) ())
(defclass rata-beads-relations (magit-section) ())

(defun rata-beads--arguments ()
  "Return query arguments for the current buffer."
  (append '("--readonly" "--json")
          (if rata-beads--id
              (list "show" (concat "--id=" rata-beads--id))
            (append '("list" "--limit" "0")
                    (pcase rata-beads--view
                      ("ready" '("--ready"))
                      ("closed" '("--status" "closed"))
                      ("all" '("--all"))
                      (_ nil))))))

(defun rata-beads--parse (text)
  "Parse and validate a Beads JSON array from TEXT."
  (let ((rows (json-parse-string text :object-type 'alist :array-type 'list
                                 :null-object nil :false-object nil)))
    ;; Check the source shape too: JSON null is not an empty task list.
    (unless (and (string-prefix-p "[" (string-trim-left text))
                 (listp rows)
                 (cl-every (lambda (row)
                             (and (listp row)
                                  (stringp (alist-get 'id row))
                                  (stringp (alist-get 'title row))))
                           rows))
      (error "Expected a Beads issue array"))
    rows))

(defun rata-beads--line (value)
  "Make VALUE safe for a single heading line."
  (replace-regexp-in-string "[\n\r\t]+" " " (format "%s" (or value ""))))

(defun rata-beads--insert-issue (issue)
  "Insert ISSUE as a section, with its description folded initially."
  (magit-insert-section (rata-beads-issue (alist-get 'id issue) t)
    (magit-insert-heading
      (format "  %-18s P%s %-9s %s%s"
              (rata-beads--line (alist-get 'id issue))
              (or (alist-get 'priority issue) "?")
              (rata-beads--line (alist-get 'issue_type issue))
              (rata-beads--line (alist-get 'title issue))
              (if-let* ((owner (alist-get 'assignee issue)))
                  (format "  @%s" (rata-beads--line owner)) "")))
    (dolist (field '(description design acceptance_criteria notes))
      (when-let* ((text (alist-get field issue))
                  ((not (equal text ""))))
        (insert (format "\n%s:\n%s\n" field text))))
    (when-let* ((labels (alist-get 'labels issue)))
      (insert (format "\nLabels: %s\n" (string-join labels ", "))))
    (insert "\n")))

(defun rata-beads--render (issues)
  "Render ISSUES in the current dashboard or detail buffer."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (magit-insert-section (rata-beads-root)
      (magit-insert-heading
        (format "Beads: %s" (or rata-beads--id rata-beads--view)))
      (insert default-directory "\n\n"
              "RET details   TAB fold   g r refresh   f view   y copy ID   q quit\n\n")
      (if rata-beads--id
          (dolist (issue issues)
            (rata-beads--insert-issue issue)
            (magit-section-show (car (last (oref magit-root-section children))))
            (insert (format "Status: %s   Created: %s   Updated: %s\n\n"
                            (alist-get 'status issue)
                            (or (alist-get 'created_at issue) "")
                            (or (alist-get 'updated_at issue) "")))
            (dolist (field '(dependencies dependents))
              (magit-insert-section (rata-beads-relations field)
                (magit-insert-heading (capitalize (symbol-name field)))
                (dolist (relation (alist-get field issue))
                  (rata-beads--insert-issue relation))
                (insert "\n"))))
        (let ((statuses (delete-dups
                         (append '("in_progress" "open" "blocked" "deferred" "closed")
                                 (mapcar (lambda (i) (alist-get 'status i)) issues)))))
          (dolist (status statuses)
            (let ((group (cl-remove-if-not
                          (lambda (i) (equal status (alist-get 'status i))) issues)))
              (when group
                (magit-insert-section (rata-beads-status status)
                  (magit-insert-heading
                    (format "%s (%d)" (or status "Unknown") (length group)))
                  (dolist (issue (cl-stable-sort
                                 (copy-sequence group) #'<
                                 :key (lambda (i) (or (alist-get 'priority i) 5))))
                    (rata-beads--insert-issue issue))))))))
      (unless issues (insert "No tasks in this view.\n")))
    (goto-char (min position (point-max)))))

(defun rata-beads--cancel ()
  "Invalidate pending callbacks and stop this buffer's query."
  (cl-incf rata-beads--generation)
  (when (process-live-p rata-beads--process)
    (delete-process rata-beads--process))
  (setq rata-beads--process nil))

(defun rata-beads-refresh ()
  "Refresh tasks asynchronously, preserving the previous display on failure."
  (interactive)
  (when (file-remote-p default-directory)
    (user-error "Beads dashboard currently supports local projects only"))
  (unless (executable-find rata-beads-executable)
    (user-error "Beads CLI `%s' is missing; install bd or set rata-beads-executable"
                rata-beads-executable))
  (rata-beads--cancel)
  (let ((target (current-buffer))
        (generation rata-beads--generation)
        (output (generate-new-buffer " *beads-output*"))
        (stderr (generate-new-buffer " *beads-stderr*"))
        timer)
    (setq mode-line-process ": loading")
    (condition-case err
        (progn
          (setq rata-beads--process
                (make-process
                 :name "beads" :buffer output :stderr stderr :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix
                 :command (cons rata-beads-executable (rata-beads--arguments))
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (when timer (cancel-timer timer))
                     (unwind-protect
                         (when (buffer-live-p target)
                           (with-current-buffer target
                             (when (= generation rata-beads--generation)
                               (setq rata-beads--process nil)
                               (condition-case failure
                                   (progn
                                     (unless (and (eq (process-status process) 'exit)
                                                  (= (process-exit-status process) 0))
                                       (error "%s" (if (process-get process 'timed-out)
                                                       "Query timed out"
                                                     (with-current-buffer stderr
                                                       (string-trim (buffer-string))))))
                                     (rata-beads--render
                                      (rata-beads--parse
                                       (with-current-buffer output (buffer-string))))
                                     (setq mode-line-process nil))
                                 (error
                                  (setq mode-line-process ": failed (see *Messages*)")
                                  (message "Beads: %s" (error-message-string failure)))))))
                       (kill-buffer output)
                       (kill-buffer stderr))))))
          (setq timer
                (run-at-time
                 rata-beads-timeout nil
                 (lambda (process)
                   (when (process-live-p process)
                     (process-put process 'timed-out t)
                     (delete-process process)))
                 rata-beads--process)))
      (error
       (kill-buffer output)
       (kill-buffer stderr)
       (setq mode-line-process ": failed")
       (user-error "Beads: %s" (error-message-string err))))))

(defun rata-beads-filter (view)
  "Switch to VIEW and refresh."
  (interactive (list (completing-read "Beads view: "
                                     '("open" "ready" "closed" "all") nil t)))
  (when rata-beads--id (user-error "Switch views in the task dashboard"))
  (setq rata-beads--view view)
  (rata-beads-refresh))

(defun rata-beads--current-id ()
  "Return the issue ID at point, or signal a user error."
  (or (magit-section-value-if 'rata-beads-issue) rata-beads--id
      (user-error "No Beads task at point")))

(defun rata-beads-copy-id ()
  "Copy the current task's ID."
  (interactive)
  (kill-new (rata-beads--current-id))
  (message "Copied %s" (current-kill 0)))

(defun rata-beads-show ()
  "Show full details of the task at point in a separate buffer."
  (interactive)
  (let ((directory default-directory)
        (id (rata-beads--current-id)))
    (pop-to-buffer (get-buffer-create (format "*Beads %s: %s*" directory id)))
    (unless (derived-mode-p 'rata-beads-mode) (rata-beads-mode))
    (setq default-directory directory rata-beads--id id)
    (rata-beads-refresh)))

(defvar rata-beads-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "RET") #'rata-beads-show)
    (define-key map (kbd "g") #'rata-beads-refresh)
    (define-key map (kbd "f") #'rata-beads-filter)
    (define-key map (kbd "y") #'rata-beads-copy-id)
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode rata-beads-mode magit-section-mode "Beads"
  "Inspect Beads tasks with collapsible Magit sections."
  (setq-local revert-buffer-function (lambda (&rest _) (rata-beads-refresh)))
  (add-hook 'kill-buffer-hook #'rata-beads--cancel nil t)
  (add-hook 'change-major-mode-hook #'rata-beads--cancel nil t))

(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-beads-mode-map
    (kbd "RET") #'rata-beads-show
    (kbd "TAB") #'magit-section-toggle
    (kbd "gr") #'rata-beads-refresh
    (kbd "f") #'rata-beads-filter
    (kbd "y") #'rata-beads-copy-id
    (kbd "q") #'quit-window))

;;;###autoload
(defun rata-beads (&optional directory)
  "Inspect Beads tasks in DIRECTORY or the nearest enclosing .beads project.
With a prefix argument, prompt for DIRECTORY.  All queries are read-only."
  (interactive (list (when current-prefix-arg
                       (read-directory-name "Beads project: "))))
  (when (file-remote-p (or directory default-directory))
    (user-error "Beads dashboard supports local projects only"))
  (let* ((start (or directory default-directory))
         (root (or directory (locate-dominating-file start ".beads"))))
    (unless root (user-error "No .beads project here; use C-u SPC g t to select one"))
    (setq root (file-name-as-directory (expand-file-name root)))
    (when (file-remote-p root) (user-error "Beads dashboard supports local projects only"))
    (pop-to-buffer (get-buffer-create (format "*Beads: %s*" root)))
    (unless (derived-mode-p 'rata-beads-mode) (rata-beads-mode))
    (setq default-directory root)
    (rata-beads-refresh)))

(provide 'rata-beads)
;;; rata-beads.el ends here
