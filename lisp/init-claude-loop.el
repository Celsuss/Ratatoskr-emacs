;;; -*- lexical-binding: t; -*-
;;; init-claude-loop.el --- Drive Claude Code through a checklist file

;; Open a .md/.org file containing `- [ ] task' lines, start the loop, and each
;; task is handed to a fresh `claude -p' process in turn.  One process per task
;; means one session per task, so every task gets a clean context.  The child is
;; run with --output-format stream-json and its events are parsed here, so the
;; output buffer shows readable prose and tool calls rather than raw JSON.

(require 'ansi-color)
(require 'subr-x)

(declare-function org-todo "org" (&optional arg))

(defgroup rata-claude-loop nil
  "Run Claude Code over a checklist of tasks."
  :group 'tools
  :prefix "rata-claude-loop-")


;;; Customization

(defcustom rata-claude-loop-executable "claude"
  "Name of (or path to) the Claude Code CLI executable."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-extra-args '("--permission-mode" "acceptEdits")
  "Extra arguments passed to every `claude -p' invocation.
In print mode there are no interactive permission prompts: anything
not permitted is silently denied, so this is where autonomy is set."
  :type '(repeat string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-model nil
  "Model alias passed via --model, or nil to use the CLI default."
  :type '(choice (const :tag "CLI default" nil) string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-partial-messages nil
  "When non-nil, stream assistant text token-by-token.
Adds --include-partial-messages.  The per-turn assistant and tool-use
events are usually granular enough without it."
  :type 'boolean
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-task-regexp "^[ \t]*[-+*] \\[ \\][ \t]+\\(.+\\)$"
  "Regexp matching an open checklist item.
Group 1 must be the task description.  Covers both Markdown and Org
checkbox lists."
  :type 'regexp
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-org-todo-regexp "^\\*+[ \t]+TODO[ \t]+\\(.+\\)$"
  "Regexp matching an open Org TODO heading.
Group 1 must be the task description.  Only used in `org-mode' files."
  :type 'regexp
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-prompt-template
  "You are working through the task list in %s.

Your task -- the only task -- is:

%s

Complete it fully. Do not start any other task from that list.
Do not edit %s; the checkbox is managed by the caller.
Verify your work before finishing (run the project's tests or build if there are any).
If the task cannot be completed, stop and explain why instead of leaving partial changes."
  "Template for the prompt handed to Claude.
Receives three `format' arguments: the task file name, the task text,
and the task file name again."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-verify-command nil
  "Shell command run after each task that exits successfully.
A non-zero exit halts the loop and leaves the task unchecked.  This is
the only real quality gate: `claude -p' exits 0 whenever the CLI itself
succeeded, even if the code it wrote is wrong."
  :type '(choice (const :tag "None" nil) string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-max-tasks 50
  "Maximum number of tasks to run in a single loop, as a runaway guard."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-buffer-name "*claude-loop*"
  "Name of the buffer showing loop output."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-task-file-names
  '("tasks.md" "TASKS.md" "tasks.org" "TASKS.org" "TODO.md" "TODO.org")
  "File names searched for at the project root when no task file is obvious."
  :type '(repeat string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-root-markers
  '(".git" ".hg" ".projectile" ".svn" "_darcs" ".fslckout" "_FOSSIL_" ".bzr")
  "Markers identifying a repository root, searched upward from the task file.
Determines the working directory Claude is launched in."
  :type '(repeat string)
  :group 'rata-claude-loop)


;;; Faces

(defface rata-claude-loop-banner-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the per-task banner."
  :group 'rata-claude-loop)

(defface rata-claude-loop-text-face
  '((t :inherit default))
  "Face for assistant prose."
  :group 'rata-claude-loop)

(defface rata-claude-loop-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for tool-use lines."
  :group 'rata-claude-loop)

(defface rata-claude-loop-meta-face
  '((t :inherit font-lock-comment-face))
  "Face for session metadata and footers."
  :group 'rata-claude-loop)

(defface rata-claude-loop-error-face
  '((t :inherit error))
  "Face for errors and halts."
  :group 'rata-claude-loop)

(defface rata-claude-loop-success-face
  '((t :inherit success))
  "Face for successful task footers."
  :group 'rata-claude-loop)


;;; State

(defvar rata-claude-loop--state nil
  "Plist describing the running loop, or nil when idle.
Keys: :file :root :process :index :current-task :current-line :status
:started :pending :single.  :status is one of `running', `halted',
`finished'.  :pending accumulates a partial JSON line between filter
calls.  :single means run one task only and stop.")

(defun rata-claude-loop--get (key)
  "Return KEY from the loop state."
  (plist-get rata-claude-loop--state key))

(defun rata-claude-loop--put (key value)
  "Set KEY to VALUE in the loop state."
  (setq rata-claude-loop--state (plist-put rata-claude-loop--state key value)))

(defun rata-claude-loop-running-p ()
  "Return non-nil if a loop is currently running."
  (and rata-claude-loop--state
       (eq (rata-claude-loop--get :status) 'running)))


;;; Output buffer

(defvar rata-claude-loop-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'rata-claude-loop-status)
    (define-key map (kbd "k") #'rata-claude-loop-stop)
    map)
  "Keymap for `rata-claude-loop-mode'.")

(define-derived-mode rata-claude-loop-mode special-mode "ClaudeLoop"
  "Major mode for the Claude Code task-loop output buffer."
  (setq-local truncate-lines nil)
  (setq-local header-line-format '(:eval (rata-claude-loop--header-line))))

(defun rata-claude-loop--header-line ()
  "Return the header line describing the current loop."
  (if (null rata-claude-loop--state)
      "claude-loop: idle"
    (format "claude-loop: %s  ·  task %d  ·  %s"
            (file-name-nondirectory (or (rata-claude-loop--get :file) "?"))
            (or (rata-claude-loop--get :index) 0)
            (or (rata-claude-loop--get :status) 'idle))))

(defun rata-claude-loop--buffer ()
  "Return the loop output buffer, creating it if needed."
  (or (get-buffer rata-claude-loop-buffer-name)
      (with-current-buffer (get-buffer-create rata-claude-loop-buffer-name)
        (rata-claude-loop-mode)
        (current-buffer))))

(defun rata-claude-loop--insert (string &optional face)
  "Append STRING to the loop buffer, propertized with FACE."
  (let ((buffer (rata-claude-loop--buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (windows (get-buffer-window-list buffer nil t))
            (at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (if face (propertize string 'face face) string)))
        (when at-end (goto-char (point-max)))
        ;; Follow the tail only in windows already showing the end.
        (dolist (window windows)
          (when (>= (window-point window) (1- (point-max)))
            (set-window-point window (point-max))))))))

(defun rata-claude-loop--log (format-string &rest args)
  "Insert a line into the loop buffer from FORMAT-STRING and ARGS."
  (rata-claude-loop--insert (concat (apply #'format format-string args) "\n")))


;;; Task file handling

(defun rata-claude-loop--project-root (file)
  "Return the directory Claude should run in for task FILE.
Walks up from FILE looking for a marker in
`rata-claude-loop-root-markers'.  A marker at or above the home
directory is refused: a dotfiles repo or a stray package.json in $HOME
must not turn the whole home directory into the project.  Falls back to
the directory containing FILE, which is what you want for a checklist
sitting outside any repository."
  (let* ((directory (file-name-directory (expand-file-name file)))
         (home (file-name-as-directory (expand-file-name "~")))
         (marker-root (seq-some (lambda (marker)
                                  (locate-dominating-file directory marker))
                                rata-claude-loop-root-markers))
         (root (and marker-root
                    (file-name-as-directory (expand-file-name marker-root)))))
    (if (and root (not (string-prefix-p root home)))
        root
      directory)))

(defun rata-claude-loop--task-file (&optional prompt)
  "Resolve the task file to use.
With PROMPT non-nil, always ask.  Otherwise prefer the current buffer
when it visits a Markdown or Org file, then a well-known file name at
the project root, then ask."
  (cond
   (prompt (expand-file-name (read-file-name "Task file: " nil nil t)))
   ((and buffer-file-name
         (string-match-p "\\.\\(md\\|markdown\\|org\\)\\'" buffer-file-name))
    buffer-file-name)
   (t
    ;; Search upward from the current directory rather than from a guessed
    ;; project root, for the same reason as `rata-claude-loop--project-root'.
    (or (seq-some (lambda (name)
                    (let ((directory (locate-dominating-file default-directory name)))
                      (and directory (expand-file-name name directory))))
                  rata-claude-loop-task-file-names)
        (expand-file-name (read-file-name "Task file: " nil nil t))))))

(defun rata-claude-loop--file-buffer (file)
  "Return a live buffer visiting FILE, creating one if needed."
  (find-file-noselect file))

(defun rata-claude-loop--next-task (file)
  "Return (LINE . TEXT) for the first open task in FILE, or nil.
The file is rescanned on every call, so the list can be edited while the
loop runs and it is harmless if Claude ticks a box itself."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    (save-excursion
      (goto-char (point-min))
      (let ((org (derived-mode-p 'org-mode))
            (best nil))
        (dolist (regexp (if org
                            (list rata-claude-loop-task-regexp
                                  rata-claude-loop-org-todo-regexp)
                          (list rata-claude-loop-task-regexp)))
          (goto-char (point-min))
          (when (re-search-forward regexp nil t)
            (let ((position (match-beginning 0)))
              (when (or (null best) (< position (car best)))
                (setq best (list position
                                 (line-number-at-pos position)
                                 (string-trim (match-string 1))))))))
        (when best
          (cons (nth 1 best) (nth 2 best)))))))

(defun rata-claude-loop--mark-line (file line marker)
  "Mark the task on LINE of FILE with MARKER, one of `done' or `skipped'.
Editing happens in the live buffer so an already-open task file stays in
sync.  Returns non-nil when the line actually changed."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- line))
      (let ((changed nil))
        (cond
         ;; Org TODO heading: go through org so logging/repeaters behave.
         ((and (derived-mode-p 'org-mode)
               (looking-at rata-claude-loop-org-todo-regexp))
          (org-todo (if (eq marker 'done) 'done "CANCELLED"))
          (setq changed t))
         ((looking-at "^\\([ \t]*[-+*] \\)\\[ \\]")
          (replace-match (concat "\\1[" (if (eq marker 'done) "X" "-") "]")
                         nil nil)
          (setq changed t)))
        (when changed
          (save-buffer))
        changed))))

(defun rata-claude-loop--count-open (file)
  "Return the number of open tasks left in FILE."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (re-search-forward rata-claude-loop-task-regexp nil t)
          (setq count (1+ count)))
        (when (derived-mode-p 'org-mode)
          (goto-char (point-min))
          (while (re-search-forward rata-claude-loop-org-todo-regexp nil t)
            (setq count (1+ count))))
        count))))


;;; Stream rendering

(defun rata-claude-loop--truncate (string limit)
  "Return STRING collapsed to a single line and truncated to LIMIT chars."
  (let ((flat (replace-regexp-in-string "[ \t\n\r]+" " " (or string ""))))
    (if (> (length flat) limit)
        (concat (substring flat 0 limit) "…")
      flat)))

(defun rata-claude-loop--tool-argument (input)
  "Return a short description of tool INPUT for display.
Absolute paths under the project root are shown relative to it."
  (let* ((value (seq-some (lambda (key) (alist-get key input))
                          '(file_path command pattern description url path query)))
         (root (rata-claude-loop--get :root))
         (value (if (and (stringp value) (stringp root)
                         (string-prefix-p (file-name-as-directory root) value))
                    (file-relative-name value root)
                  value)))
    (rata-claude-loop--truncate (if (stringp value) value "") 72)))

(defun rata-claude-loop--indent (text prefix)
  "Return TEXT with every line after the first indented under PREFIX."
  (let ((pad (make-string (length prefix) ?\s)))
    (replace-regexp-in-string "\n" (concat "\n" pad) text)))

(defun rata-claude-loop--render-assistant (event)
  "Render an assistant EVENT's content blocks."
  (dolist (block (alist-get 'content (alist-get 'message event)))
    (pcase (alist-get 'type block)
      ("text"
       (let ((text (string-trim (or (alist-get 'text block) ""))))
         (unless (string-empty-p text)
           (rata-claude-loop--insert
            (concat "  ● " (rata-claude-loop--indent text "  ● ") "\n")
            'rata-claude-loop-text-face))))
      ("tool_use"
       (rata-claude-loop--insert
        (format "  ⚙ %-10s %s\n"
                (or (alist-get 'name block) "?")
                (rata-claude-loop--tool-argument (alist-get 'input block)))
        'rata-claude-loop-tool-face)))))

(defun rata-claude-loop--render-user (event)
  "Render failing tool results from a user EVENT."
  (dolist (block (alist-get 'content (alist-get 'message event)))
    (when (and (equal (alist-get 'type block) "tool_result")
               (alist-get 'is_error block))
      (let ((content (alist-get 'content block)))
        (rata-claude-loop--insert
         (format "  ✗ tool error: %s\n"
                 (rata-claude-loop--truncate
                  (if (stringp content) content (format "%S" content))
                  160))
         'rata-claude-loop-error-face)))))

(defun rata-claude-loop--render-result (event)
  "Render the terminating result EVENT."
  (let ((denials (alist-get 'permission_denials event)))
    (when denials
      (rata-claude-loop--insert
       (format "  ! %d permission denial(s): %s\n"
               (length denials)
               (mapconcat (lambda (denial)
                            (or (alist-get 'tool_name denial) "?"))
                          denials ", "))
       'rata-claude-loop-error-face)))
  (let ((error-p (alist-get 'is_error event))
        (cost (alist-get 'total_cost_usd event))
        (duration (alist-get 'duration_ms event))
        (turns (alist-get 'num_turns event)))
    (rata-claude-loop--insert
     (format "\n  %s %s · %.0fs · $%.2f · %s turns\n"
             (if error-p "✗" "✓")
             (or (alist-get 'subtype event) "")
             (/ (or duration 0) 1000.0)
             (or cost 0)
             (or turns 0))
     (if error-p 'rata-claude-loop-error-face 'rata-claude-loop-success-face))))

(defun rata-claude-loop--render-event (event)
  "Render a single decoded stream EVENT."
  (pcase (alist-get 'type event)
    ("system"
     ;; hook_started / hook_response / thinking_tokens are noise.
     (when (equal (alist-get 'subtype event) "init")
       (rata-claude-loop--insert
        (format "  [%s · %s · %s]\n"
                (or (alist-get 'model event) "?")
                (or (alist-get 'permissionMode event) "?")
                (rata-claude-loop--truncate (or (alist-get 'session_id event) "") 8))
        'rata-claude-loop-meta-face)))
    ("assistant" (rata-claude-loop--render-assistant event))
    ("user" (rata-claude-loop--render-user event))
    ("result" (rata-claude-loop--render-result event))
    ("stream_event"
     (when rata-claude-loop-partial-messages
       (let* ((delta (alist-get 'delta (alist-get 'event event)))
              (text (and (equal (alist-get 'type delta) "text_delta")
                         (alist-get 'text delta))))
         (when text
           (rata-claude-loop--insert text 'rata-claude-loop-text-face)))))))

(defun rata-claude-loop--filter (process string)
  "Process filter for PROCESS decoding newline-delimited JSON in STRING."
  (when (eq process (rata-claude-loop--get :process))
    (let* ((pending (concat (or (rata-claude-loop--get :pending) "") string))
           (lines (split-string pending "\n")))
      ;; The final element is an incomplete line (or "" on a clean boundary).
      (rata-claude-loop--put :pending (car (last lines)))
      (dolist (line (butlast lines))
        (let ((trimmed (string-trim line)))
          (unless (string-empty-p trimmed)
            (condition-case nil
                (rata-claude-loop--render-event
                 (json-parse-string trimmed
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil))
              (error
               ;; Not JSON: most likely a warning on stdout.  Show it raw.
               (rata-claude-loop--insert
                (concat "  " (ansi-color-apply trimmed) "\n")
                'rata-claude-loop-meta-face)))))))))


;;; Running

(defun rata-claude-loop--build-command (task file)
  "Return the argv list running TASK from FILE through the Claude CLI."
  (let ((name (file-name-nondirectory file)))
    (append
     (list rata-claude-loop-executable
           "-p" (format rata-claude-loop-prompt-template name task name)
           "--output-format" "stream-json"
           "--verbose")
     (when rata-claude-loop-partial-messages '("--include-partial-messages"))
     (when rata-claude-loop-model (list "--model" rata-claude-loop-model))
     rata-claude-loop-extra-args)))

(defun rata-claude-loop--halt (format-string &rest args)
  "Halt the loop, reporting FORMAT-STRING with ARGS."
  (rata-claude-loop--put :status 'halted)
  (let ((message-text (apply #'format format-string args)))
    (rata-claude-loop--insert (format "\n■ halted: %s\n\n" message-text)
                              'rata-claude-loop-error-face)
    (message "claude-loop halted: %s" message-text))
  (display-buffer (rata-claude-loop--buffer)))

(defun rata-claude-loop--verify ()
  "Run `rata-claude-loop-verify-command'.
Return non-nil when it passes or when no command is configured."
  (if (null rata-claude-loop-verify-command)
      t
    (rata-claude-loop--log "  … verifying: %s" rata-claude-loop-verify-command)
    (let* ((default-directory (rata-claude-loop--get :root))
           (output (generate-new-buffer " *claude-loop-verify*"))
           (code (call-process shell-file-name nil output nil
                               shell-command-switch
                               rata-claude-loop-verify-command)))
      (unwind-protect
          (if (zerop code)
              (progn (rata-claude-loop--insert "  ✓ verify passed\n"
                                               'rata-claude-loop-success-face)
                     t)
            (rata-claude-loop--insert
             (format "  ✗ verify failed (exit %s):\n%s\n" code
                     (with-current-buffer output
                       (rata-claude-loop--truncate (buffer-string) 800)))
             'rata-claude-loop-error-face)
            nil)
        (kill-buffer output)))))

(defun rata-claude-loop--sentinel (process _event)
  "Sentinel for PROCESS advancing the loop when it exits."
  (when (and (eq process (rata-claude-loop--get :process))
             (memq (process-status process) '(exit signal)))
    (let ((code (process-exit-status process))
          (file (rata-claude-loop--get :file))
          (line (rata-claude-loop--get :current-line))
          (task (rata-claude-loop--get :current-task)))
      (rata-claude-loop--put :process nil)
      (cond
       ((not (zerop code))
        (rata-claude-loop--halt "claude exited with code %s" code))
       ((not (rata-claude-loop--verify))
        (rata-claude-loop--halt "verify command failed"))
       ((not (rata-claude-loop--mark-line file line 'done))
        (rata-claude-loop--halt
         "could not tick the checkbox on line %s of %s"
         line (file-name-nondirectory file)))
       ((rata-claude-loop--get :single)
        (rata-claude-loop--put :status 'finished)
        (rata-claude-loop--insert "\n■ task done.\n\n"
                                  'rata-claude-loop-success-face)
        (message "claude-loop: done — %s" task))
       (t
        (rata-claude-loop--put :last-task task)
        (rata-claude-loop--advance))))))

(defun rata-claude-loop--run-task (line task)
  "Start a Claude process for TASK found on LINE."
  (let* ((file (rata-claude-loop--get :file))
         (index (1+ (or (rata-claude-loop--get :index) 0)))
         (remaining (rata-claude-loop--count-open file))
         (default-directory (rata-claude-loop--get :root))
         (command (rata-claude-loop--build-command task file)))
    (rata-claude-loop--put :index index)
    (rata-claude-loop--put :current-line line)
    (rata-claude-loop--put :current-task task)
    (rata-claude-loop--put :pending "")
    (rata-claude-loop--put :status 'running)
    (rata-claude-loop--insert
     (format "\n%s\n▶ [%d/%d] %s\n\n"
             (make-string 60 ?─) index (+ index remaining -1) task)
     'rata-claude-loop-banner-face)
    (message "claude-loop [%d]: %s" index task)
    ;; A spawn failure here would otherwise propagate out of the sentinel that
    ;; called us, where errors are silently swallowed and the loop would hang
    ;; with :status stuck at `running'.
    (condition-case err
        (let ((stderr (rata-claude-loop--stderr-process)))
          (condition-case spawn-error
              (let ((process (make-process
                              :name "claude-loop"
                              :buffer nil
                              :command command
                              :connection-type 'pipe
                              :noquery t
                              :stderr stderr
                              :filter #'rata-claude-loop--filter
                              :sentinel #'rata-claude-loop--sentinel)))
                ;; Register before touching the process: the filter and sentinel
                ;; identity-check against :process and would drop early output.
                (rata-claude-loop--put :process process)
                ;; The prompt is passed via -p, so the child gets nothing on
                ;; stdin.  Close it immediately, or the CLI waits 3s for piped
                ;; input and warns about it on every single task.
                (process-send-eof process))
            (error (delete-process stderr) (signal (car spawn-error) (cdr spawn-error)))))
      (error
       (rata-claude-loop--put :process nil)
       (rata-claude-loop--halt "could not start %s: %s"
                               rata-claude-loop-executable
                               (error-message-string err))))))

(defun rata-claude-loop--stderr-process ()
  "Return a process rendering the child's stderr into the loop buffer."
  (make-pipe-process
   :name "claude-loop-stderr"
   :buffer nil
   :noquery t
   :filter (lambda (_process string)
             (rata-claude-loop--insert
              (replace-regexp-in-string "^" "  ! " (string-trim-right string))
              'rata-claude-loop-error-face)
             (rata-claude-loop--insert "\n"))))

(defun rata-claude-loop--advance ()
  "Run the next open task, or finish the loop when none are left."
  (let* ((file (rata-claude-loop--get :file))
         (next (rata-claude-loop--next-task file)))
    (cond
     ((>= (or (rata-claude-loop--get :index) 0) rata-claude-loop-max-tasks)
      (rata-claude-loop--halt "hit `rata-claude-loop-max-tasks' (%d)"
                              rata-claude-loop-max-tasks))
     ((null next)
      (rata-claude-loop--put :status 'finished)
      (rata-claude-loop--insert
       (format "\n■ all tasks in %s are complete (%d run).\n\n"
               (file-name-nondirectory file)
               (or (rata-claude-loop--get :index) 0))
       'rata-claude-loop-success-face)
      (message "claude-loop: all tasks complete"))
     ;; A task identical to the one just finished means the checkbox never
     ;; changed; running it again would spin forever.
     ((equal (cdr next) (rata-claude-loop--get :last-task))
      (rata-claude-loop--halt "task %S repeated — checkbox was not updated"
                              (cdr next)))
     (t
      (rata-claude-loop--run-task (car next) (cdr next))))))


;;; Commands

;;;###autoload
(defun rata-claude-loop-start (&optional ask)
  "Work through the open tasks in a checklist file with Claude Code.
With one prefix argument ASK, prompt for the task file.  With two,
also prompt for the directory Claude should run in."
  (interactive "P")
  (when (rata-claude-loop-running-p)
    (user-error "A claude-loop is already running; stop it first"))
  (let* ((file (rata-claude-loop--task-file ask))
         (root (if (equal ask '(16))
                   (read-directory-name
                    "Run Claude in: " (rata-claude-loop--project-root file) nil t)
                 (rata-claude-loop--project-root file)))
         (open (rata-claude-loop--count-open file)))
    (when (zerop open)
      (user-error "No open tasks in %s" file))
    (unless (executable-find rata-claude-loop-executable)
      (user-error "Cannot find %s in `exec-path'" rata-claude-loop-executable))
    (unless (y-or-n-p (format "Run Claude on %d task(s) from %s in %s? "
                              open (file-name-nondirectory file) root))
      (user-error "Aborted"))
    (setq rata-claude-loop--state
          (list :file file :root root :index 0 :status 'running
                :started (current-time) :pending "" :single nil))
    (with-current-buffer (rata-claude-loop--buffer)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (display-buffer (rata-claude-loop--buffer))
    (rata-claude-loop--advance)))

;;;###autoload
(defun rata-claude-loop-run-task-at-point ()
  "Run only the task on the current line through Claude Code."
  (interactive)
  (when (rata-claude-loop-running-p)
    (user-error "A claude-loop is already running; stop it first"))
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let ((task (save-excursion
                (beginning-of-line)
                (cond
                 ((looking-at rata-claude-loop-task-regexp) (match-string 1))
                 ((and (derived-mode-p 'org-mode)
                       (looking-at rata-claude-loop-org-todo-regexp))
                  (match-string 1))
                 (t (user-error "No open task on this line"))))))
    (setq rata-claude-loop--state
          (list :file buffer-file-name
                :root (rata-claude-loop--project-root buffer-file-name)
                :index 0 :status 'running :started (current-time)
                :pending "" :single t))
    (with-current-buffer (rata-claude-loop--buffer)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (display-buffer (rata-claude-loop--buffer))
    (rata-claude-loop--run-task (line-number-at-pos) (string-trim task))))

;;;###autoload
(defun rata-claude-loop-stop ()
  "Stop the running loop and kill the current Claude process."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop to stop"))
  (let ((process (rata-claude-loop--get :process)))
    (rata-claude-loop--put :status 'halted)
    (rata-claude-loop--put :process nil)
    (when (process-live-p process)
      (kill-process process)))
  (rata-claude-loop--insert "\n■ stopped by user.\n\n"
                            'rata-claude-loop-error-face)
  (message "claude-loop stopped"))

;;;###autoload
(defun rata-claude-loop-resume ()
  "Resume a halted loop from the next open task."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop to resume; use `rata-claude-loop-start'"))
  (when (rata-claude-loop-running-p)
    (user-error "The loop is already running"))
  (rata-claude-loop--put :single nil)
  (rata-claude-loop--put :last-task nil)
  (rata-claude-loop--put :status 'running)
  (display-buffer (rata-claude-loop--buffer))
  (rata-claude-loop--advance))

;;;###autoload
(defun rata-claude-loop-skip ()
  "Mark the next open task as skipped and continue the loop."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop in progress"))
  (when (rata-claude-loop-running-p)
    (user-error "Stop the running task first"))
  (let* ((file (rata-claude-loop--get :file))
         (next (rata-claude-loop--next-task file)))
    (unless next
      (user-error "No open task to skip"))
    (rata-claude-loop--mark-line file (car next) 'skipped)
    (rata-claude-loop--log "  ⊘ skipped: %s" (cdr next))
    (rata-claude-loop--put :last-task nil)
    (rata-claude-loop--put :status 'running)
    (rata-claude-loop--advance)))

;;;###autoload
(defun rata-claude-loop-status ()
  "Report the state of the loop in the echo area."
  (interactive)
  (if (null rata-claude-loop--state)
      (message "claude-loop: idle")
    (message "claude-loop: %s · %s · task %d (%s) · %d open · %s elapsed"
             (rata-claude-loop--get :status)
             (file-name-nondirectory (rata-claude-loop--get :file))
             (or (rata-claude-loop--get :index) 0)
             (rata-claude-loop--truncate
              (or (rata-claude-loop--get :current-task) "-") 50)
             (rata-claude-loop--count-open (rata-claude-loop--get :file))
             (format-seconds "%mm %ss"
                             (float-time (time-subtract
                                          (current-time)
                                          (rata-claude-loop--get :started)))))))

;;;###autoload
(defun rata-claude-loop-show-buffer ()
  "Pop to the loop output buffer."
  (interactive)
  (pop-to-buffer (rata-claude-loop--buffer)))


;;; Keybindings

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aicl"  '(:ignore t :which-key "task loop")
    "aicll" '(rata-claude-loop-start             :which-key "start loop")
    "aiclr" '(rata-claude-loop-run-task-at-point :which-key "run task at point")
    "aicls" '(rata-claude-loop-stop              :which-key "stop loop")
    "aicln" '(rata-claude-loop-skip              :which-key "skip current task")
    "aiclc" '(rata-claude-loop-resume            :which-key "resume after halt")
    "aiclb" '(rata-claude-loop-show-buffer       :which-key "show output")
    "aicl?" '(rata-claude-loop-status            :which-key "status")))

(provide 'init-claude-loop)
