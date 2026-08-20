;;; -*- lexical-binding: t; -*-
;;; init-claude-loop.el --- Drive Claude Code through a checklist file

;; Open a .md/.org file containing `- [ ] task' lines, start the loop, and each
;; task is handed to a fresh `claude -p' process in turn.  One process per task
;; means one session per task, so every task gets a clean context.  The child is
;; run with --output-format stream-json and its events are parsed here, so the
;; output buffer shows readable prose and tool calls rather than raw JSON.
;;
;; Control flow is a trampoline, not a callback chain.  Process sentinels and
;; timers only record what happened and schedule `rata-claude-loop--step'; every
;; state transition then runs from a zero-delay timer at top level.  Two reasons
;; this matters: an error signalled inside a sentinel is demoted to a line in
;; *Messages*, which would leave the loop claiming to run with nothing running;
;; and marking a checkbox calls `save-buffer' and `org-todo', i.e. arbitrary
;; hook code, which has no business executing in a process callback.
;;
;; Staleness is handled by `:epoch', an integer bumped on every spawn and every
;; stop.  Callbacks and timers capture the epoch they were created under and
;; no-op on mismatch, which covers the child process, the stderr pipe, the
;; timeout timer, the grace-period kill and the pending step timer with one
;; check.

(require 'ansi-color)
(require 'seq)
(require 'subr-x)

(declare-function org-todo "org" (&optional arg))
(declare-function org-toggle-tag "org" (tag &optional onoff))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string &optional paste-p))

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

(defcustom rata-claude-loop-fallback-model nil
  "Model to fall back to when the primary is overloaded, or nil.
Passed as --fallback-model, which only applies in print mode.  Without
it a transient overload halts the whole loop."
  :type '(choice (const :tag "None" nil) string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-max-turns nil
  "Cap on tool-use rounds per attempt, or nil for no cap.
Passed as --max-turns.  Hitting it ends the attempt with subtype
`error_max_turns', which this module treats as retryable."
  :type '(choice (const :tag "No cap" nil) integer)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-task-budget-usd nil
  "Dollar cap per attempt, or nil for no cap.
Passed as --max-budget-usd.  Hitting it ends the attempt with subtype
`error_max_budget_usd', which halts the loop rather than retrying —
spending more on the same task is exactly what the cap forbids."
  :type '(choice (const :tag "No cap" nil) number)
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

(defcustom rata-claude-loop-org-cancelled-keywords '("CANCELLED" "CANCELED" "KILL")
  "Org keywords meaning \"deliberately not done\", tried in order.
A skipped Org task moves to the first of these present in
`org-todo-keywords-1'.  With the default keyword set there is none, and
`org-todo' would signal on an unknown state, so the task is moved to DONE
and tagged instead."
  :type '(repeat string)
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
and the task file name again.  `rata-claude-loop-report-instruction' is
appended to whatever this produces."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-report-instruction
  "End your final message with a status line of its own, exactly one of:

RATA-TASK-STATUS: done
RATA-TASK-STATUS: blocked -- <one-line reason>

Report `blocked' if you could not finish. `claude -p' exits 0 whenever the
CLI itself succeeded, so this line is how the caller tells a completed task
from an abandoned one; without it an abandoned task is recorded as done."
  "Instruction appended to every prompt asking for a machine-readable verdict.
Set to the empty string to disable the self-report, which also makes
`rata-claude-loop-require-status' meaningless."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-require-status nil
  "When non-nil, a task that reports no status line counts as failed.
Stricter, but it will also fail against a model that simply forgets the
line, so it is off by default; a reported `blocked' always fails."
  :type 'boolean
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-critical-denial-tools
  '("Edit" "Write" "MultiEdit" "NotebookEdit")
  "Tools whose denial means the task cannot have done anything.
Print mode denies silently rather than prompting, so a task whose every
edit was refused still exits 0 with a `success' subtype.  A denial of one
of these fails the attempt; a denied WebFetch is reported but tolerated,
because halting a good run over it would be worse."
  :type '(repeat string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-verify-command nil
  "Shell command run after each task that reports success.
A non-zero exit fails the task, which then retries or halts.  This is the
strongest quality gate available: `claude -p' exits 0 whenever the CLI
itself succeeded, even if the code it wrote is wrong.

Read in the task file's buffer, so a project can set it through
`.dir-locals.el'.  Deliberately not marked `safe-local-variable' — it is
a shell command and Emacs should ask before trusting one."
  :type '(choice (const :tag "None" nil) string)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-verify-output-lines 40
  "How many trailing lines of failed verify output to show in the buffer.
The tail, not the head: a test runner's summary is at the end."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-max-attempts 2
  "Attempts allowed per task, counting the first.
The default 2 means one retry.  Beyond that you pay a full task each time
for progressively worse odds, and an unbounded retry-on-test-output loop
is how an agent talks itself into deleting the failing test."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-retry-on '(verify execution max-turns)
  "Failure kinds worth retrying by resuming the task's session.
