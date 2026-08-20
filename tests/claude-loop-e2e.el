;;; -*- lexical-binding: t; -*-
;;; tests/claude-loop-e2e.el --- State-machine tests for init-claude-loop
;;
;; Exercises the whole loop -- spawn, stream decoding, classification, async
;; verify, retry-by-resume, timeout, checkbox marking -- against a stub CLI
;; written to a temp directory.  No API calls and no money spent.
;;
;; Kept out of `just test' on purpose: it drives real processes and timers, so
;; it is deterministic but not instant, and a wedged run should not block the
;; fast feedback loop.  Run it with:
;;
;;   just test-claude-loop
;;
;; The pure functions are covered by ERT in tests/run-tests.el instead.

(add-to-list 'load-path (expand-file-name "lisp" (or (getenv "RATA_ROOT")
                                                     default-directory)))
(require 'init-claude-loop)

(defvar rata-e2e--failures 0)
(defvar rata-e2e--dir (make-temp-file "claude-loop-e2e" t))
(defvar rata-e2e--stub (expand-file-name "fake-claude" rata-e2e--dir))
(defvar rata-e2e--counter (expand-file-name "invocations" rata-e2e--dir))
(defvar rata-e2e--verify-counter (expand-file-name "verifies" rata-e2e--dir))
(defvar rata-e2e--prompt (expand-file-name "last-prompt" rata-e2e--dir))

(defun rata-e2e--check (label got expected)
  "Report whether GOT equals EXPECTED for LABEL."
  (if (equal got expected)
      (message "ok   %s" label)
    (setq rata-e2e--failures (1+ rata-e2e--failures))
    (message "FAIL %s\n  got:      %S\n  expected: %S" label got expected)))

;;; ------------------------------------------------------------------
;;; The stub CLI
;;; ------------------------------------------------------------------
;; Emits the stream-json shapes the real CLI does.  FAKE_MODE selects the
;; scenario; invocations are counted so a test can make attempt 1 fail and
;; attempt 2 succeed.  Note `ok' deliberately omits the trailing newline after
;; the result line: the real CLI does not promise one, and the result event is
;; the only carrier of is_error/subtype/permission_denials.

