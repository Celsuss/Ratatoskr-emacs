;;; -*- lexical-binding: t; -*-
;;; tests/claude-loop-acp-e2e.el --- The agent-shell backend, end to end
;;
;; Drives the real claude-loop state machine through the real agent-shell
;; and acp.el, against tests/fake-claude-acp -- a scripted ACP agent that
;; logs every message it receives.  No API calls, no network, no money.
;;
;; Needs agent-shell, acp and shell-maker, taken from elpaca/builds/, so it
;; is not part of `are-verify fast' (which loads no packages).  Run it with:
;;
;;   just test-claude-loop-acp
;;
;; What it cannot prove: that claude-agent-acp itself behaves like the stub.
;; The stub's message shapes were taken from the live spike recorded in
;; plans/claude-loop-agent-shell.md, Phase 0.

(let ((root (or (getenv "RATA_ROOT") default-directory)))
  (add-to-list 'load-path (expand-file-name "lisp" root))
  (dolist (package '("agent-shell" "acp" "shell-maker"))
    (add-to-list 'load-path (expand-file-name (concat "elpaca/builds/" package)
                                              root))))
(require 'json)
(require 'init-claude-loop)
(require 'init-claude-loop-acp)
(require 'agent-shell)
(require 'agent-shell-anthropic)

(defvar rata-acp--failures 0)
(defvar rata-acp--dir (make-temp-file "claude-loop-acp-e2e" t))
(defvar rata-acp--log (expand-file-name "wire.jsonl" rata-acp--dir))
(defvar rata-acp--script (expand-file-name "script.json" rata-acp--dir))

(defun rata-acp--check (label got expected)
  "Report whether GOT equals EXPECTED for LABEL."
  (if (equal got expected)
      (message "ok   %s" label)
    (setq rata-acp--failures (1+ rata-acp--failures))
    (message "FAIL %s\n  got:      %S\n  expected: %S" label got expected)))

;;; ------------------------------------------------------------------
;;; Harness
;;; ------------------------------------------------------------------

(setq rata-claude-loop-backend 'agent-shell
      agent-shell-anthropic-claude-acp-command
      (list (expand-file-name "tests/fake-claude-acp"
                              (or (getenv "RATA_ROOT") default-directory)))
      rata-claude-loop-task-timeout nil
      rata-claude-loop-verify-timeout nil
      rata-claude-loop-verify-command nil
      rata-claude-loop-verify-baseline nil
      rata-claude-loop-kill-grace 1
      rata-claude-loop-max-attempts 2
      rata-claude-loop-journal-directory (expand-file-name "journal" rata-acp--dir))
(setenv "FAKE_ACP_LOG" rata-acp--log)
(setenv "FAKE_ACP_SCRIPT" rata-acp--script)

(defun rata-acp--script (&rest turns)
  "Script the stub: one plist per prompt turn, see tests/fake-claude-acp."
  (with-temp-file rata-acp--script
    (insert (json-encode (mapcar (lambda (turn)
                                   (let (alist)
                                     (while turn
                                       (push (cons (substring (symbol-name (pop turn)) 1)
                                                   (pop turn))
                                             alist))
                                     (nreverse alist)))
                                 turns))))
  (ignore-errors (delete-file rata-acp--log)))

(defun rata-acp--wire (&optional method)
  "Return the messages the stub received, oldest first, or only METHOD's."
  (when (file-exists-p rata-acp--log)
    (with-temp-buffer
      (insert-file-contents rata-acp--log)
      (seq-filter (lambda (message)
                    (or (null method) (equal (alist-get 'method message) method)))
                  (mapcar (lambda (line) (json-read-from-string line))
                          (split-string (buffer-string) "\n" t))))))

(defun rata-acp--responses ()
  "Return the permission answers the client sent, as option ids."
  (delq nil (mapcar (lambda (message)
                      (and (null (alist-get 'method message))
                           (let-alist message .result.outcome.optionId)))
                    (rata-acp--wire))))

(defun rata-acp--wait (&optional limit)
  "Pump timers and process output until the loop stops running."
  (let ((deadline (+ (float-time) (or limit 30))))
    (while (and (rata-claude-loop-running-p) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (sit-for 0.01)))
  (rata-claude-loop--get :status))

(defun rata-acp--settle (seconds)
  "Keep pumping events for SECONDS, whatever the loop's state."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05)
      (sit-for 0.01))))

(defun rata-acp--tasks (content)
  "Write CONTENT to a fresh tasks.md and return its path."
  (let ((file (expand-file-name "tasks.md" (make-temp-file "acp-case" t))))
    (with-temp-file file (insert content))
    file))

(defun rata-acp--run (file)
  "Run the loop over FILE and return its final status."
  (rata-claude-loop--backend-call :check)
  (rata-claude-loop--begin file (file-name-directory file) nil)
  (rata-claude-loop--advance)
  (rata-acp--wait))

(defun rata-acp--contents (file)
  "Return FILE's contents, freshly read from disk."
  (with-current-buffer (find-file-noselect file)
    (revert-buffer t t t)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun rata-acp--output ()
  "Return the loop buffer's text."
  (with-current-buffer (rata-claude-loop--buffer) (buffer-string)))

(defun rata-acp--reset ()
  "Close every loop shell left by the previous case."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p rata-claude-loop-acp-buffer-name (buffer-name buffer))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))))
  (rata-acp--settle 0.3))

(defun rata-acp--loop-shells ()
  "Return the live loop shell buffers."
  (seq-filter (lambda (buffer)
                (string-prefix-p rata-claude-loop-acp-buffer-name (buffer-name buffer)))
              (buffer-list)))

;;; ------------------------------------------------------------------
;;; 1. Happy path, and what reaches the wire
;;; ------------------------------------------------------------------

(rata-acp--script '(:text "did it\nRATA-TASK-STATUS: done" :cost 0.10))
(let* ((rata-claude-loop-allowed-tools '("Bash(just:*)"))
       (rata-claude-loop-max-turns 12)
       (rata-claude-loop-append-system-prompt "be brief")
       (file (rata-acp--tasks "- [ ] alpha\n- [ ] beta\n"))
       (root (file-name-directory file))
       (status (rata-acp--run file)))
  (rata-acp--check "happy: finished" status 'finished)
  (rata-acp--check "happy: both boxes ticked" (rata-acp--contents file)
                   "- [X] alpha\n- [X] beta\n")
  (let ((news (rata-acp--wire "session/new")))
    (rata-acp--check "happy: one session per task" (length news) 2)
    (let-alist (alist-get 'params (car news))
      (rata-acp--check "happy: session runs in the run's root"
                       (file-name-as-directory .cwd) root)
      (rata-acp--check "happy: allowedTools reach the SDK options"
                       .\_meta.claudeCode.options.allowedTools ["Bash(just:*)"])
      (rata-acp--check "happy: maxTurns reaches the SDK options"
                       .\_meta.claudeCode.options.maxTurns 12)
      (rata-acp--check "happy: agent-shell's own options survive the merge"
                       .\_meta.claudeCode.options.thinking.display "summarized")
      (rata-acp--check "happy: the append goes in top-level systemPrompt"
                       .\_meta.systemPrompt.append "be brief")))
  (rata-acp--check "happy: acceptEdits mode requested"
                   (and (seq-find (lambda (m) (equal (let-alist m .params.modeId)
                                                     "acceptEdits"))
                                  (rata-acp--wire "session/set_mode"))
                        t)
                   t)
  (rata-acp--check "happy: the prompt names the task"
                   (and (string-match-p
                         "alpha"
                         (let-alist (car (rata-acp--wire "session/prompt"))
                           (alist-get 'text (aref .params.prompt 0))))
                        t)
                   t)
  (rata-acp--check "happy: costs from two sessions add up" (rata-claude-loop--get :cost)
                   0.2)
  (rata-acp--check "happy: a finished run closes its shell" (rata-acp--loop-shells) nil)
  (rata-acp--check "happy: session id journalled"
                   (rata-claude-loop--get :session-id) "fake-acp-session"))
(rata-acp--reset)

;;; ------------------------------------------------------------------
;;; 2. A denied command fails the attempt; the retry is the same session
;;; ------------------------------------------------------------------

(rata-acp--script
 '(:text "RATA-TASK-STATUS: done" :cost 0.10
   :tools [(:title "python3 hello.py" :kind "execute" :command "python3 hello.py"
            :permission t)])
 '(:text "RATA-TASK-STATUS: done" :cost 0.30))
(let* ((file (rata-acp--tasks "- [ ] gamma\n"))
       (status (rata-acp--run file)))
  (rata-acp--check "denied: finished after the retry" status 'finished)
  (rata-acp--check "denied: box ticked" (rata-acp--contents file) "- [X] gamma\n")
  (rata-acp--check "denied: the responder only ever rejected"
                   (rata-acp--responses) '("reject"))
  (rata-acp--check "denied: retry stayed in the session (one session/new)"
                   (length (rata-acp--wire "session/new")) 1)
  (let ((prompts (rata-acp--wire "session/prompt")))
    (rata-acp--check "denied: two prompts" (length prompts) 2)
    (rata-acp--check "denied: the retry names the pattern to allow"
                     (and (string-match-p
                           "Bash(python3:\\*)"
                           (let-alist (cadr prompts)
                             (alist-get 'text (aref .params.prompt 0))))
                          t)
                     t))
  (rata-acp--check "denied: the buffer printed the allow hint"
                   (and (string-match-p "allow with: Bash(python3:\\*)" (rata-acp--output)) t)
                   t)
  (rata-acp--check "denied: cost is the session total, not the sum of readings"
                   (rata-claude-loop--get :cost) 0.3))
(rata-acp--reset)

;;; ------------------------------------------------------------------
;;; 3. A denied edit is `denied', and is not retried
;;; ------------------------------------------------------------------

