;;; -*- lexical-binding: t; -*-
;;; init-claude-loop-acp.el --- agent-shell (ACP) backend for rata-claude-loop

;; Set `rata-claude-loop-backend' to `agent-shell' and each task runs in an
;; agent-shell buffer talking to Claude Code over ACP (claude-agent-acp),
;; instead of a headless `claude -p' process.  Everything else -- the task
;; scan, verify, retries, budgets, checkbox marking, the journal -- is the
;; shared state machine in `init-claude-loop.el'; this file only implements
;; the operations listed in `rata-claude-loop--backends'.
;;
;; What changes for the operator: each task is a real shell you can open and
;; read while it runs, and a retry is another prompt into the same live
;; session.  What must not change: autonomy.  A tool call that the session's
;; mode and `rata-claude-loop-allowed-tools' do not already allow reaches
;; `agent-shell-permission-responder-function', and for a loop-owned shell
;; this module answers `reject_once' -- selected by kind, never by id or
;; position, and never an allow option, because `allow_always' is written
;; into Claude's settings as a durable rule.  The denial is recorded in the
;; attempt record exactly as the CLI's `permission_denials' are, so it fails
;; the attempt the same way (FAIL-0010).  Requests from any other shell go to
;; whatever responder was installed before, or to agent-shell's own dialog.
;;
;; agent-shell is never loaded by this file: only by the backend's :check,
;; when a run actually asks for it.  Every agent-shell symbol is declared.
;; It does call the private `agent-shell--start', because the public
;; `agent-shell-start' displays the buffer and, under the default
;; `agent-shell-session-strategy', offers a session picker; the test suite
;; pins the keywords used.  Spike record: plans/claude-loop-agent-shell.md.
;;
;; Event handlers follow the core's discipline: they capture the attempt's
;; epoch and no-op on mismatch, they only record, and the transition runs
;; from `rata-claude-loop--later'.  An attempt completes once, whichever of
;; turn-complete, an error, or the shell dying gets there first.

