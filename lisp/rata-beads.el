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

(defface rata-beads-status-open
  '((t :foreground "#83a598"))
  "Blue for open tasks." :group 'rata-beads)
(defface rata-beads-status-in-progress
  '((t :foreground "#fabd2f"))
  "Yellow for tasks in progress." :group 'rata-beads)
(defface rata-beads-status-blocked
  '((t :foreground "#fb4934"))
  "Red for blocked tasks." :group 'rata-beads)
(defface rata-beads-status-deferred
  '((t :foreground "#d3869b"))
  "Purple for deferred tasks." :group 'rata-beads)
(defface rata-beads-status-closed
  '((t :foreground "#b8bb26"))
  "Green for closed tasks." :group 'rata-beads)

(defface rata-beads-priority-0
  '((t :foreground "#fb4934" :weight bold))
  "Bold red for critical priority." :group 'rata-beads)
(defface rata-beads-priority-1
  '((t :foreground "#fe8019"))
  "Orange for high priority." :group 'rata-beads)
(defface rata-beads-priority-2
  '((t :foreground "#fabd2f"))
  "Yellow for medium priority." :group 'rata-beads)
(defface rata-beads-priority-3
  '((t :foreground "#83a598"))
  "Blue for low priority." :group 'rata-beads)
(defface rata-beads-priority-4
  '((t :foreground "#928374"))
  "Muted gray for backlog priority." :group 'rata-beads)

(defconst rata-beads--status-faces
  '(("open" . rata-beads-status-open)
    ("in_progress" . rata-beads-status-in-progress)
    ("blocked" . rata-beads-status-blocked)
    ("deferred" . rata-beads-status-deferred)
    ("closed" . rata-beads-status-closed))
  "Faces used for Beads status values.")

(defconst rata-beads--priority-faces
  '((0 . rata-beads-priority-0) (1 . rata-beads-priority-1)
    (2 . rata-beads-priority-2) (3 . rata-beads-priority-3)
    (4 . rata-beads-priority-4))
  "Faces used for Beads priority levels.")

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
(defvar-local rata-beads--detail-buffer nil
  "Task detail buffer opened by this dashboard.")

(defclass rata-beads-root (magit-section) ())
(defclass rata-beads-issue (magit-section) ())
(defclass rata-beads-relations (magit-section) ())
(defclass rata-beads-group (magit-section) ())

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

(defun rata-beads--status-text (status)
  "Format STATUS with its face, leaving unknown values uncolored."
  (let ((text (rata-beads--line status)))
    (if-let* ((face (cdr (assoc status rata-beads--status-faces))))
        ;; Font lock clears `face' on redisplay.  Like Magit's headings, keep
        ;; directly rendered colors in `font-lock-face' so they survive it.
        (propertize text 'font-lock-face face)
      text)))

(defun rata-beads--priority-text (priority)
  "Format PRIORITY with its face, leaving unknown levels uncolored."
  (let ((text (format "P%s" (or priority "?"))))
    (if-let* ((face (cdr (assq priority rata-beads--priority-faces))))
        (propertize text 'font-lock-face face)
      text)))

(defun rata-beads--row-format (issues)
  "Return a column format wide enough for the metadata in ISSUES."
  (let ((widths
         (mapcar (lambda (column)
                   (apply #'max (length (cdr column))
                          (mapcar (lambda (issue)
                                    (string-width
                                     (rata-beads--line (alist-get (car column) issue))))
                                  issues)))
                 '((id . "ID") (status . "Status") (priority . "Pri")
                   (issue_type . "Type")))))
    (concat (mapconcat (lambda (width) (format "%%-%ds" width)) widths "  ")
            "  %s")))

(defun rata-beads--insert-issue (issue row-format)
  "Insert exactly one row for ISSUE using ROW-FORMAT."
  (magit-insert-section (rata-beads-issue (alist-get 'id issue))
    (let ((start (point)))
      (insert (format row-format
                      (rata-beads--line (alist-get 'id issue))
                      (rata-beads--status-text (alist-get 'status issue))
                      (rata-beads--priority-text (alist-get 'priority issue))
                      (rata-beads--line (alist-get 'issue_type issue))
                      (rata-beads--line (alist-get 'title issue)))
              "\n")
      (add-text-properties start (point)
                           '(mouse-face highlight help-echo "Show task details")))))

(defun rata-beads--insert-details (issue)
  "Insert the full text and metadata of ISSUE."
  (magit-insert-section (rata-beads-issue (alist-get 'id issue))
    (magit-insert-heading
      (rata-beads--line (alist-get 'title issue)))
    (insert (format "ID: %s\nStatus: %s   Pri: %s   Type: %s\n"
                    (alist-get 'id issue)
                    (rata-beads--status-text (alist-get 'status issue))
                    (rata-beads--priority-text (alist-get 'priority issue))
                    (or (alist-get 'issue_type issue) "")))
    (dolist (field '(assignee created_at updated_at))
      (when-let* ((text (alist-get field issue)))
        (insert (format "%s: %s\n" field text))))
    (dolist (field '(description design acceptance_criteria notes))
      (when-let* ((text (alist-get field issue))
                  ((not (equal text ""))))
        (insert (format "\n%s:\n%s\n" field text))))
    (when-let* ((labels (alist-get 'labels issue)))
      (insert (format "\nLabels: %s\n" (string-join labels ", "))))
    (insert "\n")))

(defun rata-beads--parent (issue)
  "Return ISSUE's explicit parent ID, ignoring blocking dependencies."
  (or (alist-get 'parent issue)
      (alist-get 'depends_on_id
                 (cl-find "parent-child" (alist-get 'dependencies issue)
                          :key (lambda (dep) (alist-get 'type dep))
                          :test #'equal))))

(defun rata-beads--group-id (issue index)
  "Find ISSUE's epic in INDEX, or a parent absent from the current view.
Follow explicit parents only, never infer ancestry from an issue ID.
Malformed cycles and chains without an epic have no group."
  (let (seen result)
    (while (and issue (not result)
                (not (member (alist-get 'id issue) seen)))
      (push (alist-get 'id issue) seen)
      (if (equal (alist-get 'issue_type issue) "epic")
          (setq result (alist-get 'id issue))
        (let ((parent (rata-beads--parent issue)))
          (setq issue (gethash parent index))
          (when (and parent (not issue)) (setq result parent)))))
    result))

(defun rata-beads--insert-groups (issues row-format)
  "Insert ISSUES grouped by epic using ROW-FORMAT for task rows.
Keep priority order within each group and between epic rows.  A parent
outside the filtered view is identified by ID without adding hidden tasks."
  (let ((index (make-hash-table :test #'equal))
        (groups (make-hash-table :test #'equal))
        order)
    (dolist (issue issues)
      (puthash (alist-get 'id issue) issue index))
    (dolist (issue (cl-stable-sort
                   (copy-sequence issues) #'<
                   :key (lambda (i) (or (alist-get 'priority i) 5))))
      (let ((id (rata-beads--group-id issue index)))
        (unless (gethash id groups) (push id order))
        (push issue (gethash id groups))))
    ;; Epic groups follow their own priority, not their most urgent child's.
    (setq order
          (cl-stable-sort
           (nreverse order) #'<
           :key (lambda (id)
                  (if id (or (alist-get 'priority (gethash id index)) 5) 6))))
    (dolist (id order)
      (let* ((epic (gethash id index))
             (rows (nreverse (gethash id groups)))
             (heading (cond
                       (epic (format "Epic: %s — %s" id
                                     (rata-beads--line (alist-get 'title epic))))
                       (id (format "Parent: %s (outside this view)" id))
                       (t "Other tasks"))))
        (if (and (null id) (= (hash-table-count groups) 1))
            ;; Preserve the compact flat list for projects without epics.
            (dolist (issue rows) (rata-beads--insert-issue issue row-format))
          (insert "\n")
          (magit-insert-section (rata-beads-group id)
            (magit-insert-heading (concat "── " heading " ──"))
            ;; Keep the epic itself selectable and ahead of its children.
            (when epic (rata-beads--insert-issue epic row-format))
            (dolist (issue rows)
              (unless (eq issue epic)
                (rata-beads--insert-issue issue row-format)))))))))

(defun rata-beads--render (issues)
  "Render ISSUES in the current dashboard or detail buffer."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (magit-insert-section (rata-beads-root)
      (magit-insert-heading
        (format "Beads: %s" (or rata-beads--id rata-beads--view)))
      (insert default-directory "\n\n"
              "RET/click details   g r refresh   f view   y copy ID   q quit\n\n")
      (if rata-beads--id
          (dolist (issue issues)
            (rata-beads--insert-details issue)
            (dolist (field '(dependencies dependents))
              (magit-insert-section (rata-beads-relations field)
                (magit-insert-heading (capitalize (symbol-name field)))
                (let* ((relations (alist-get field issue))
                       (row-format (rata-beads--row-format relations)))
                  (dolist (relation relations)
                    (rata-beads--insert-issue relation row-format)))
                (insert "\n"))))
        (let ((row-format (rata-beads--row-format issues)))
          (insert (propertize (format row-format "ID" "Status" "Pri" "Type" "Title")
                              'font-lock-face 'magit-section-heading)
                  "\n")
          (rata-beads--insert-groups issues row-format)))
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
  "Show and focus the task at point in the project's right side window."
  (interactive)
  (let ((directory default-directory)
        (id (rata-beads--current-id)))
    (let ((buffer (get-buffer-create (format "*Beads details: %s*" directory))))
      (unless rata-beads--id
        (setq rata-beads--detail-buffer buffer))
      (with-current-buffer buffer
        (unless (derived-mode-p 'rata-beads-mode) (rata-beads-mode))
        (unless (equal rata-beads--id id)
          ;; Never show the previous task's text while the new query is pending.
          (let ((inhibit-read-only t))
            (erase-buffer)
            (setq magit-root-section nil)
            (insert (format "Loading task %s…\n" id))))
        (setq default-directory directory rata-beads--id id)
        (setq-local truncate-lines nil)
        (rata-beads-refresh))
      ;; Call the side-window function directly so Shackle cannot replace the
      ;; dashboard's window.  One slot also keeps repeated selections in place.
      (let ((window (display-buffer-in-side-window
                     buffer '((side . right) (slot . 1) (window-width . 0.45)))))
        (set-window-point window (with-current-buffer buffer (point-min)))
        (select-window window)))))

(defun rata-beads-quit ()
  "Quit this window, also closing this dashboard's task windows.
In a task detail buffer, quit only that window to return to the dashboard."
  (interactive)
  (let ((window (selected-window)))
    (when (and (not rata-beads--id) (buffer-live-p rata-beads--detail-buffer))
      (dolist (detail-window (get-buffer-window-list rata-beads--detail-buffer))
        (quit-window nil detail-window)))
    (quit-window nil window)))

(defun rata-beads-mouse-show (event)
  "Show the task clicked on by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (rata-beads-show))

(defvar rata-beads-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "RET") #'rata-beads-show)
    (define-key map [mouse-1] #'rata-beads-mouse-show)
    (define-key map (kbd "g") #'rata-beads-refresh)
    (define-key map (kbd "f") #'rata-beads-filter)
    (define-key map (kbd "y") #'rata-beads-copy-id)
    (define-key map (kbd "q") #'rata-beads-quit)
    map))

(define-derived-mode rata-beads-mode magit-section-mode "Beads"
  "Inspect Beads tasks in single rows with details in a side window."
  (setq-local truncate-lines t)
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
    (kbd "q") #'rata-beads-quit))

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
    (pop-to-buffer-same-window (get-buffer-create (format "*Beads: %s*" root)))
    (unless (derived-mode-p 'rata-beads-mode) (rata-beads-mode))
    (setq default-directory root)
    (rata-beads-refresh)))

(provide 'rata-beads)
;;; rata-beads.el ends here