(rata-acp--script
 '(:text "RATA-TASK-STATUS: done"
   :tools [(:title "Write notes.md" :kind "edit" :command "" :permission t)]))
(let* ((file (rata-acp--tasks "- [ ] delta\n"))
       (status (rata-acp--run file)))
  (rata-acp--check "edit: halted" status 'halted)
  (rata-acp--check "edit: box open" (rata-acp--contents file) "- [ ] delta\n")
  (rata-acp--check "edit: kind denied, one attempt"
                   (and (string-match-p "nothing can have been written: Edit"
                                        (rata-acp--output))
                        (= 1 (length (rata-acp--wire "session/prompt"))))
                   t)
  (rata-acp--check "edit: a halted run keeps its shell for reading"
                   (length (rata-acp--loop-shells)) 1))
(rata-acp--reset)

;;; ------------------------------------------------------------------
;;; 4. Stop reasons and errors map onto the CLI's failure kinds
;;; ------------------------------------------------------------------

(let ((rata-claude-loop-max-attempts 1))
  (rata-acp--script '(:stop "max_turn_requests"))
  (let ((file (rata-acp--tasks "- [ ] epsilon\n")))
    (rata-acp--check "max-turns: halted" (rata-acp--run file) 'halted)
    (rata-acp--check "max-turns: named as the CLI names it"
                     (and (string-match-p "subtype error_max_turns" (rata-acp--output)) t)
                     t))
  (rata-acp--reset)
  (rata-acp--script '(:error t))
  (let ((file (rata-acp--tasks "- [ ] zeta\n")))
    (rata-acp--check "rpc error: halted" (rata-acp--run file) 'halted)
    (rata-acp--check "rpc error: the agent's message is the reason"
                     (and (string-match-p "reported an error (scripted failure"
                                          (rata-acp--output))
                          t)
                     t)
    (rata-acp--check "rpc error: box open" (rata-acp--contents file) "- [ ] zeta\n"))
  (rata-acp--reset))

;;; ------------------------------------------------------------------
;;; 5. The agent dies mid-turn; a hung turn times out
;;; ------------------------------------------------------------------

(let ((rata-claude-loop-max-attempts 1)
      (rata-claude-loop-task-timeout 3))
  (rata-acp--script '(:exit t))
  (let* ((file (rata-acp--tasks "- [ ] eta\n"))
         (status (rata-acp--run file)))
    (rata-acp--check "agent exit: the run does not hang" status 'halted)
    (rata-acp--check "agent exit: box open" (rata-acp--contents file) "- [ ] eta\n")
    (rata-acp--check "agent exit: nothing left in flight"
                     (rata-claude-loop--get :acp-in-flight) nil))
  (rata-acp--reset)
  (rata-acp--script '(:hang t))
  (let* ((file (rata-acp--tasks "- [ ] theta\n"))
         (status (rata-acp--run file)))
    (rata-acp--check "timeout: halted" status 'halted)
    (rata-acp--check "timeout: the verdict is the timeout"
                     (and (string-match-p "attempt exceeded" (rata-acp--output)) t) t)
    (rata-acp--check "timeout: the turn was cancelled on the wire"
                     (length (rata-acp--wire "session/cancel")) 1)
    (rata-acp--check "timeout: nothing left in flight"
                     (rata-claude-loop--get :acp-in-flight) nil))
  (rata-acp--reset))

;;; ------------------------------------------------------------------
;;; 6. After the operator's stop, a late answer moves nothing
;;; ------------------------------------------------------------------

(rata-acp--script '(:hang t))
(let ((file (rata-acp--tasks "- [ ] iota\n")))
  (rata-claude-loop--backend-call :check)
  (rata-claude-loop--begin file (file-name-directory file) nil)
  (rata-claude-loop--advance)
  (rata-acp--settle 1.5)
  (rata-claude-loop-stop)
  ;; The stub now answers the cancelled prompt; it must change nothing.
  (rata-acp--settle 1.5)
  (rata-acp--check "stop: halted" (rata-claude-loop--get :status) 'halted)
  (rata-acp--check "stop: box open" (rata-acp--contents file) "- [ ] iota\n")
  (rata-acp--check "stop: no retry was started"
                   (length (rata-acp--wire "session/prompt")) 1)
  (rata-acp--check "stop: the shell is kept" (length (rata-acp--loop-shells)) 1))
(rata-acp--reset)

;;; ------------------------------------------------------------------
;;; 7. Requests from shells the loop does not own are handed on
;;; ------------------------------------------------------------------

(let ((rata-claude-loop-acp--previous-responder (lambda (_p) 'theirs)))
  (with-temp-buffer
    (rata-acp--check "responder: another shell's request goes to the previous responder"
                     (rata-claude-loop-acp--responder '((:options))) 'theirs)))
(let ((rata-claude-loop-acp--previous-responder nil))
  (with-temp-buffer
    (rata-acp--check "responder: with none before, agent-shell's own dialog decides"
                     (rata-claude-loop-acp--responder '((:options))) nil)))

;;; ------------------------------------------------------------------
;;; 8. CLI-only arguments are refused, not silently dropped
;;; ------------------------------------------------------------------

(let ((rata-claude-loop-extra-args '("--permission-mode" "acceptEdits" "--verbose")))
  (rata-acp--check "extra-args: refused at check"
                   (condition-case nil
                       (progn (rata-claude-loop--backend-call :check) 'accepted)
                     (user-error 'refused))
                   'refused))

;;; ------------------------------------------------------------------

(rata-acp--reset)
(delete-directory rata-acp--dir t)
(message "\n==== claude-loop acp e2e: %s ===="
         (if (zerop rata-acp--failures)
             "ALL PASSED"
           (format "%d FAILURE(S)" rata-acp--failures)))
(kill-emacs (if (zerop rata-acp--failures) 0 1))