(defconst rata-e2e--stub-source "\
#!/usr/bin/env bash
sid=\"11111111-2222-3333-4444-555555555555\"
resumed=0
prev=\"\"
for a in \"$@\"; do
  [ \"$a\" = \"--resume\" ] && resumed=1
  [ \"$prev\" = \"-p\" ] && [ -n \"$FAKE_PROMPT_FILE\" ] && printf '%s' \"$a\" > \"$FAKE_PROMPT_FILE\"
  prev=\"$a\"
done
n=1
if [ -n \"$FAKE_COUNT_FILE\" ]; then
  n=$(( $(cat \"$FAKE_COUNT_FILE\" 2>/dev/null || echo 0) + 1 ))
  echo \"$n\" > \"$FAKE_COUNT_FILE\"
fi
printf '{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"fake\",\"permissionMode\":\"acceptEdits\",\"session_id\":\"%s\"}\\n' \"$sid\"
case \"${FAKE_MODE:-ok}\" in
  ok)
    printf '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"did it (call %s, resumed=%s)\\\\n\\\\nRATA-TASK-STATUS: done\"}]}}\\n' \"$n\" \"$resumed\"
    printf '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.01,\"duration_ms\":1200,\"num_turns\":3}'
    ;;
  blocked)
    printf '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"cannot\\\\n\\\\nRATA-TASK-STATUS: blocked -- the API does not exist\"}]}}\\n'
    printf '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.01,\"duration_ms\":900,\"num_turns\":1}\\n'
    ;;
  denied)
    printf '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"permission_denials\":[{\"tool_name\":\"Edit\"}],\"total_cost_usd\":0.01,\"duration_ms\":500,\"num_turns\":1}\\n'
    ;;
  noise)
    echo \"some warning on stdout that is not JSON\"
    echo \"a warning on stderr, split\" 1>&2
    printf '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"RATA-TASK-STATUS: done\"}]}}\\n'
    printf '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":0.01,\"duration_ms\":100,\"num_turns\":1}\\n'
    ;;
  hang)
    printf '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"working...\"}]}}\\n'
    sleep 300
    ;;
esac
exit ${FAKE_EXIT:-0}
"
  "Shell source of the stub CLI.")

(with-temp-file rata-e2e--stub
  (insert rata-e2e--stub-source))
(set-file-modes rata-e2e--stub #o755)

;;; ------------------------------------------------------------------
;;; Harness
;;; ------------------------------------------------------------------

(setq rata-claude-loop-executable rata-e2e--stub
      rata-claude-loop-task-timeout nil
      rata-claude-loop-verify-timeout nil
      rata-claude-loop-verify-command nil
      rata-claude-loop-kill-grace 1
      ;; Journals go to the scratch directory, never to the real one: a test
      ;; run must not leave records in the operator's history.
      rata-claude-loop-journal-directory (expand-file-name "journal"
                                                           rata-e2e--dir))

(defun rata-e2e--wait (&optional limit)
  "Pump timers and process output until the loop stops running."
  (let ((deadline (+ (float-time) (or limit 30))))
    (while (and (rata-claude-loop-running-p) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      ;; Batch mode needs an explicit nudge for the zero-delay step timers.
      (sit-for 0.01)))
  (rata-claude-loop--get :status))

(defun rata-e2e--tasks (content)
  "Write CONTENT to a fresh tasks.md and return its path."
  (let ((file (expand-file-name "tasks.md" (make-temp-file "cl-case" t))))
    (with-temp-file file (insert content))
    file))

(defun rata-e2e--run (file &optional single)
  "Run the loop over FILE and return its final status."
  (rata-claude-loop--begin file (file-name-directory file) single)
  (rata-claude-loop--advance)
  (rata-e2e--wait))

(defun rata-e2e--run-from-start (file)
  "Run the loop over FILE through `--start-run', so the baseline applies."
  (rata-claude-loop--begin file (file-name-directory file) nil)
  (rata-claude-loop--start-run)
  (rata-e2e--wait))

(defun rata-e2e--journal ()
  "Return the current run's journal contents, or an empty string."
  (let ((file (rata-claude-loop--get :journal)))
    (if (and file (file-exists-p file))
        (with-temp-buffer (insert-file-contents file) (buffer-string))
      "")))

(defun rata-e2e--contents (file)
  "Return FILE's contents, freshly read from disk."
  (with-current-buffer (find-file-noselect file)
    (revert-buffer t t t)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun rata-e2e--output ()
  "Return the loop buffer's text."
  (with-current-buffer (rata-claude-loop--buffer) (buffer-string)))

(defun rata-e2e--saw (regexp)
  "Return t when REGEXP appears in the loop output."
  (and (string-match-p regexp (rata-e2e--output)) t))

;;; ------------------------------------------------------------------
;;; 1. Happy path
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(let* ((file (rata-e2e--tasks "- [ ] alpha\n- [ ] beta\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "happy: finished" status 'finished)
  (rata-e2e--check "happy: both boxes ticked" (rata-e2e--contents file)
                   "- [X] alpha\n- [X] beta\n")
  (rata-e2e--check "happy: two tasks run" (rata-claude-loop--get :index) 2)
  ;; The result line arrived without a trailing newline and still rendered.
  (rata-e2e--check "happy: result event survived EOF"
                   (rata-e2e--saw "· 3 turns") t)
  (rata-e2e--check "happy: whole session id kept"
                   (rata-claude-loop--get :session-id)
                   "11111111-2222-3333-4444-555555555555"))

;;; ------------------------------------------------------------------
;;; 2. Exit-0 failures must not tick the box
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "blocked")
(let* ((file (rata-e2e--tasks "- [ ] impossible\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "blocked: halted" status 'halted)
  (rata-e2e--check "blocked: box still open" (rata-e2e--contents file)
                   "- [ ] impossible\n")
  (rata-e2e--check "blocked: reason surfaced"
                   (rata-e2e--saw "the API does not exist") t))

(setenv "FAKE_MODE" "denied")
(let* ((file (rata-e2e--tasks "- [ ] denied work\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "denied: halted" status 'halted)
  (rata-e2e--check "denied: box still open" (rata-e2e--contents file)
                   "- [ ] denied work\n")
  (rata-e2e--check "denied: names the tool" (rata-e2e--saw "denied.*Edit") t))

(setenv "FAKE_MODE" "ok")
(setenv "FAKE_EXIT" "1")
(let* ((file (rata-e2e--tasks "- [ ] crashy\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "crash: halted" status 'halted)
  (rata-e2e--check "crash: box still open" (rata-e2e--contents file)
                   "- [ ] crashy\n"))
(setenv "FAKE_EXIT" "0")

;;; ------------------------------------------------------------------
;;; 3. Retry by resuming the session
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(setenv "FAKE_COUNT_FILE" rata-e2e--counter)
(setenv "FAKE_PROMPT_FILE" rata-e2e--prompt)
(ignore-errors (delete-file rata-e2e--counter))
(ignore-errors (delete-file rata-e2e--verify-counter))
(let ((file (rata-e2e--tasks "- [ ] flaky\n")))
  ;; Verify fails the first time it is asked and passes afterwards.
  (setq rata-claude-loop-verify-command
        (format "n=$(cat %s 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s; \
if [ $n -le 1 ]; then echo 'FAILED: test_thing'; exit 1; fi; echo 'all good'"
                (shell-quote-argument rata-e2e--verify-counter)
                (shell-quote-argument rata-e2e--verify-counter))
        rata-claude-loop-max-attempts 2)
  (let ((status (rata-e2e--run file)))
    (rata-e2e--check "retry: finished" status 'finished)
    (rata-e2e--check "retry: box ticked" (rata-e2e--contents file) "- [X] flaky\n")
    (rata-e2e--check "retry: claude ran twice"
                     (string-trim (with-temp-buffer
                                    (insert-file-contents rata-e2e--counter)
                                    (buffer-string)))
                     "2")
    (rata-e2e--check "retry: second run resumed the session"
                     (rata-e2e--saw "resumed=1") t)
    (rata-e2e--check "retry: attempt announced" (rata-e2e--saw "attempt 2/2") t)
    (rata-e2e--check "retry: failing output shown"
                     (rata-e2e--saw "FAILED: test_thing") t)
    ;; The point of resuming is the payload, not the call: the second attempt
    ;; must be told what broke, and told not to game the test.
    (let ((prompt (with-temp-buffer
                    (insert-file-contents rata-e2e--prompt)
                    (buffer-string))))
      (rata-e2e--check "retry: prompt carries the failure output"
                       (and (string-match-p "FAILED: test_thing" prompt) t) t)
      (rata-e2e--check "retry: prompt forbids gaming the test"
                       (and (string-match-p "not weaken" prompt) t) t))))
(setenv "FAKE_COUNT_FILE" nil)
(setenv "FAKE_PROMPT_FILE" nil)

(let ((file (rata-e2e--tasks "- [ ] never passes\n")))
  (setq rata-claude-loop-verify-command "echo 'boom'; exit 3"
        rata-claude-loop-max-attempts 2)
  (let ((status (rata-e2e--run file)))
    (rata-e2e--check "exhausted: halted" status 'halted)
    (rata-e2e--check "exhausted: box still open" (rata-e2e--contents file)
                     "- [ ] never passes\n")
    (rata-e2e--check "exhausted: says it gave up"
                     (rata-e2e--saw "gave up after 2 attempts") t)))
(setq rata-claude-loop-verify-command nil)

;;; ------------------------------------------------------------------
;;; 4. Never tick the wrong box
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(let ((file (rata-e2e--tasks "- [ ] alpha\n- [ ] beta\n")))
  ;; Claim beta sits on line 1, where alpha actually is.
  (rata-claude-loop--begin file (file-name-directory file) t)
  (rata-claude-loop--run-task 1 "beta")
  (rata-e2e--wait)
  (rata-e2e--check "relocate: only beta ticked" (rata-e2e--contents file)
                   "- [ ] alpha\n- [X] beta\n"))

(let ((file (rata-e2e--tasks "- [ ] alpha\n")))
  (rata-claude-loop--begin file (file-name-directory file) t)
  (rata-claude-loop--run-task 1 "a task that is not in the file")
  (let ((status (rata-e2e--wait)))
    (rata-e2e--check "missing task: halted" status 'halted)
    (rata-e2e--check "missing task: nothing ticked" (rata-e2e--contents file)
                     "- [ ] alpha\n")
    (rata-e2e--check "missing task: says it refused"
                     (rata-e2e--saw "refusing to tick") t)))

;;; ------------------------------------------------------------------
;;; 5. Timeout
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "hang")
(setq rata-claude-loop-task-timeout 2)
(let* ((file (rata-e2e--tasks "- [ ] slow\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "timeout: halted" status 'halted)
  (rata-e2e--check "timeout: box still open" (rata-e2e--contents file)
                   "- [ ] slow\n")
  (rata-e2e--check "timeout: reason mentions it" (rata-e2e--saw "exceeded") t)
  (rata-e2e--check "timeout: no process left behind"
                   (process-live-p (rata-claude-loop--get :process)) nil))
(setq rata-claude-loop-task-timeout nil)

;;; ------------------------------------------------------------------
;;; 6. Noise on stdout and stderr is rendered, not fatal
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "noise")
(let* ((file (rata-e2e--tasks "- [ ] noisy\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "noise: finished" status 'finished)
  (rata-e2e--check "noise: box ticked" (rata-e2e--contents file) "- [X] noisy\n")
  (rata-e2e--check "noise: stdout warning shown"
                   (rata-e2e--saw "some warning on stdout") t)
  ;; One marker line, not one per chunk.
  (rata-e2e--check "noise: stderr shown whole"
                   (rata-e2e--saw "! a warning on stderr, split") t))

;;; ------------------------------------------------------------------
;;; 7. Duplicate task text does not trip the progress guard
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(let* ((file (rata-e2e--tasks "- [ ] Add tests\n- [ ] Add tests\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "duplicates: finished" status 'finished)
  (rata-e2e--check "duplicates: both ticked" (rata-e2e--contents file)
                   "- [X] Add tests\n- [X] Add tests\n"))

;;; ------------------------------------------------------------------
;;; 8. A wedged loop is detectable rather than silent
;;; ------------------------------------------------------------------

(let ((rata-claude-loop--state (list :status 'running :epoch 1)))
  (rata-e2e--check "wedged: detected" (rata-claude-loop--wedged-p) t))
(let ((rata-claude-loop--state (list :status 'finished :epoch 1)))
  (rata-e2e--check "wedged: not for a finished loop"
                   (rata-claude-loop--wedged-p) nil))

;;; ------------------------------------------------------------------
;;; 9. One impossible task does not have to end the run
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "blocked")
(setq rata-claude-loop-on-task-failure 'skip)
(let* ((file (rata-e2e--tasks "- [ ] one\n- [ ] two\n- [ ] three\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "contain: run finished rather than halting" status 'finished)
  (rata-e2e--check "contain: every task marked skipped, none ticked"
                   (rata-e2e--contents file)
                   "- [-] one\n- [-] two\n- [-] three\n")
  (rata-e2e--check "contain: all three were attempted"
                   (rata-claude-loop--get :index) 3)
  (rata-e2e--check "contain: summary counts the failures"
                   (rata-e2e--saw "3 tasks · 0 done · 3 failed") t))
(setq rata-claude-loop-on-task-failure 'halt)

;; The default is still to stop, and a single-task run always stops.
(setenv "FAKE_MODE" "blocked")
(let* ((file (rata-e2e--tasks "- [ ] one\n- [ ] two\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "contain: halt is still the default" status 'halted)
  (rata-e2e--check "contain: nothing marked when halting"
                   (rata-e2e--contents file) "- [ ] one\n- [ ] two\n"))

(setq rata-claude-loop-on-task-failure 'skip)
(let ((file (rata-e2e--tasks "- [ ] only\n")))
  (rata-e2e--check "contain: a single-task run halts even under `skip'"
                   (rata-e2e--run file t) 'halted))
(setq rata-claude-loop-on-task-failure 'halt)

;;; ------------------------------------------------------------------
;;; 10. The run budget stops the loop between tasks
;;; ------------------------------------------------------------------

;; The stub reports $0.01 per attempt, so a $0.015 cap must stop after the
;; second task -- having let the second one finish and tick its box.
(setenv "FAKE_MODE" "ok")
(setq rata-claude-loop-run-budget-usd 0.015)
(let* ((file (rata-e2e--tasks "- [ ] one\n- [ ] two\n- [ ] three\n"))
       (status (rata-e2e--run file)))
  (rata-e2e--check "budget: halted" status 'halted)
  (rata-e2e--check "budget: stopped between tasks, not mid-task"
                   (rata-e2e--contents file)
                   "- [X] one\n- [X] two\n- [ ] three\n")
  (rata-e2e--check "budget: says why" (rata-e2e--saw "run budget") t)
  (rata-e2e--check "budget: spend accumulated across tasks"
                   (> (rata-claude-loop--get :cost) 0.015) t))
(setq rata-claude-loop-run-budget-usd nil)

;;; ------------------------------------------------------------------
;;; 11. The detail written under a task reaches the prompt
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(setenv "FAKE_PROMPT_FILE" rata-e2e--prompt)
(ignore-errors (delete-file rata-e2e--prompt))
(let ((file (rata-e2e--tasks "- [ ] alpha\n    it must handle the empty case\n    and keep the old name\n- [ ] beta\n")))
  (rata-e2e--run file t)
  (let ((prompt (with-temp-buffer
                  (insert-file-contents rata-e2e--prompt)
                  (buffer-string))))
    (rata-e2e--check "body: detail reached the prompt"
                     (and (string-match-p "it must handle the empty case" prompt)
                          (string-match-p "and keep the old name" prompt)
                          t)
                     t)
    ;; The next task's line is not this task's detail.
    (rata-e2e--check "body: stops at the next task"
                     (string-match-p "beta" prompt) nil))
  (rata-e2e--check "body: announced in the buffer"
                   (rata-e2e--saw "2 line(s) of detail") t))
(setenv "FAKE_PROMPT_FILE" nil)

;;; ------------------------------------------------------------------
;;; 12. A verify command that already fails stops before any task runs
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(setenv "FAKE_COUNT_FILE" rata-e2e--counter)
(ignore-errors (delete-file rata-e2e--counter))
(setq rata-claude-loop-verify-command "echo 'pre-existing breakage'; exit 1"
      rata-claude-loop-verify-baseline t)
(let* ((file (rata-e2e--tasks "- [ ] alpha\n"))
       (status (rata-e2e--run-from-start file)))
  (rata-e2e--check "baseline: halted" status 'halted)
  (rata-e2e--check "baseline: box untouched" (rata-e2e--contents file)
                   "- [ ] alpha\n")
  (rata-e2e--check "baseline: claude was never launched"
                   (file-exists-p rata-e2e--counter) nil)
  (rata-e2e--check "baseline: blames the tree, not the task"
                   (rata-e2e--saw "already fails") t)
  ;; Nothing of the baseline's output may survive to be fed to a task retry.
  (rata-e2e--check "baseline: output not kept as task feedback"
                   (rata-claude-loop--get :verify-output) nil))

;; A passing baseline gets out of the way.
(setq rata-claude-loop-verify-command "exit 0")
(let* ((file (rata-e2e--tasks "- [ ] alpha\n"))
       (status (rata-e2e--run-from-start file)))
  (rata-e2e--check "baseline: passing baseline runs the tasks" status 'finished)
  (rata-e2e--check "baseline: box ticked" (rata-e2e--contents file)
                   "- [X] alpha\n"))
(setq rata-claude-loop-verify-command nil)
(setenv "FAKE_COUNT_FILE" nil)

;;; ------------------------------------------------------------------
;;; 13. The run is journalled durably, session id included
;;; ------------------------------------------------------------------

(setenv "FAKE_MODE" "ok")
(let* ((file (rata-e2e--tasks "- [ ] alpha\n"))
       (_ (rata-e2e--run file))
       (journal (rata-e2e--journal)))
  (rata-e2e--check "journal: run start recorded"
                   (and (string-match-p "\"event\":\"run-start\"" journal) t) t)
  (rata-e2e--check "journal: task recorded as done"
                   (and (string-match-p "\"event\":\"task-end\"" journal)
                        (string-match-p "\"status\":\"done\"" journal)
                        t)
                   t)
  ;; The one fact that cannot be recomputed after an Emacs restart.
  (rata-e2e--check "journal: session id survives the process"
                   (and (string-match-p "11111111-2222-3333-4444-555555555555"
                                        journal)
                        t)
                   t)
  (rata-e2e--check "journal: run end recorded"
                   (and (string-match-p "\"event\":\"run-end\"" journal) t) t))

;;; ------------------------------------------------------------------

(delete-directory rata-e2e--dir t)
(message "\n==== claude-loop e2e: %s ===="
         (if (zerop rata-e2e--failures)
             "ALL PASSED"
           (format "%d FAILURE(S)" rata-e2e--failures)))
(kill-emacs (if (zerop rata-e2e--failures) 0 1))