Recognised kinds: `verify' (the verify command failed), `execution' (the
CLI reported an error mid-run, which covers a transient overload),
`max-turns', `budget', `denied', `blocked', `timeout', `crash',
`no-result'.  The excluded ones are excluded on purpose: a timeout leaves
unknown partial state, `blocked' is a considered judgement rather than a
stumble, and `budget' means the cap you set did its job."
  :type '(repeat symbol)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-retry-prompt-template
  "That attempt did not pass: %s

%s

Fix it and finish the task you were given. Do not weaken, skip, disable or
delete tests to make them pass. Do not edit the checklist file. End with a
status line as before."
  "Template for the follow-up prompt sent when retrying a task.
Receives two `format' arguments: the failure reason, and captured output
(the tail of the verify command's output, or an empty string)."
  :type 'string
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-feedback-limit 4000
  "Maximum characters of captured output fed back into a retry.
Truncated from the front: the interesting part of a failing test run is
at the end."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-retry-backoff 15
  "Seconds to wait before retrying a failure that looks transient."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-task-timeout 1800
  "Seconds a single attempt may run before it is stopped, or nil for none.
There is no CLI flag for this, so the timer lives here."
  :type '(choice (const :tag "No timeout" nil) integer)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-verify-timeout 900
  "Seconds the verify command may run before it is stopped, or nil for none."
  :type '(choice (const :tag "No timeout" nil) integer)
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-kill-grace 5
  "Seconds between SIGINT and SIGKILL when stopping a child.
SIGKILL alone gives the CLI no chance to flush its final result event."
  :type 'integer
  :group 'rata-claude-loop)

(defcustom rata-claude-loop-git-checkpoint nil
  "Whether to report what each task changed in git.
`record' prints a per-task `git diff --stat' into the loop buffer,
baselined with `git stash create' so it shows only this task's changes.
Read-only: nothing is committed, stashed or reset.  nil disables it."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Report a diffstat per task" record))
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

Loop-wide keys: :file :root :started :single :status :phase :epoch :index
:open-count.  :status is `running', `halted' or `finished'.  :phase is
`idle', `claude', `verify', `mark', `between' or `done' and is the finer
grained truth; :status exists so `rata-claude-loop-running-p' stays cheap.

Per-attempt keys: :process :stderr :pending :stderr-pending :session-id
:result :report :report-reason :outcome :attempt :current-task
:current-line :task-started :baseline :verify-process :verify-buffer
:verify-output :timer :kill-timer :step-timer.

:pending and :stderr-pending accumulate a partial line between filter
calls.  :outcome is written at most once per attempt.  :epoch invalidates
outstanding callbacks; see the commentary at the top of this file.")

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

(defun rata-claude-loop--busy-p ()
  "Return non-nil while the loop owns a live process."
  (or (process-live-p (rata-claude-loop--get :process))
      (process-live-p (rata-claude-loop--get :verify-process))))

(defun rata-claude-loop--wedged-p ()
  "Return non-nil when the loop claims to run but nothing is running.
Should be unreachable; reported in the status line so that if it ever
happens it is visible rather than a silent hang."
  (and (rata-claude-loop-running-p)
       (not (rata-claude-loop--busy-p))
       (not (timerp (rata-claude-loop--get :step-timer)))))

(defun rata-claude-loop--bump-epoch ()
  "Start a new epoch, invalidating every outstanding callback and timer."
  (let ((epoch (1+ (or (rata-claude-loop--get :epoch) 0))))
    (rata-claude-loop--put :epoch epoch)
    epoch))

(defun rata-claude-loop--epoch-current-p (epoch)
  "Return non-nil when EPOCH is still the live one."
  (and rata-claude-loop--state
       (eql epoch (rata-claude-loop--get :epoch))))

(defun rata-claude-loop--set-outcome (kind reason)
  "Record KIND and REASON as this attempt's outcome; the first writer wins.
A timeout stops the child, so the sentinel arrives moments later with a
signal status.  Without write-once the timeout's verdict would be
overwritten by the kill it caused."
  (unless (rata-claude-loop--get :outcome)
    (rata-claude-loop--put :outcome (cons kind reason))))

(defun rata-claude-loop--cancel-timer (key)
  "Cancel and clear the timer stored under KEY."
  (let ((timer (rata-claude-loop--get key)))
    (when (timerp timer)
      (cancel-timer timer)))
  (rata-claude-loop--put key nil))

(defun rata-claude-loop--cancel-timers ()
  "Cancel every timer the loop owns."
  (dolist (key '(:timer :kill-timer :step-timer))
    (rata-claude-loop--cancel-timer key)))


;;; Output buffer

(defvar rata-claude-loop-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'rata-claude-loop-status)
    (define-key map (kbd "r") #'rata-claude-loop-retry-task)
    (define-key map (kbd "o") #'rata-claude-loop-open-session)
    (define-key map (kbd "K") #'rata-claude-loop-stop)
    map)
  "Keymap for `rata-claude-loop-mode'.
Evil users get the bindings installed near the bottom of this file
instead; a plain keymap loses to evil's state maps.")

(define-derived-mode rata-claude-loop-mode special-mode "ClaudeLoop"
  "Major mode for the Claude Code task-loop output buffer."
  (setq-local truncate-lines nil)
  (setq-local header-line-format '(:eval (rata-claude-loop--header-line))))

(defun rata-claude-loop--header-line ()
  "Return the header line describing the current loop."
  (if (null rata-claude-loop--state)
      "claude-loop: idle"
    (let ((attempt (or (rata-claude-loop--get :attempt) 1)))
      (format "claude-loop: %s  ·  task %d  ·  %s%s%s"
              (file-name-nondirectory (or (rata-claude-loop--get :file) "?"))
              (or (rata-claude-loop--get :index) 0)
              (or (rata-claude-loop--get :phase)
                  (rata-claude-loop--get :status) 'idle)
              (if (> attempt 1) (format "  ·  attempt %d" attempt) "")
              (if (rata-claude-loop--wedged-p) "  ·  WEDGED" "")))))

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

(defmacro rata-claude-loop--guard (&rest body)
  "Run BODY, halting the loop on error rather than losing the error.
Emacs demotes an error raised inside a process filter, sentinel or timer
to a line in *Messages*.  Without this the loop would sit at `:status
running' with nothing running and no visible explanation."
  (declare (indent 0) (debug t))
  `(condition-case err
       (progn ,@body)
     (error
      (rata-claude-loop--halt "internal error: %s" (error-message-string err)))))

(defun rata-claude-loop--later (function)
  "Schedule FUNCTION to run at top level, in the current epoch.
Transitions must not run inside a process callback; see the commentary at
the top of this file."
  (let ((epoch (rata-claude-loop--get :epoch)))
    (rata-claude-loop--put
     :step-timer
     (run-at-time 0 nil
                  (lambda ()
                    (when (rata-claude-loop--epoch-current-p epoch)
                      (rata-claude-loop--put :step-timer nil)
                      (rata-claude-loop--guard (funcall function))))))))


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

(defun rata-claude-loop--task-regexps ()
  "Return the open-task regexps that apply to the current buffer."
  (if (derived-mode-p 'org-mode)
      (list rata-claude-loop-task-regexp rata-claude-loop-org-todo-regexp)
    (list rata-claude-loop-task-regexp)))

(defun rata-claude-loop--scan-buffer ()
  "Return (LINE . TEXT) for the first open task in the current buffer, or nil."
  (save-excursion
    (let ((best nil))
      (dolist (regexp (rata-claude-loop--task-regexps))
        (goto-char (point-min))
        (when (re-search-forward regexp nil t)
          (let ((position (match-beginning 0)))
            (when (or (null best) (< position (car best)))
              (setq best (list position
                               (line-number-at-pos position)
                               (string-trim (match-string 1))))))))
      (when best
        (cons (nth 1 best) (nth 2 best))))))

(defun rata-claude-loop--count-in-buffer ()
  "Return the number of open tasks in the current buffer."
  (save-excursion
    (let ((count 0))
      (dolist (regexp (rata-claude-loop--task-regexps))
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (setq count (1+ count))))
      count)))

(defun rata-claude-loop--task-at-line-p (line text)
  "Return non-nil when LINE of the current buffer is an open task reading TEXT."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (seq-some (lambda (regexp)
                (and (looking-at regexp)
                     (equal (string-trim (match-string 1)) text)))
              (rata-claude-loop--task-regexps))))

(defun rata-claude-loop--find-task-line (line text)
  "Return the line of the current buffer holding the open task TEXT, or nil.
Prefers LINE and falls back to searching the whole buffer, because the
file can shift under a task that ran for half an hour.  Refuses an
ambiguous match: ticking the wrong box is worse than halting and saying
so."
  (if (rata-claude-loop--task-at-line-p line text)
      line
    (save-excursion
      (let ((matches nil))
        (dolist (regexp (rata-claude-loop--task-regexps))
          (goto-char (point-min))
          (while (re-search-forward regexp nil t)
            (when (equal (string-trim (match-string 1)) text)
              (push (line-number-at-pos (match-beginning 0)) matches))))
        (setq matches (delete-dups matches))
        (and (= (length matches) 1) (car matches))))))

(defun rata-claude-loop--org-mark (marker)
  "Move the Org heading at point to a state representing MARKER.
`skipped' wants a cancelled keyword, but `org-todo' signals on a state
that is not in `org-todo-keywords-1' — and the default keyword set has
none — so fall back to DONE plus a tag, which keeps the intent."
  (if (eq marker 'done)
      (org-todo 'done)
    (let ((cancelled (seq-find (lambda (keyword)
                                 (member keyword
                                         (bound-and-true-p org-todo-keywords-1)))
                               rata-claude-loop-org-cancelled-keywords)))
      (if cancelled
          (org-todo cancelled)
        (org-todo 'done)
        (org-toggle-tag "skipped" 'on)))))

(defun rata-claude-loop--mark-in-buffer (line marker)
  "Mark the task on LINE of the current buffer with MARKER.
MARKER is `done' or `skipped'.  Returns non-nil when the line changed."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (cond
     ;; Org TODO heading: go through org so logging/repeaters behave.
     ((and (derived-mode-p 'org-mode)
           (looking-at rata-claude-loop-org-todo-regexp))
      (rata-claude-loop--org-mark marker)
      t)
     ((looking-at "^\\([ \t]*[-+*] \\)\\[ \\]")
      (replace-match (concat "\\1[" (if (eq marker 'done) "X" "-") "]")
                     nil nil)
      t))))

(defun rata-claude-loop--mark-task (file line text marker)
  "Mark the task TEXT of FILE, expected on LINE, with MARKER.
Returns the line actually marked, or nil when the task could not be
located unambiguously — in which case nothing is written.  Editing
happens in the live buffer so an already-open task file stays in sync."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    ;; Pick up an external edit, but never discard the user's own: if the
    ;; buffer is modified and the file changed too, leave it and let
    ;; `save-buffer' ask.
    (unless (or (buffer-modified-p) (verify-visited-file-modtime))
      (revert-buffer t t t))
    (let ((target (rata-claude-loop--find-task-line line text)))
      (when target
        (let ((dirty (buffer-modified-p)))
          (when (rata-claude-loop--mark-in-buffer target marker)
            (when dirty
              (rata-claude-loop--log
               "  ! %s had unsaved edits; they are being saved along with the checkbox"
               (file-name-nondirectory file)))
            (save-buffer)
            target))))))

(defun rata-claude-loop--next-task (file)
  "Return (LINE . TEXT) for the first open task in FILE, or nil.
The file is rescanned on every call, so the list can be edited while the
loop runs and it is harmless if Claude ticks a box itself."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    (rata-claude-loop--scan-buffer)))

(defun rata-claude-loop--count-open (file)
  "Return the number of open tasks left in FILE."
  (with-current-buffer (rata-claude-loop--file-buffer file)
    (rata-claude-loop--count-in-buffer)))

(defun rata-claude-loop--verify-command ()
  "Return the verify command, read in the task file's buffer.
Reading it there rather than globally lets a project set it in
`.dir-locals.el'."
  (let ((file (rata-claude-loop--get :file)))
    (if (and file (file-exists-p file))
        (buffer-local-value 'rata-claude-loop-verify-command
                            (rata-claude-loop--file-buffer file))
      rata-claude-loop-verify-command)))


;;; Stream rendering

(defconst rata-claude-loop--status-regexp
  "^[ \t]*RATA-TASK-STATUS:[ \t]*\\(done\\|blocked\\)\\(?:[ \t]*\\(?:--\\|—\\|:\\)?[ \t]*\\(.*\\)\\)?$"
  "Regexp matching the status line asked for by the prompt.")

(defun rata-claude-loop--truncate (string limit)
  "Return STRING collapsed to a single line and truncated to LIMIT chars."
  (let ((flat (replace-regexp-in-string "[ \t\n\r]+" " " (or string ""))))
    (if (> (length flat) limit)
        (concat (substring flat 0 limit) "…")
      flat)))

(defun rata-claude-loop--tail (string limit)
  "Return the last LIMIT characters of STRING, marked when truncated."
  (let ((string (or string "")))
    (if (<= (length string) limit)
        string
      (concat "…(earlier output truncated)…\n"
              (substring string (- (length string) limit))))))

(defun rata-claude-loop--tail-lines (string lines)
  "Return the last LINES lines of STRING, marked when truncated."
  (let* ((all (split-string (string-trim-right (or string "")) "\n"))
         (extra (- (length all) lines)))
    (if (<= extra 0)
        (string-join all "\n")
      (string-join (cons (format "…(%d earlier line%s omitted)…"
                                 extra (if (= extra 1) "" "s"))
                         (last all lines))
                   "\n"))))

(defun rata-claude-loop--format-seconds (seconds)
  "Return SECONDS rendered for a human."
  (format-seconds "%mm %ss" (or seconds 0)))

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

(defun rata-claude-loop--note-status (text)
  "Record a self-reported status line found in TEXT.
The last one in the stream wins, so a task that corrects itself is taken
at its final word."
  (let ((start 0))
    (while (string-match rata-claude-loop--status-regexp text start)
      (setq start (match-end 0))
      (rata-claude-loop--put :report
                             (intern (downcase (match-string 1 text))))
      (rata-claude-loop--put :report-reason
                             (let ((reason (string-trim
                                            (or (match-string 2 text) ""))))
                               (unless (string-empty-p reason) reason))))))

(defun rata-claude-loop--render-assistant (event)
  "Render an assistant EVENT's content blocks."
  (dolist (block (alist-get 'content (alist-get 'message event)))
    (pcase (alist-get 'type block)
      ("text"
       (let ((text (string-trim (or (alist-get 'text block) ""))))
         (rata-claude-loop--note-status text)
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
  "Render the terminating result EVENT and keep it for classification."
  (rata-claude-loop--put :result event)
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
       (let ((session (alist-get 'session_id event)))
         ;; Keep the whole id: it is what `--resume' needs for a retry, and
         ;; what `rata-claude-loop-open-session' hands to an interactive CLI.
         (when session
           (rata-claude-loop--put :session-id session))
         (rata-claude-loop--insert
          (format "  [%s · %s · %s]\n"
                  (or (alist-get 'model event) "?")
                  (or (alist-get 'permissionMode event) "?")
                  (rata-claude-loop--truncate (or session "") 8))
          'rata-claude-loop-meta-face))))
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

(defun rata-claude-loop--render-line (line)
  "Decode and render one output LINE."
  (condition-case nil
      (rata-claude-loop--render-event
       (json-parse-string line
                          :object-type 'alist
                          :array-type 'list
                          :null-object nil
                          :false-object nil))
    (error
     ;; Not JSON: most likely a warning on stdout.  Show it raw.
     (rata-claude-loop--insert
      (concat "  " (ansi-color-apply line) "\n")
      'rata-claude-loop-meta-face))))

(defun rata-claude-loop--consume (string &optional flush)
  "Render the newline-delimited JSON events in STRING.
A partial trailing line is held in `:pending' until the next call.  With
FLUSH non-nil what is held is treated as a complete final line: the CLI
does not have to terminate its last line with a newline, and that line is
the one carrying the `result' event."
  (let* ((pending (concat (or (rata-claude-loop--get :pending) "") string))
         (lines (split-string pending "\n")))
    (if flush
        (rata-claude-loop--put :pending "")
      (rata-claude-loop--put :pending (car (last lines)))
      (setq lines (butlast lines)))
    (dolist (line lines)
      (let ((trimmed (string-trim line)))
        (unless (string-empty-p trimmed)
          (rata-claude-loop--render-line trimmed))))))

(defun rata-claude-loop--consume-stderr (string &optional flush)
  "Render the child's stderr in STRING, one whole line at a time.
Buffering matters: stderr arrives in arbitrary chunks, and prefixing
each chunk would split one message across several marker lines."
  (let* ((pending (concat (or (rata-claude-loop--get :stderr-pending) "") string))
         (lines (split-string pending "\n")))
    (if flush
        (rata-claude-loop--put :stderr-pending "")
      (rata-claude-loop--put :stderr-pending (car (last lines)))
      (setq lines (butlast lines)))
    (dolist (line lines)
      (let ((trimmed (string-trim-right line)))
        (unless (string-empty-p (string-trim trimmed))
          (rata-claude-loop--insert
           (concat "  ! " (ansi-color-apply trimmed) "\n")
           'rata-claude-loop-error-face))))))

(defun rata-claude-loop--filter (epoch _process string)
  "Render STRING as stream-json output from the child of EPOCH."
  (when (rata-claude-loop--epoch-current-p epoch)
    (rata-claude-loop--guard
      (rata-claude-loop--consume string))))

(defun rata-claude-loop--stderr-process (epoch)
  "Return a process rendering the stderr of EPOCH's child into the buffer."
  (make-pipe-process
   :name "claude-loop-stderr"
   :buffer nil
   :noquery t
   :coding 'utf-8-unix
   :filter (lambda (_process string)
             (when (rata-claude-loop--epoch-current-p epoch)
               (rata-claude-loop--guard
                 (rata-claude-loop--consume-stderr string))))))


;;; Classification

(defun rata-claude-loop--subtype-kind (subtype)
  "Map a result SUBTYPE onto a failure kind."
  (pcase subtype
    ("error_max_turns" 'max-turns)
    ("error_max_budget_usd" 'budget)
    ("error_during_execution" 'execution)
    (_ 'crash)))

(defun rata-claude-loop--critical-denials ()
  "Return the names of denied tools that mean the task cannot have worked."
  (let ((denials (alist-get 'permission_denials (rata-claude-loop--get :result))))
    (delete-dups
     (delq nil
           (mapcar (lambda (denial)
                     (let ((name (alist-get 'tool_name denial)))
                       (and (member name rata-claude-loop-critical-denial-tools)
                            name)))
                   denials)))))

(defun rata-claude-loop--classify (code)
  "Return (KIND . REASON) for an attempt that exited with CODE, or nil.
nil means the attempt itself succeeded — which is not the same as the
task being done; that is what the verify command is for."
  (let* ((result (rata-claude-loop--get :result))
         (subtype (alist-get 'subtype result))
         (denials (rata-claude-loop--critical-denials))
         (report (rata-claude-loop--get :report))
         (reason (rata-claude-loop--get :report-reason)))
    (cond
     ;; A timer got here first; its verdict is the accurate one.
     ((rata-claude-loop--get :outcome))
     ((null result)
      (cons 'no-result
            (format "claude exited with code %s without reporting a result" code)))
     ((alist-get 'is_error result)
      (cons (rata-claude-loop--subtype-kind subtype)
            (format "claude reported an error (%s)" (or subtype "unknown"))))
     ((and subtype (not (equal subtype "success")))
      (cons (rata-claude-loop--subtype-kind subtype)
            (format "claude ended with subtype %s" subtype)))
     ((not (zerop code))
      (cons 'crash (format "claude exited with code %s" code)))
     (denials
      (cons 'denied
            (format "%s denied, so nothing can have been written: %s"
                    (if (cdr denials) "tools were" "a tool was")
                    (string-join denials ", "))))
     ((eq report 'blocked)
      (cons 'blocked (or reason "the task reported itself blocked")))
     ((and rata-claude-loop-require-status (null report))
      (cons 'blocked "the task reported no status line"))
     (t nil))))


;;; Git

(defun rata-claude-loop--git (&rest args)
  "Run git with ARGS in the loop's root; return trimmed output or nil."
  (let ((default-directory (rata-claude-loop--get :root)))
    (when (and (executable-find "git")
               (locate-dominating-file default-directory ".git"))
      (with-temp-buffer
        (when (zerop (apply #'process-file "git" nil t nil args))
          (string-trim (buffer-string)))))))

(defun rata-claude-loop--git-baseline ()
  "Return an object id capturing the working tree now, or nil.
`stash create' writes objects but touches neither the working tree nor
the stash list, so it is a read-only way to get a per-task baseline.
HEAD would not do: it folds in every earlier task's changes."
  (when (eq rata-claude-loop-git-checkpoint 'record)
    (let ((stash (rata-claude-loop--git "stash" "create")))
      (if (and stash (not (string-empty-p stash)))
          stash
        (rata-claude-loop--git "rev-parse" "HEAD")))))

(defun rata-claude-loop--report-diff ()
  "Render what the finished task changed.
Read-only: nothing is committed, stashed or reset."
  (when (eq rata-claude-loop-git-checkpoint 'record)
    (let* ((baseline (rata-claude-loop--get :baseline))
           (stat (and baseline (rata-claude-loop--git "diff" "--stat" baseline "--"))))
      (rata-claude-loop--insert
       (if (and stat (not (string-empty-p stat)))
           (concat "  ± " (rata-claude-loop--indent stat "  ± ") "\n")
         "  ± no tracked files changed\n")
       'rata-claude-loop-meta-face))))


;;; Running

(defun rata-claude-loop--common-args ()
  "Return the CLI arguments shared by a first attempt and a retry.
`--resume' does not inherit configuration from the original launch, so
every one of these has to be passed again on a retry."
  (append
   (list "--output-format" "stream-json" "--verbose")
   (when rata-claude-loop-partial-messages '("--include-partial-messages"))
   (when rata-claude-loop-model (list "--model" rata-claude-loop-model))
   (when rata-claude-loop-fallback-model
     (list "--fallback-model" rata-claude-loop-fallback-model))
   (when rata-claude-loop-max-turns
     (list "--max-turns" (number-to-string rata-claude-loop-max-turns)))
   (when rata-claude-loop-task-budget-usd
     (list "--max-budget-usd"
           (number-to-string rata-claude-loop-task-budget-usd)))
   rata-claude-loop-extra-args))

(defun rata-claude-loop--prompt (task file)
  "Return the prompt for TASK from FILE."
  (let ((name (file-name-nondirectory file)))
    (string-trim
     (concat (format rata-claude-loop-prompt-template name task name)
             "\n\n"
             rata-claude-loop-report-instruction))))

(defun rata-claude-loop--build-command (task file)
  "Return the argv list running TASK from FILE through the Claude CLI."
  (append (list rata-claude-loop-executable
                "-p" (rata-claude-loop--prompt task file))
          (rata-claude-loop--common-args)))

(defun rata-claude-loop--build-retry-command (reason feedback)
  "Return the argv list resuming this task's session to fix REASON.
FEEDBACK is captured output to hand back, or an empty string."
  (append (list rata-claude-loop-executable
                "-p" (format rata-claude-loop-retry-prompt-template
                             reason feedback)
                "--resume" (rata-claude-loop--get :session-id))
          (rata-claude-loop--common-args)))

(defun rata-claude-loop--kill-processes ()
  "Kill whatever the loop still has running.
Only the direct child is signalled; anything its Bash tool spawned is in
another process group and survives."
  (dolist (key '(:process :verify-process))
    (let ((process (rata-claude-loop--get key)))
      (rata-claude-loop--put key nil)
      (when (process-live-p process)
        (kill-process process)))))

(defun rata-claude-loop--halt (format-string &rest args)
  "Halt the loop, reporting FORMAT-STRING with ARGS."
  (rata-claude-loop--cancel-timers)
  (rata-claude-loop--kill-processes)
  (rata-claude-loop--bump-epoch)
  (rata-claude-loop--put :status 'halted)
  (rata-claude-loop--put :phase 'idle)
  (let ((message-text (apply #'format format-string args)))
    (rata-claude-loop--insert (format "\n■ halted: %s\n\n" message-text)
                              'rata-claude-loop-error-face)
    (message "claude-loop halted: %s" message-text))
  (display-buffer (rata-claude-loop--buffer)))

(defun rata-claude-loop--finish (message-text)
  "Finish the loop cleanly, reporting MESSAGE-TEXT."
  (rata-claude-loop--cancel-timers)
  (rata-claude-loop--put :status 'finished)
  (rata-claude-loop--put :phase 'done)
  (let ((index (or (rata-claude-loop--get :index) 0)))
    (rata-claude-loop--insert
     (format "\n■ %s (%d task%s run).\n\n"
             message-text index (if (= index 1) "" "s"))
     'rata-claude-loop-success-face))
  (message "claude-loop: %s" message-text))

(defun rata-claude-loop--terminate ()
  "Ask the live child to stop, escalating to SIGKILL after a grace period.
Unlike `rata-claude-loop-stop' this keeps the epoch, so the sentinel
still fires and the recorded outcome is what gets classified."
  (let ((process (or (rata-claude-loop--get :process)
                     (rata-claude-loop--get :verify-process)))
        (epoch (rata-claude-loop--get :epoch)))
    (when (process-live-p process)
      (interrupt-process process)
      (rata-claude-loop--put
       :kill-timer
       (run-at-time rata-claude-loop-kill-grace nil
                    (lambda ()
                      (when (and (rata-claude-loop--epoch-current-p epoch)
                                 (process-live-p process))
                        (kill-process process))))))))

(defun rata-claude-loop--arm-timeout (seconds kind reason)
  "Stop the current child after SECONDS, recording KIND and REASON."
  (when seconds
    (let ((epoch (rata-claude-loop--get :epoch)))
      (rata-claude-loop--put
       :timer
       (run-at-time seconds nil
                    (lambda ()
                      (when (rata-claude-loop--epoch-current-p epoch)
                        (rata-claude-loop--guard
                          (rata-claude-loop--set-outcome kind reason)
                          (rata-claude-loop--insert
                           (format "\n  ⏱ %s\n" reason)
                           'rata-claude-loop-error-face)
                          (rata-claude-loop--terminate)))))))))

(defun rata-claude-loop--sentinel (epoch process _event)
  "Hand the exit of EPOCH's child PROCESS to the dispatcher."
  (when (and (rata-claude-loop--epoch-current-p epoch)
             (memq (process-status process) '(exit signal)))
    (let ((code (process-exit-status process)))
      (rata-claude-loop--cancel-timer :timer)
      (rata-claude-loop--cancel-timer :kill-timer)
      (rata-claude-loop--put :process nil)
      (rata-claude-loop--later
       (lambda () (rata-claude-loop--after-claude code))))))

(defun rata-claude-loop--spawn (command)
  "Spawn COMMAND as the loop's child, entering the `claude' phase."
  (rata-claude-loop--bump-epoch)
  (rata-claude-loop--put :phase 'claude)
  (rata-claude-loop--put :status 'running)
  (dolist (key '(:pending :stderr-pending))
    (rata-claude-loop--put key ""))
  (dolist (key '(:result :report :report-reason :outcome :verify-output))
    (rata-claude-loop--put key nil))
  (let ((default-directory (rata-claude-loop--get :root))
        (epoch (rata-claude-loop--get :epoch)))
    ;; A spawn failure here would otherwise propagate out of the timer that
    ;; called us, where it would be reported but leave :status stuck at
    ;; `running' with nothing running.
    (condition-case err
        (let ((stderr (rata-claude-loop--stderr-process epoch)))
          (condition-case spawn-error
              (let ((process (make-process
                              :name "claude-loop"
                              :buffer nil
                              :command command
                              :connection-type 'pipe
                              :coding 'utf-8-unix
                              :noquery t
                              :stderr stderr
                              :filter (lambda (proc string)
                                        (rata-claude-loop--filter
                                         epoch proc string))
                              :sentinel (lambda (proc event)
                                          (rata-claude-loop--sentinel
                                           epoch proc event)))))
                (rata-claude-loop--put :process process)
                (rata-claude-loop--put :stderr stderr)
                ;; The prompt is passed via -p, so the child gets nothing on
                ;; stdin.  Close it immediately, or the CLI waits 3s for piped
                ;; input and warns about it on every single task.
                (process-send-eof process)
                (rata-claude-loop--arm-timeout
                 rata-claude-loop-task-timeout 'timeout
                 (format "attempt exceeded %s"
                         (rata-claude-loop--format-seconds
                          rata-claude-loop-task-timeout))))
            (error (delete-process stderr)
                   (signal (car spawn-error) (cdr spawn-error)))))
      (error
       (rata-claude-loop--put :process nil)
       (rata-claude-loop--halt "could not start %s: %s"
                               rata-claude-loop-executable
                               (error-message-string err))))))

(defun rata-claude-loop--run-task (line task)
  "Start the first attempt at TASK, found on LINE."
  (let* ((file (rata-claude-loop--get :file))
         (index (1+ (or (rata-claude-loop--get :index) 0)))
         (remaining (rata-claude-loop--count-open file)))
    (rata-claude-loop--put :index index)
    (rata-claude-loop--put :current-line line)
    (rata-claude-loop--put :current-task task)
    (rata-claude-loop--put :attempt 1)
    (rata-claude-loop--put :session-id nil)
    (rata-claude-loop--put :task-started (current-time))
    (rata-claude-loop--put :open-count remaining)
    (rata-claude-loop--put :baseline (rata-claude-loop--git-baseline))
    (rata-claude-loop--insert
     (format "\n%s\n▶ [%d/%d] %s\n\n"
             (make-string 60 ?─) index (+ index remaining -1) task)
     'rata-claude-loop-banner-face)
    (message "claude-loop [%d]: %s" index task)
    (rata-claude-loop--spawn (rata-claude-loop--build-command task file))))

(defun rata-claude-loop--feedback (kind)
  "Return captured output to hand back for a failure of KIND."
  (if (eq kind 'verify)
      (rata-claude-loop--tail (rata-claude-loop--get :verify-output)
                              rata-claude-loop-feedback-limit)
    ""))

(defun rata-claude-loop--start-retry (kind reason)
  "Resume this task's session and ask it to fix REASON, a failure of KIND."
  (let* ((attempt (1+ (or (rata-claude-loop--get :attempt) 1)))
         (delay (if (eq kind 'execution) rata-claude-loop-retry-backoff 0))
         (command (rata-claude-loop--build-retry-command
                   reason (rata-claude-loop--feedback kind))))
    (rata-claude-loop--put :attempt attempt)
    (rata-claude-loop--insert
     (format "\n  ↻ attempt %d/%d — resuming session %s\n\n"
             attempt rata-claude-loop-max-attempts
             (rata-claude-loop--truncate (rata-claude-loop--get :session-id) 8))
     'rata-claude-loop-meta-face)
    (if (zerop delay)
        (rata-claude-loop--spawn command)
      (rata-claude-loop--log "  … waiting %ds before retrying" delay)
      (let ((epoch (rata-claude-loop--get :epoch)))
        (rata-claude-loop--put
         :step-timer
         (run-at-time delay nil
                      (lambda ()
                        (when (rata-claude-loop--epoch-current-p epoch)
                          (rata-claude-loop--put :step-timer nil)
                          (rata-claude-loop--guard
                            (rata-claude-loop--spawn command))))))))))

(defun rata-claude-loop--fail (kind reason)
  "React to a failed attempt of KIND, explained by REASON."
  (let ((attempt (or (rata-claude-loop--get :attempt) 1)))
    (rata-claude-loop--insert (format "  ✗ %s\n" reason)
                              'rata-claude-loop-error-face)
    (cond
     ((not (memq kind rata-claude-loop-retry-on))
      (rata-claude-loop--halt "%s" reason))
     ((>= attempt rata-claude-loop-max-attempts)
      (rata-claude-loop--halt "%s (gave up after %d attempt%s)"
                              reason attempt (if (= attempt 1) "" "s")))
     ((null (rata-claude-loop--get :session-id))
      (rata-claude-loop--halt "%s (no session to resume)" reason))
     (t
      (rata-claude-loop--start-retry kind reason)))))

(defun rata-claude-loop--start-verify ()
  "Run the verify command asynchronously, entering the `verify' phase."
  (let ((command (rata-claude-loop--verify-command)))
    (rata-claude-loop--bump-epoch)
    (rata-claude-loop--put :phase 'verify)
    (rata-claude-loop--log "  … verifying: %s" command)
    (let* ((default-directory (rata-claude-loop--get :root))
           (buffer (generate-new-buffer " *claude-loop-verify*"))
           (epoch (rata-claude-loop--get :epoch)))
      (rata-claude-loop--put :verify-buffer buffer)
      (condition-case err
          (let ((process
                 (make-process
                  :name "claude-loop-verify"
                  :buffer buffer
                  :command (list shell-file-name shell-command-switch command)
                  :connection-type 'pipe
                  :coding 'utf-8-unix
                  :noquery t
                  :sentinel
                  (lambda (proc _event)
                    (when (and (rata-claude-loop--epoch-current-p epoch)
                               (memq (process-status proc) '(exit signal)))
                      (let ((code (process-exit-status proc)))
                        (rata-claude-loop--cancel-timer :timer)
                        (rata-claude-loop--cancel-timer :kill-timer)
                        (rata-claude-loop--put :verify-process nil)
                        (rata-claude-loop--later
                         (lambda ()
                           (rata-claude-loop--after-verify code)))))))))
            (rata-claude-loop--put :verify-process process)
            (rata-claude-loop--arm-timeout
             rata-claude-loop-verify-timeout 'timeout
             (format "verify exceeded %s"
                     (rata-claude-loop--format-seconds
                      rata-claude-loop-verify-timeout))))
        (error
         (rata-claude-loop--put :verify-process nil)
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (rata-claude-loop--halt "could not start the verify command: %s"
                                 (error-message-string err)))))))

(defun rata-claude-loop--after-claude (code)
  "Decide what an attempt that exited with CODE means, and move on."
  ;; The stderr pipe's filter fires after the main sentinel, so flush it here
  ;; rather than there; otherwise the last line lands under the next banner.
  (rata-claude-loop--consume-stderr "" t)
  (rata-claude-loop--consume "" t)
  (let ((outcome (rata-claude-loop--classify code)))
    (cond
     (outcome (rata-claude-loop--fail (car outcome) (cdr outcome)))
     (t
      (rata-claude-loop--report-diff)
      (if (rata-claude-loop--verify-command)
          (rata-claude-loop--start-verify)
        (rata-claude-loop--complete-task))))))

(defun rata-claude-loop--after-verify (code)
  "Decide what a verify run that exited with CODE means, and move on."
  (let* ((buffer (rata-claude-loop--get :verify-buffer))
         (output (and (buffer-live-p buffer)
                      (with-current-buffer buffer (buffer-string)))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    (rata-claude-loop--put :verify-buffer nil)
    (rata-claude-loop--put :verify-output output)
    (if (and (zerop code) (null (rata-claude-loop--get :outcome)))
        (progn
          (rata-claude-loop--insert "  ✓ verify passed\n"
                                    'rata-claude-loop-success-face)
          (rata-claude-loop--complete-task))
      (rata-claude-loop--insert
       (format "  ✗ verify failed (exit %s):\n%s\n" code
               (rata-claude-loop--tail-lines
                output rata-claude-loop-verify-output-lines))
       'rata-claude-loop-error-face)
      (let ((outcome (or (rata-claude-loop--get :outcome)
                         (cons 'verify
                               (format "verify command failed (exit %s)" code)))))
        (rata-claude-loop--fail (car outcome) (cdr outcome))))))

(defun rata-claude-loop--complete-task ()
  "Tick the finished task's box and move to the next one."
  (rata-claude-loop--put :phase 'mark)
  (let* ((file (rata-claude-loop--get :file))
         (line (rata-claude-loop--get :current-line))
         (task (rata-claude-loop--get :current-task)))
    (cond
     ((null (rata-claude-loop--mark-task file line task 'done))
      (rata-claude-loop--halt
       "refusing to tick a box: %S is no longer an unambiguous open task in %s"
       (rata-claude-loop--truncate task 50) (file-name-nondirectory file)))
     ((rata-claude-loop--get :single)
      (rata-claude-loop--finish "task done"))
     (t
      (rata-claude-loop--put :phase 'between)
      (rata-claude-loop--advance)))))

(defun rata-claude-loop--advance ()
  "Run the next open task, or finish the loop when none are left."
  (let* ((file (rata-claude-loop--get :file))
         (open (rata-claude-loop--count-open file))
         (previous (rata-claude-loop--get :open-count))
         (next (and (> open 0) (rata-claude-loop--next-task file))))
    (cond
     ((>= (or (rata-claude-loop--get :index) 0) rata-claude-loop-max-tasks)
      (rata-claude-loop--halt "hit `rata-claude-loop-max-tasks' (%d)"
                              rata-claude-loop-max-tasks))
     ((null next)
      (rata-claude-loop--finish
       (format "all tasks in %s are complete" (file-name-nondirectory file))))
     ;; The open count not dropping means the box never got ticked, and running
     ;; the same task again would spin forever.  Counting rather than comparing
     ;; task text keeps two identically-worded checklist items from tripping
     ;; this.
     ((and previous (>= open previous))
      (rata-claude-loop--halt
       "the open task count did not drop (%d); the checkbox was not updated"
       open))
     (t
      (rata-claude-loop--run-task (car next) (cdr next))))))


;;; Commands

(defun rata-claude-loop--offer-save (file)
  "Offer to save FILE's buffer when it has unsaved changes.
Claude reads the file from disk while the loop reads tasks from the
buffer, so an unsaved checklist means it is prompted with text it cannot
see."
  (let ((buffer (get-file-buffer file)))
    (when (and buffer (buffer-modified-p buffer))
      (when (y-or-n-p (format "Save %s before starting? "
                              (file-name-nondirectory file)))
        (with-current-buffer buffer (save-buffer))))))

(defun rata-claude-loop--begin (file root single)
  "Set up fresh loop state for FILE in ROOT and show the output buffer.
SINGLE means run one task only and stop."
  (unless (executable-find rata-claude-loop-executable)
    (user-error "Cannot find %s in `exec-path'" rata-claude-loop-executable))
  (setq rata-claude-loop--state
        (list :file file :root root :index 0 :epoch 0
              :status 'running :phase 'between
              :started (current-time) :pending "" :stderr-pending ""
              :single single))
  (with-current-buffer (rata-claude-loop--buffer)
    (let ((inhibit-read-only t)) (erase-buffer)))
  (display-buffer (rata-claude-loop--buffer)))

;;;###autoload
(defun rata-claude-loop-start (&optional ask)
  "Work through the open tasks in a checklist file with Claude Code.
With one prefix argument ASK, prompt for the task file.  With two,
also prompt for the directory Claude should run in."
  (interactive "P")
  (when (rata-claude-loop-running-p)
    (user-error "A claude-loop is already running; stop it first"))
  (unless (executable-find rata-claude-loop-executable)
    (user-error "Cannot find %s in `exec-path'" rata-claude-loop-executable))
  (let* ((file (rata-claude-loop--task-file ask))
         (root (if (equal ask '(16))
                   (read-directory-name
                    "Run Claude in: " (rata-claude-loop--project-root file) nil t)
                 (rata-claude-loop--project-root file)))
         (open (rata-claude-loop--count-open file)))
    (when (zerop open)
      (user-error "No open tasks in %s" file))
    (rata-claude-loop--offer-save file)
    (unless (y-or-n-p (format "Run Claude on %d task(s) from %s in %s? "
                              open (file-name-nondirectory file) root))
      (user-error "Aborted"))
    (rata-claude-loop--begin file root nil)
    (rata-claude-loop--guard (rata-claude-loop--advance))))

;;;###autoload
(defun rata-claude-loop-run-task-at-point ()
  "Run only the task on the current line through Claude Code."
  (interactive)
  (when (rata-claude-loop-running-p)
    (user-error "A claude-loop is already running; stop it first"))
  (unless (executable-find rata-claude-loop-executable)
    (user-error "Cannot find %s in `exec-path'" rata-claude-loop-executable))
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (let ((line (line-number-at-pos))
        (task (save-excursion
                (beginning-of-line)
                (cond
                 ((looking-at rata-claude-loop-task-regexp) (match-string 1))
                 ((and (derived-mode-p 'org-mode)
                       (looking-at rata-claude-loop-org-todo-regexp))
                  (match-string 1))
                 (t (user-error "No open task on this line"))))))
    (rata-claude-loop--offer-save buffer-file-name)
    (rata-claude-loop--begin buffer-file-name
                             (rata-claude-loop--project-root buffer-file-name)
                             t)
    (rata-claude-loop--guard
      (rata-claude-loop--run-task line (string-trim task)))))

;;;###autoload
(defun rata-claude-loop-stop ()
  "Stop the running loop, giving the child a chance to shut down cleanly."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop to stop"))
  (rata-claude-loop--cancel-timers)
  ;; Invalidate every outstanding callback before signalling, so the child's
  ;; dying output cannot advance the loop.
  (rata-claude-loop--bump-epoch)
  (rata-claude-loop--put :status 'halted)
  (rata-claude-loop--put :phase 'idle)
  (dolist (key '(:process :verify-process))
    (let ((process (rata-claude-loop--get key)))
      (rata-claude-loop--put key nil)
      (when (process-live-p process)
        ;; SIGINT first: SIGKILL gives the CLI no chance to flush or clean up.
        ;; Anything its Bash tool spawned is in another process group and
        ;; survives either way.
        (interrupt-process process)
        (run-at-time rata-claude-loop-kill-grace nil
                     (lambda ()
                       (when (process-live-p process)
                         (kill-process process)))))))
  (rata-claude-loop--insert "\n■ stopped by user.\n\n"
                            'rata-claude-loop-error-face)
  (message "claude-loop stopped"))

;;;###autoload
(defun rata-claude-loop-resume ()
  "Resume a halted loop from the next open task."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop to resume; use `rata-claude-loop-start'"))
  (when (rata-claude-loop--busy-p)
    (user-error "A process is still running; stop it first"))
  (when (and (rata-claude-loop-running-p)
             (not (rata-claude-loop--wedged-p)))
    (user-error "The loop is already running"))
  (rata-claude-loop--cancel-timers)
  (rata-claude-loop--bump-epoch)
  (rata-claude-loop--put :single nil)
  (rata-claude-loop--put :open-count nil)
  (rata-claude-loop--put :status 'running)
  (rata-claude-loop--put :phase 'between)
  (display-buffer (rata-claude-loop--buffer))
  (rata-claude-loop--guard (rata-claude-loop--advance)))

;;;###autoload
(defun rata-claude-loop-retry-task ()
  "Retry the current task by resuming the session that attempted it."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop in progress"))
  (when (rata-claude-loop--busy-p)
    (user-error "A process is still running; stop it first"))
  (unless (rata-claude-loop--get :session-id)
    (user-error "No session recorded for this task"))
  (rata-claude-loop--cancel-timers)
  ;; Reset the counter: a retry asked for by hand should not be refused
  ;; because the automatic ones are used up.
  (rata-claude-loop--put :attempt 0)
  (rata-claude-loop--put :status 'running)
  (display-buffer (rata-claude-loop--buffer))
  (rata-claude-loop--guard
    (rata-claude-loop--start-retry 'manual "retried by hand")))

;;;###autoload
(defun rata-claude-loop-open-session ()
  "Open an interactive Claude session resuming the current task's.
Lets you take over by hand from exactly where the loop got stuck,
instead of re-explaining the problem to a fresh context."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop in progress"))
  (let ((session (rata-claude-loop--get :session-id))
        (root (rata-claude-loop--get :root)))
    (unless session
      (user-error
       "No session recorded yet; `%s --resume' with no argument offers a picker"
       rata-claude-loop-executable))
    (let ((command (format "%s --resume %s" rata-claude-loop-executable session))
          (default-directory root))
      (if (require 'vterm nil t)
          (let ((buffer (vterm (format "*claude-loop %s*"
                                       (rata-claude-loop--truncate session 8)))))
            (with-current-buffer buffer
              (vterm-send-string (concat command "\n"))))
        (kill-new command)
        (message "No vterm; copied to the kill ring, run it in %s: %s"
                 root command)))))

;;;###autoload
(defun rata-claude-loop-skip ()
  "Mark the next open task as skipped and continue the loop."
  (interactive)
  (unless rata-claude-loop--state
    (user-error "No claude-loop in progress"))
  (when (rata-claude-loop--busy-p)
    (user-error "Stop the running task first"))
  (let* ((file (rata-claude-loop--get :file))
         (next (rata-claude-loop--next-task file)))
    (unless next
      (user-error "No open task to skip"))
    (unless (rata-claude-loop--mark-task file (car next) (cdr next) 'skipped)
      (user-error "Could not mark %S as skipped" (cdr next)))
    (rata-claude-loop--log "  ⊘ skipped: %s" (cdr next))
    (rata-claude-loop--cancel-timers)
    (rata-claude-loop--bump-epoch)
    (rata-claude-loop--put :open-count nil)
    (rata-claude-loop--put :status 'running)
    (rata-claude-loop--put :phase 'between)
    (rata-claude-loop--guard (rata-claude-loop--advance))))

;;;###autoload
(defun rata-claude-loop-status ()
  "Report the state of the loop in the echo area."
  (interactive)
  (if (null rata-claude-loop--state)
      (message "claude-loop: idle")
    (message "claude-loop: %s%s · %s · task %d attempt %d (%s) · %d open · %s elapsed"
             (rata-claude-loop--get :status)
             (let ((phase (rata-claude-loop--get :phase)))
               (cond ((rata-claude-loop--wedged-p) " [WEDGED]")
                     (phase (format "/%s" phase))
                     (t "")))
             (file-name-nondirectory (rata-claude-loop--get :file))
             (or (rata-claude-loop--get :index) 0)
             (or (rata-claude-loop--get :attempt) 0)
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

;; `rata-claude-loop-mode' derives from `special-mode', which is in none of
;; evil's state lists, so the buffer comes up in normal state -- where evil's
;; state maps live in `emulation-mode-map-alists' and outrank the major-mode
;; map.  Plain `define-key' bindings there are dead; `evil-define-key' installs
;; an auxiliary map that wins.  Keys are chosen not to shadow evil motions.
;; `evil-define-key*' rather than `evil-define-key': the latter is a macro, so
;; byte-compiling this file without evil loaded would emit a call to it as a
;; function and fail at runtime against a stale .elc.
(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-claude-loop-mode-map
    "q" #'quit-window
    (kbd "gr") #'rata-claude-loop-status
    (kbd "gt") #'rata-claude-loop-retry-task
    (kbd "go") #'rata-claude-loop-open-session
    (kbd "C-c C-k") #'rata-claude-loop-stop))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aicl"  '(:ignore t :which-key "task loop")
    "aicll" '(rata-claude-loop-start             :which-key "start loop")
    "aiclr" '(rata-claude-loop-run-task-at-point :which-key "run task at point")
    "aicls" '(rata-claude-loop-stop              :which-key "stop loop")
    "aicln" '(rata-claude-loop-skip              :which-key "skip current task")
    "aiclc" '(rata-claude-loop-resume            :which-key "resume after halt")
    "aiclt" '(rata-claude-loop-retry-task        :which-key "retry current task")
    "aiclo" '(rata-claude-loop-open-session      :which-key "take over session")
    "aiclb" '(rata-claude-loop-show-buffer       :which-key "show output")
    "aicl?" '(rata-claude-loop-status            :which-key "status")))

(provide 'init-claude-loop)