(require 'init-claude-loop)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-interrupt "agent-shell" (&optional force))
(declare-function agent-shell-anthropic-make-claude-code-config
                  "agent-shell-anthropic")

(eval-when-compile
  (defvar agent-shell-permission-responder-function)
  (defvar agent-shell-anthropic-claude-acp-command)
  (defvar agent-shell-cwd-function)
  (defvar agent-shell--state))

(defcustom rata-claude-loop-acp-buffer-name "Claude loop"
  "Base name of the agent-shell buffers the loop starts, one per task."
  :type 'string
  :group 'rata-claude-loop)


;;; Pure helpers

(defun rata-claude-loop-acp--session-mode (extra-args)
  "Return the ACP session mode that EXTRA-ARGS asks for, or nil for none.
EXTRA-ARGS is `rata-claude-loop-extra-args', which is CLI argv.  The
only thing in it with an ACP meaning is `--permission-mode MODE'; anything
else would be silently dropped, so it is refused instead."
  (pcase extra-args
    ('nil nil)
    (`("--permission-mode" ,(and mode (pred stringp))) mode)
    (_ (user-error "The agent-shell backend cannot apply \
`rata-claude-loop-extra-args' %S; it understands only (\"--permission-mode\" \
MODE)" extra-args))))

(defun rata-claude-loop-acp--session-meta (base)
  "Return the session `_meta' for a loop shell, merged over BASE.
BASE is agent-shell's own `:session-meta' for Claude.  The loop's limits
go in `claudeCode.options', which claude-agent-acp spreads into the Agent
SDK options; the system-prompt append goes in top-level `systemPrompt',
because the adapter overrides an option of that name (spike Q4)."
  (let* ((claude (copy-alist (alist-get 'claudeCode base)))
         (ours (append
                (when rata-claude-loop-allowed-tools
                  (list (cons 'allowedTools
                              (vconcat rata-claude-loop-allowed-tools))))
                (when rata-claude-loop-max-turns
                  (list (cons 'maxTurns rata-claude-loop-max-turns)))
                (when rata-claude-loop-task-budget-usd
                  (list (cons 'maxBudgetUsd rata-claude-loop-task-budget-usd)))
                (when rata-claude-loop-model
                  (list (cons 'model rata-claude-loop-model)))
                (when rata-claude-loop-fallback-model
                  (list (cons 'fallbackModel rata-claude-loop-fallback-model)))))
         (options (append ours
                          (seq-remove (lambda (entry) (assq (car entry) ours))
                                      (alist-get 'options claude)))))
    (setf (alist-get 'options claude) options)
    (append (list (cons 'claudeCode claude))
            (when rata-claude-loop-append-system-prompt
              (list (cons 'systemPrompt
                          (list (cons 'append
                                      rata-claude-loop-append-system-prompt)))))
            (seq-remove (lambda (entry)
                          (memq (car entry) '(claudeCode systemPrompt)))
                        base))))

(defun rata-claude-loop-acp--tool-name (kind title)
  "Return the Claude Code tool name for an ACP tool call of KIND.
The core's denial lists (`rata-claude-loop-critical-denial-tools',
`rata-claude-loop-verification-denial-tools') speak Claude's tool names;
ACP reports a kind.  Falls back to TITLE, then \"?\"."
  (pcase kind
    ("execute" "Bash")
    ((or "edit" "delete" "move") "Edit")
    ("read" "Read")
    ("search" "Grep")
    ("fetch" "WebFetch")
    (_ (or title "?"))))

(defun rata-claude-loop-acp--denial (tool-call)
  "Return a denial alist, in the CLI's shape, for agent-shell's TOOL-CALL."
  (list (cons 'tool_name
              (rata-claude-loop-acp--tool-name (map-elt tool-call :kind)
                                               (map-elt tool-call :title)))
        (cons 'tool_input (map-elt tool-call :raw-input))))

(defun rata-claude-loop-acp--stop-record (stop-reason)
  "Return the attempt-record fields for a turn that ended with STOP-REASON.
The subtypes reuse the CLI's names where the meaning is the same, so
`rata-claude-loop--subtype-kind' and `rata-claude-loop-retry-on' apply
unchanged; the rest fall through to `crash'."
  (list :result-p t
        :subtype (pcase stop-reason
                   ("end_turn" "success")
                   ("max_turn_requests" "error_max_turns")
                   ((pred stringp) stop-reason)
                   (_ "unknown"))))

(defun rata-claude-loop-acp--pick-reject (options)
  "Return the option id in OPTIONS that rejects this one call, or nil."
  (map-elt (seq-find (lambda (option)
                       (equal (map-elt option :kind) "reject_once"))
                     options)
           :option-id))


;;; State

(defun rata-claude-loop-acp--buffer ()
  "Return the current task's shell buffer if it is still live."
  (let ((buffer (rata-claude-loop--get :acp-buffer)))
    (and (buffer-live-p buffer) buffer)))

(defun rata-claude-loop-acp--unsubscribe ()
  "Drop the current attempt's event subscription, if any."
  (let ((token (rata-claude-loop--get :acp-subscription))
        (buffer (rata-claude-loop-acp--buffer)))
    (rata-claude-loop--put :acp-subscription nil)
    (when (and token buffer)
      (ignore-errors (agent-shell-unsubscribe :subscription token)))))

(defun rata-claude-loop-acp--discard-shell ()
  "Kill the current task's shell, if there is one."
  (rata-claude-loop-acp--unsubscribe)
  (let ((buffer (rata-claude-loop-acp--buffer)))
    (rata-claude-loop--put :acp-buffer nil)
    (when buffer
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun rata-claude-loop-acp--interrupt ()
  "Cancel the current shell's turn, if it has a session to cancel."
  (let ((buffer (rata-claude-loop-acp--buffer)))
    (when buffer
      (with-current-buffer buffer
        (ignore-errors (agent-shell-interrupt t))))))


;;; Permissions

(defvar rata-claude-loop-acp--previous-responder nil
  "The responder that was installed before this module's, if any.")

(defun rata-claude-loop-acp--install-responder ()
  "Make sure this module's responder is the one agent-shell calls.
Checked at every attempt rather than once, so a responder set later by
something else is wrapped too instead of silently replacing the loop's
-- which, for a deny policy, would leave the loop's request waiting for a
human until the task timed out."
  (unless (eq agent-shell-permission-responder-function
              #'rata-claude-loop-acp--responder)
    (setq rata-claude-loop-acp--previous-responder
          agent-shell-permission-responder-function)
    (setq agent-shell-permission-responder-function
          #'rata-claude-loop-acp--responder)))

(defun rata-claude-loop-acp--responder (permission)
  "Answer PERMISSION for a loop shell; hand any other shell's on.
agent-shell calls this with the requesting shell's buffer current."
  (if (and (rata-claude-loop-running-p)
           (rata-claude-loop--get :acp-in-flight)
           (eq (current-buffer) (rata-claude-loop-acp--buffer)))
      (progn (rata-claude-loop-acp--deny permission) t)
    (and (functionp rata-claude-loop-acp--previous-responder)
         (funcall rata-claude-loop-acp--previous-responder permission))))

(defun rata-claude-loop-acp--deny (permission)
  "Reject PERMISSION once and record the denial for classification."
  (let* ((tool-call (map-elt permission :tool-call))
         (denial (rata-claude-loop-acp--denial tool-call))
         (option (rata-claude-loop-acp--pick-reject
                  (map-elt permission :options)))
         (pattern (rata-claude-loop--denial-pattern denial)))
    (rata-claude-loop--put :acp-denials
                           (cons denial (rata-claude-loop--get :acp-denials)))
    (rata-claude-loop--insert
     (format "  ! denied %s: %s\n" (alist-get 'tool_name denial)
             (rata-claude-loop--tool-argument (alist-get 'tool_input denial)))
     'rata-claude-loop-error-face)
    (when pattern
      (rata-claude-loop--insert (format "    allow with: %s\n" pattern)
                                'rata-claude-loop-meta-face))
    (if option
        (funcall (map-elt permission :respond) option)
      ;; Nothing that rejects only this call: refusing by cancelling the
      ;; whole turn is the one answer that grants nothing.
      (rata-claude-loop--insert "    no reject option offered; cancelling the turn\n"
                                'rata-claude-loop-error-face)
      (rata-claude-loop-acp--interrupt))))


;;; Events

(defun rata-claude-loop-acp--complete (record)
  "Finish the current attempt with RECORD; only the first call counts."
  (unless (rata-claude-loop--get :acp-done)
    (rata-claude-loop--put :acp-done t)
    (rata-claude-loop--put :acp-in-flight nil)
    (rata-claude-loop--cancel-timer :timer)
    (rata-claude-loop--cancel-timer :kill-timer)
    (rata-claude-loop-acp--unsubscribe)
    (let ((text (string-trim (rata-claude-loop--get :acp-text))))
      (rata-claude-loop--note-status text)
      (unless (string-empty-p text)
        (rata-claude-loop--insert
         (concat "  ● " (rata-claude-loop--indent text "  ● ") "\n")
         'rata-claude-loop-text-face)))
    (rata-claude-loop--put
     :acp-record
     (append record
             (list :exit-code nil
                   :denials (reverse (rata-claude-loop--get :acp-denials)))))
    (let* ((reading (plist-get record :cost))
           (mark (or (rata-claude-loop--get :acp-cost-mark) 0))
           ;; The reading is the session's running total (spike Q2), so this
           ;; attempt is what it added; a retry reuses the session.
           (spent (if (numberp reading) (max 0 (- reading mark)) 0))
           (ok (equal (plist-get record :subtype) "success")))
      (when (numberp reading)
        (rata-claude-loop--put :acp-cost-mark reading))
      (when (> spent 0)
        (rata-claude-loop--add-cost spent))
      (rata-claude-loop--insert
       (format "\n  %s %s · %.0fs · $%.2f%s\n"
               (if ok "✓" "✗")
               (or (plist-get record :subtype) (plist-get record :detail) "")
               (float-time (time-since (rata-claude-loop--get :acp-started)))
               spent
               (let ((total (rata-claude-loop--get :cost)))
                 (if (and (numberp total) (> total 0))
                     (format " · $%.2f this run" total)
                   "")))
       (if ok 'rata-claude-loop-success-face 'rata-claude-loop-error-face)))
    (rata-claude-loop--later (lambda () (rata-claude-loop--after-claude nil)))))

(defun rata-claude-loop-acp--note-session (buffer)
  "Record BUFFER's session id once it has one."
  (let ((id (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                            '(:session :id))))
    (when (and id (not (equal id (rata-claude-loop--get :session-id))))
      (rata-claude-loop--put :session-id id)
      (rata-claude-loop--insert
       (format "  [agent-shell · %s · %s]\n"
               (or (rata-claude-loop-acp--session-mode rata-claude-loop-extra-args)
                   "default mode")
               (rata-claude-loop--truncate id 8))
       'rata-claude-loop-meta-face))))

(defun rata-claude-loop-acp--send-pending ()
  "Send the attempt's prompt if the shell is ready and it is still unsent."
  (let ((prompt (rata-claude-loop--get :acp-pending-prompt))
        (buffer (rata-claude-loop-acp--buffer)))
    (when (and prompt buffer (rata-claude-loop--get :acp-ready))
      (rata-claude-loop--put :acp-pending-prompt nil)
      (agent-shell-insert :text prompt :submit t :no-focus t
                          :shell-buffer buffer))))

(defun rata-claude-loop-acp--on-tool (data)
  "Render a finished tool call from DATA, once per call."
  (let* ((id (map-elt data :tool-call-id))
         (tool-call (map-elt data :tool-call))
         (status (map-elt tool-call :status)))
    (when (and (member status '("completed" "failed"))
               (not (member id (rata-claude-loop--get :acp-seen))))
      (rata-claude-loop--put :acp-seen (cons id (rata-claude-loop--get :acp-seen)))
      (rata-claude-loop--insert
       (format "  %s %-10s %s\n" (if (equal status "failed") "✗" "⚙")
               (rata-claude-loop-acp--tool-name (map-elt tool-call :kind) nil)
               (rata-claude-loop--truncate (or (map-elt tool-call :title) "") 100))
       (if (equal status "failed")
           'rata-claude-loop-error-face
         'rata-claude-loop-tool-face)))))

(defun rata-claude-loop-acp--on-event (buffer event)
  "Record what EVENT from BUFFER means for the current attempt."
  (let ((data (map-elt event :data))
        (in-flight (rata-claude-loop--get :acp-in-flight)))
    (pcase (map-elt event :event)
      ((or 'init-session 'session-selected 'init-finished)
       (rata-claude-loop-acp--note-session buffer))
      ('prompt-ready
       (rata-claude-loop-acp--note-session buffer)
       (rata-claude-loop--put :acp-ready t)
       (rata-claude-loop-acp--send-pending))
      ('agent-message-chunk
       (when-let* ((chunk (map-elt data :text-chunk)))
         (rata-claude-loop--put :acp-text
                                (concat (rata-claude-loop--get :acp-text) chunk))))
      ('tool-call-update (rata-claude-loop-acp--on-tool data))
      ('turn-complete
       (when in-flight
         (rata-claude-loop-acp--complete
          (append (rata-claude-loop-acp--stop-record (map-elt data :stop-reason))
                  (list :cost (map-nested-elt data '(:usage :cost-amount)))))))
      ('error
       (when in-flight
         (rata-claude-loop-acp--complete
          (list :result-p t :is-error t
                :detail (format "%s (code %s)"
                                (or (map-elt data :message) "ACP request failed")
                                (map-elt data :code))))))
      ('clean-up
       (rata-claude-loop--put :acp-buffer nil)
       (when in-flight
         (rata-claude-loop-acp--complete
          (list :result-p nil
                :detail "the agent shell went away before the turn finished")))))))

(defun rata-claude-loop-acp--subscribe (buffer)
  "Subscribe to BUFFER's events for the current attempt only."
  (let ((epoch (rata-claude-loop--get :epoch)))
    (rata-claude-loop--put
     :acp-subscription
     (agent-shell-subscribe-to
      :shell-buffer buffer
      :on-event
      (lambda (event)
        (when (rata-claude-loop--epoch-current-p epoch)
          ;; agent-shell demotes a subscriber's error to a message; here it
          ;; ends the attempt visibly instead.
          (condition-case err
              (rata-claude-loop-acp--on-event buffer event)
            (error
             (rata-claude-loop-acp--complete
              (list :result-p nil
                    :detail (format "agent-shell event handler failed: %s"
                                    (error-message-string err))))))))))))


;;; Operations

(defun rata-claude-loop-acp--config ()
  "Return the agent-shell config a loop shell is started with."
  (let ((config (agent-shell-anthropic-make-claude-code-config))
        (mode (rata-claude-loop-acp--session-mode rata-claude-loop-extra-args)))
    (setf (map-elt config :session-meta)
          (rata-claude-loop-acp--session-meta (map-elt config :session-meta)))
    (setf (map-elt config :default-session-mode-id) (lambda () mode))
    (when rata-claude-loop-model
      (setf (map-elt config :default-model-id)
            (lambda () rata-claude-loop-model)))
    (setf (map-elt config :buffer-name) rata-claude-loop-acp-buffer-name)
    config))

(defun rata-claude-loop-acp--open-shell (session-id)
  "Start a loop shell in the run's root, resuming SESSION-ID when non-nil."
  (let* ((root (file-name-as-directory (rata-claude-loop--get :root)))
         (cwd (lambda () root))
         (default-directory root)
         ;; Bound for the synchronous part of the start; set buffer-locally
         ;; below for `session/new', which runs after the handshake (Q6).
         (agent-shell-cwd-function cwd)
         (buffer (agent-shell--start :config (rata-claude-loop-acp--config)
                                     :no-focus t
                                     :new-session t
                                     :session-strategy 'new
                                     :session-id session-id)))
    (with-current-buffer buffer
      (setq-local agent-shell-cwd-function cwd))
    (rata-claude-loop--put :acp-buffer buffer)
    (rata-claude-loop--put :acp-ready nil)
    (rata-claude-loop--put :acp-cost-mark 0)
    buffer))

(defun rata-claude-loop-acp--begin-attempt (prompt fresh)
  "Send PROMPT as a new attempt; FRESH means a new task, so a new shell."
  (rata-claude-loop--attempt-begin)
  (rata-claude-loop-acp--install-responder)
  (when fresh
    (rata-claude-loop-acp--discard-shell))
  (rata-claude-loop-acp--unsubscribe)
  (dolist (key '(:acp-denials :acp-record :acp-done :acp-seen))
    (rata-claude-loop--put key nil))
  (rata-claude-loop--put :acp-text "")
  (rata-claude-loop--put :acp-started (current-time))
  (rata-claude-loop--put :acp-in-flight t)
  (condition-case err
      (let ((buffer (or (rata-claude-loop-acp--buffer)
                        (rata-claude-loop-acp--open-shell
                         (unless fresh (rata-claude-loop--get :session-id))))))
        (rata-claude-loop-acp--subscribe buffer)
        (rata-claude-loop--put :acp-pending-prompt prompt)
        (rata-claude-loop-acp--send-pending)
        (rata-claude-loop--arm-timeout
         rata-claude-loop-task-timeout 'timeout
         (format "attempt exceeded %s"
                 (rata-claude-loop--format-seconds
                  rata-claude-loop-task-timeout))))
    (error
     (rata-claude-loop--put :acp-in-flight nil)
     (rata-claude-loop--halt "could not start an agent-shell session: %s"
                             (error-message-string err)))))

(defun rata-claude-loop-acp--check ()
  "Signal a `user-error' unless agent-shell and the Claude adapter are here."
  (unless (and (require 'agent-shell nil t)
               (require 'agent-shell-anthropic nil t))
    (user-error "The agent-shell backend needs the agent-shell package"))
  (let ((command (car agent-shell-anthropic-claude-acp-command)))
    (unless (and command (executable-find command))
      (user-error "Cannot find %s in `exec-path' (see \
`agent-shell-anthropic-claude-acp-command')" command)))
  (rata-claude-loop-acp--session-mode rata-claude-loop-extra-args))

(defun rata-claude-loop-acp--start (task file body)
  "Run a first attempt at TASK from FILE, with detail BODY, in a new shell."
  (rata-claude-loop-acp--begin-attempt
   (rata-claude-loop--prompt task file body) t))

(defun rata-claude-loop-acp--retry (reason feedback)
  "Ask the task's own session to fix REASON, handing back FEEDBACK."
  (rata-claude-loop-acp--begin-attempt
   (format rata-claude-loop-retry-prompt-template reason feedback) nil))

(defun rata-claude-loop-acp--attempt (_code)
  "Return the record the current attempt completed with."
  (rata-claude-loop--get :acp-record))

(defun rata-claude-loop-acp--live-p ()
  "Return non-nil while an attempt is in flight."
  (rata-claude-loop--get :acp-in-flight))

(defun rata-claude-loop-acp--stop (still-wanted detach)
  "Cancel the turn; kill the shell after the grace period if STILL-WANTED.
With DETACH (the operator's stop) the shell is kept for reading."
  (rata-claude-loop-acp--interrupt)
  (if detach
      (progn (rata-claude-loop--put :acp-in-flight nil)
             (rata-claude-loop-acp--unsubscribe)
             nil)
    (let ((buffer (rata-claude-loop-acp--buffer)))
      (run-at-time rata-claude-loop-kill-grace nil
                   (lambda ()
                     (when (and (funcall still-wanted)
                                (rata-claude-loop--get :acp-in-flight)
                                (buffer-live-p buffer))
                       ;; Its `clean-up' event completes the attempt.
                       (let ((kill-buffer-query-functions nil))
                         (kill-buffer buffer))))))))

(defun rata-claude-loop-acp--kill ()
  "End the attempt now, keeping the shell for reading."
  (when (rata-claude-loop--get :acp-in-flight)
    (rata-claude-loop-acp--interrupt))
  (rata-claude-loop--put :acp-in-flight nil)
  (rata-claude-loop-acp--unsubscribe))

(defun rata-claude-loop-acp--teardown (status)
  "Close the last shell after a finished run; keep it after a halt.
STATUS is `finished' or `halted'.  A halted run's shell is the place to
read what went wrong, and to carry on by hand."
  (let ((buffer (rata-claude-loop-acp--buffer)))
    (when buffer
      (if (eq status 'finished)
          (rata-claude-loop-acp--discard-shell)
        (rata-claude-loop--log "  shell kept for reading: %s" (buffer-name buffer))))))

(setf (alist-get 'agent-shell rata-claude-loop--backends)
      (list :check #'rata-claude-loop-acp--check
            :start #'rata-claude-loop-acp--start
            :retry #'rata-claude-loop-acp--retry
            :attempt #'rata-claude-loop-acp--attempt
            :live-p #'rata-claude-loop-acp--live-p
            :stop #'rata-claude-loop-acp--stop
            :kill #'rata-claude-loop-acp--kill
            :teardown #'rata-claude-loop-acp--teardown))

(provide 'init-claude-loop-acp)
;;; init-claude-loop-acp.el ends here
