;;; -*- lexical-binding: t; -*-
;;; tests/run-tests.el --- ERT test suite for Ratatoskr-emacs
;;
;; Run with:
;;   emacs --init-directory . --batch -l ert -l tests/run-tests.el
;;
;; Or via justfile:
;;   just test-ert

;;; ============================================================
;;; Bootstrap: load the full config
;;; ============================================================

;; --init-directory . (passed in the just recipe) sets user-emacs-directory
;; to the repo root, so elpaca finds packages in ./elpaca/.
(unless (file-exists-p (expand-file-name "init.el" user-emacs-directory))
  (error "run-tests: user-emacs-directory (%s) has no init.el — pass --init-directory ."
         user-emacs-directory))

(message "=== Ratatoskr ERT: loading config ===")
(load (expand-file-name "early-init.el" user-emacs-directory) nil t)
(load (expand-file-name "init.el" user-emacs-directory) nil t)
(message "=== Ratatoskr ERT: config loaded, running tests ===")

;;; ============================================================
;;; Keybinding extraction helpers
;;; ============================================================

(defun rata-test--classify-binding (file key form)
  "Classify one key+form pair from a rata-leader body.
Returns (FILE KIND KEY [SYM]) where KIND is one of:
  :ignore  — group header, skip
  :lambda  — anonymous fn, convention violation
  :command — named command, check commandp
  :unknown — unrecognized pattern"
  ;; After `read', the source '(CMD :which-key \"...\") becomes
  ;; (quote (CMD :which-key \"...\")) in the parsed sexp.
  (let* ((inner (when (and (consp form)
                           (eq (car form) 'quote)
                           (consp (cadr form)))
                  (cadr form)))
         (head (when inner (car inner))))
    (cond
     ((and inner (eq head :ignore))
      (list file :ignore key))
     ((and inner (consp head) (eq (car head) 'lambda))
      (list file :lambda key))
     ((and inner (symbolp head))
      (list file :command key head))
     ((symbolp form)
      (list file :command key form))
     (t
      (list file :unknown key form)))))

(defun rata-test--extract-from-leader-body (body file)
  "Walk rata-leader BODY, return list of classified binding entries.
Skips keyword arguments (:states, :keymaps, etc.) and their values."
  (let (results items skip-next)
    (setq items body)
    (while items
      (let ((item (car items)))
        (cond
         (skip-next
          (setq skip-next nil))
         ((keywordp item)
          (when (memq item '(:states :keymaps :prefix :prefix-map
                             :non-normal-prefix :global-prefix :infix))
            (setq skip-next t)))
         ((stringp item)
          (when-let ((next (cadr items)))
            (push (rata-test--classify-binding file item next) results)
            ;; Advance past the value we just consumed
            (setq items (cdr items))))))
      (setq items (cdr items)))
    (nreverse results)))

(defun rata-test--walk-form (form file)
  "Recurse into FORM, return list of rata-leader binding entries.
Uses safe CDR-walking instead of dolist to handle dotted pairs
(e.g. from `(push '((nil . \"str\") . t) alist)' patterns)."
  (when (consp form)
    (if (eq (car form) 'rata-leader)
        (rata-test--extract-from-leader-body (cdr form) file)
      (let (results sub)
        (setq sub form)
        (while (consp sub)
          (when (consp (car sub))
            (setq results
                  (nconc results (rata-test--walk-form (car sub) file))))
          (setq sub (cdr sub)))
        results))))

(defun rata-test--extract-leader-bindings-from-file (filepath)
  "Parse FILEPATH and return a list of classified binding entries.
Each entry is (FILE KIND KEY [SYM]) as returned by
`rata-test--classify-binding'."
  (let (results)
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      (condition-case err
          (while t
            (let ((form-results (rata-test--walk-form
                                 (read (current-buffer)) filepath)))
              (when form-results
                (setq results (nconc results form-results)))))
        (end-of-file nil)
        (error
         (message "Warning: parse error in %s: %s" filepath err))))
    results))

;;; ============================================================
;;; Module/file list
;;; ============================================================

(defvar rata-test--excluded-modules
  '("init-mcp.el")
  "Modules not loaded by init.el; excluded from keybinding checks.")

(defun rata-test--all-init-files ()
  "Return paths of all active lisp/init-*.el files."
  (cl-remove-if
   (lambda (f)
     (member (file-name-nondirectory f) rata-test--excluded-modules))
   (directory-files
    (expand-file-name "lisp" user-emacs-directory)
    t
    "^init-.*\\.el$")))

(defun rata-test--collect-all-bindings ()
  "Collect rata-leader bindings from all active init-*.el files."
  (mapcan #'rata-test--extract-leader-bindings-from-file
          (rata-test--all-init-files)))

;;; ============================================================
;;; Test 1a — No anonymous lambda keybindings
;;; ============================================================

(ert-deftest rata-test-keybindings-no-lambdas ()
  "No rata-leader binding may use an anonymous lambda.
Per conventions, all keybindings must use named interactive commands
with a rata- prefix so they are discoverable, describable, and testable."
  (let (violations)
    (dolist (entry (rata-test--collect-all-bindings))
      (when (eq (cadr entry) :lambda)
        (push (format "%s: key %S uses anonymous lambda"
                      (file-name-nondirectory (car entry))
                      (caddr entry))
              violations)))
    (when violations
      (ert-fail (concat "Lambda keybinding violations:\n"
                        (mapconcat #'identity (nreverse violations) "\n"))))))

;;; ============================================================
;;; Test 1b — All bound commands satisfy commandp
;;; ============================================================

(ert-deftest rata-test-keybindings-all-commandp ()
  "Every named command symbol in rata-leader forms must satisfy commandp.
Uses (commandp SYM t) which accepts autoloaded interactive commands,
so deferred packages (loaded via :commands) pass correctly."
  (let (failures)
    (dolist (entry (rata-test--collect-all-bindings))
      (when (eq (cadr entry) :command)
        (let ((sym (cadddr entry)))
          (unless (commandp sym t)
            (push (format "%s: key %S → `%s' is not a command"
                          (file-name-nondirectory (car entry))
                          (caddr entry)
                          sym)
                  failures)))))
    (when failures
      (ert-fail (concat "Non-interactive command bindings:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

;;; ============================================================
;;; Test 2 — Module load health
;;; ============================================================

(ert-deftest rata-test-no-failed-modules ()
  "All modules must load without error.
Checks rata--failed-modules, populated by rata-load-module's
condition-case in init.el when a (require module) raises an error."
  (when rata--failed-modules
    (ert-fail
     (concat "Failed modules:\n"
             (mapconcat (lambda (e)
                          (format "  %-25s %s" (car e) (cdr e)))
                        rata--failed-modules
                        "\n")))))

(ert-deftest rata-test-init-loads-every-module ()
  "Every lisp/init-*.el must be wired into init.el, and vice versa.

Regression test for .are/memory/failures/FAIL-0006.md.  `scripts/lint.sh'
enforces three of the four steps in the \"add a module\" procedure; step
four — adding the `rata-load-module' line — was enforced by nothing, so a
module could sit in lisp/ loading nothing, binding nothing, and erroring
nothing.

Modules that are knowingly not loaded live in `rata-test--excluded-modules',
which already served exactly this purpose for the keybinding tests — reusing
it keeps one source of truth.

The match must be anchored at line start: a commented-out load line
\(`;; (rata-load-module ...)') otherwise counts as loaded, which is how the
first version of this check reported zero orphans."
  (let* ((init (expand-file-name "init.el" user-emacs-directory))
         (lisp-dir (expand-file-name "lisp" user-emacs-directory))
         (body (with-temp-buffer
                 (insert-file-contents init)
                 (buffer-string)))
         (missing nil)
         (dangling nil))
    ;; Every file on disk must have an active load line, unless excluded.
    (dolist (file (directory-files lisp-dir nil "^init-.*\\.el$"))
      (unless (member file rata-test--excluded-modules)
        (let ((module (file-name-sans-extension file)))
          (unless (string-match-p
                   (concat "^(rata-load-module '" (regexp-quote module) ")")
                   body)
            (push file missing)))))
    ;; Every active load line must have a file.
    (with-temp-buffer
      (insert body)
      (goto-char (point-min))
      (while (re-search-forward "^(rata-load-module '\\([a-z0-9-]+\\))" nil t)
        (let ((module (match-string 1)))
          (unless (file-exists-p (expand-file-name (concat module ".el") lisp-dir))
            (push module dangling)))))
    (when (or missing dangling)
      (ert-fail
       (concat
        (when missing
          (format "Modules in lisp/ never loaded by init.el: %s\n"
                  (mapconcat #'identity (nreverse missing) ", ")))
        (when dangling
          (format "rata-load-module lines with no file in lisp/: %s\n"
                  (mapconcat #'identity (nreverse dangling) ", "))))))))

;;; ============================================================
;;; Test 3 — no-littering backup/auto-save redirect
;;; ============================================================

(ert-deftest rata-test-no-littering-backup-redirect ()
  "Backup files must redirect to no-littering's var/backup/ directory.
The catch-all rule in backup-directory-alist must not point to
org-roam, second-brain, or any other user data directory."
  (let* ((var-dir (expand-file-name "var/" user-emacs-directory))
         (dot-rule (assoc "." backup-directory-alist)))
    (should dot-rule)
    (let ((target (cdr dot-rule)))
      (should (string-prefix-p var-dir (expand-file-name target)))
      (should-not (string-match-p "org-roam\\|second-brain" target)))))

(ert-deftest rata-test-no-littering-auto-save-redirect ()
  "Auto-save files must redirect to no-littering's var/auto-save/ directory.
The catch-all rule in auto-save-file-name-transforms must not point to
org-roam, second-brain, or any other user data directory."
  (let* ((var-dir (expand-file-name "var/" user-emacs-directory))
         (catch-all (cl-find-if (lambda (r) (string= (car r) ".*"))
                                auto-save-file-name-transforms)))
    (should catch-all)
    (let ((target (cadr catch-all)))
      (should (string-prefix-p var-dir (expand-file-name target)))
      (should-not (string-match-p "org-roam\\|second-brain" target)))))

(ert-deftest rata-test-yas-snippet-dirs-exist ()
  "Every entry in `yas-snippet-dirs' must resolve to a real directory.

Regression test for .are/memory/failures/FAIL-0002.md.  The config listed
the obsolete `yas-installed-snippets-dir', which points at a bundled
snippets directory upstream yasnippet no longer ships, so `yas-reload-all'
warned on every startup.  It warned rather than signalled, so
`rata-load-module' had nothing to catch and every existing test passed.

Entries may be directory strings or symbols whose value is a directory —
`yasnippet-snippets' registers itself as the symbol `yasnippet-snippets-dir'
so that the path resolves lazily after the package loads."
  (skip-unless (boundp 'yas-snippet-dirs))
  (let ((bad nil))
    (dolist (entry (if (listp yas-snippet-dirs)
                       yas-snippet-dirs
                     (list yas-snippet-dirs)))
      (let ((path (cond
                   ((stringp entry) entry)
                   ((and (symbolp entry) (boundp entry)) (symbol-value entry))
                   (t nil))))
        (cond
         ;; An unbound symbol is fine: the package that defines it has not
         ;; loaded yet.  A bound one that points nowhere is the bug.
         ((and (symbolp entry) (not (boundp entry))))
         ((null path) (push (format "%S (does not resolve to a path)" entry) bad))
         ((not (file-directory-p path))
          (push (format "%S -> %s (not a directory)" entry path) bad)))))
    (when bad
      (ert-fail (concat "yas-snippet-dirs entries that do not exist:\n  "
                        (mapconcat #'identity (nreverse bad) "\n  "))))))

;;; ============================================================
;;; Test 4 — claude-loop task scanning and marking
;;; ============================================================
;;
;; These cover the pure cores of init-claude-loop.el.  No CLI is invoked; the
;; state machine is exercised separately (see README.org) because it needs
;; timers and a stub executable.

(ert-deftest rata-test-claude-loop-scan-markdown ()
  "The first open checkbox is found, and ticked ones are skipped."
  (with-temp-buffer
    (insert "# Tasks\n\n- [X] done thing\n- [ ] first open\n- [ ] second open\n")
    (should (equal (rata-claude-loop--scan-buffer) '(4 . "first open")))
    (should (= (rata-claude-loop--count-in-buffer) 2))))

(ert-deftest rata-test-claude-loop-scan-org ()
  "In Org files both TODO headings and checkboxes count, earliest first."
  (with-temp-buffer
    (insert "* DONE old\n* TODO org task\n- [ ] checkbox task\n")
    (org-mode)
    (should (equal (rata-claude-loop--scan-buffer) '(2 . "org task")))
    (should (= (rata-claude-loop--count-in-buffer) 2))))

(ert-deftest rata-test-claude-loop-scan-empty ()
  "A file with no open tasks scans to nil rather than signalling."
  (with-temp-buffer
    (insert "nothing here\n")
    (should-not (rata-claude-loop--scan-buffer))
    (should (= (rata-claude-loop--count-in-buffer) 0))))

(ert-deftest rata-test-claude-loop-relocates-shifted-task ()
  "A task that moved is found by text, so the wrong box is never ticked."
  (with-temp-buffer
    (insert "- [ ] alpha\n- [ ] beta\n")
    (should (= (rata-claude-loop--find-task-line 2 "beta") 2))
    ;; Told line 1, where alpha actually is: must relocate to 2.
    (should (= (rata-claude-loop--find-task-line 1 "beta") 2))
    ;; Absent: refuse rather than guess.
    (should-not (rata-claude-loop--find-task-line 1 "gamma"))))

(ert-deftest rata-test-claude-loop-refuses-ambiguous-task ()
  "Two identically worded tasks are refused when the line hint is wrong."
  (with-temp-buffer
    (insert "- [ ] Add tests\n- [ ] Add tests\n")
    (should (= (rata-claude-loop--find-task-line 1 "Add tests") 1))
    (should-not (rata-claude-loop--find-task-line 9 "Add tests"))))

(ert-deftest rata-test-claude-loop-mark-checkboxes ()
  "Marking rewrites only the target line, for every bullet style."
  (with-temp-buffer
    (insert "- [ ] alpha\n  + [ ] indented\n* [ ] star bullet\n")
    (should (rata-claude-loop--mark-in-buffer 1 'done))
    (should (rata-claude-loop--mark-in-buffer 2 'skipped))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "- [X] alpha\n  + [-] indented\n* [ ] star bullet\n"))
    ;; An already-marked line reports no change.
    (should-not (rata-claude-loop--mark-in-buffer 1 'done))))

(ert-deftest rata-test-claude-loop-mark-org-skip-without-cancelled ()
  "Skipping an Org TODO must not signal when there is no CANCELLED keyword.
`org-todo' rejects a state absent from `org-todo-keywords-1', and the
default keyword set has none, so the fallback is DONE plus a tag."
  (with-temp-buffer
    (insert "* TODO org task\n")
    (org-mode)
    (should (rata-claude-loop--mark-in-buffer 1 'skipped))
    (should (string-match-p "DONE" (buffer-string)))
    (should (string-match-p ":skipped:" (buffer-string)))))

(ert-deftest rata-test-claude-loop-project-root-refuses-home ()
  "A repository marker in $HOME must not make $HOME the project root."
  (should (equal (rata-claude-loop--project-root (expand-file-name "~/tasks.md"))
                 (file-name-as-directory (expand-file-name "~")))))

;;; ============================================================
;;; Test 5 — claude-loop stream decoding and classification
;;; ============================================================

(ert-deftest rata-test-claude-loop-consume-split-and-unterminated ()
  "A JSON object split across chunks and lacking a final newline is decoded.
The CLI does not have to newline-terminate its last line, and that line
carries the `result' event the loop makes every decision from."
  (let ((rata-claude-loop--state (list :pending "" :epoch 0))
        (seen nil))
    (cl-letf (((symbol-function 'rata-claude-loop--render-event)
               (lambda (event) (push event seen))))
      (dolist (chunk '("{\"type\":\"res" "ult\",\"subtype\":\"suc" "cess\"}"))
        (rata-claude-loop--consume chunk))
      (should-not seen)                 ; nothing complete yet
      (rata-claude-loop--consume "" t)) ; EOF flush
    (should (equal seen '(((type . "result") (subtype . "success")))))))

(ert-deftest rata-test-claude-loop-consume-multiple-events ()
  "Several newline-terminated events in one chunk each render once."
  (let ((rata-claude-loop--state (list :pending "" :epoch 0))
        (count 0))
    (cl-letf (((symbol-function 'rata-claude-loop--render-event)
               (lambda (_event) (setq count (1+ count)))))
      (rata-claude-loop--consume "{\"type\":\"a\"}\n{\"type\":\"b\"}\n")
      (rata-claude-loop--consume "\n\n"))
    (should (= count 2))))

(ert-deftest rata-test-claude-loop-classify ()
  "Success and every failure mode are told apart from the result event."
  (cl-flet ((classify (state code)
              (let ((rata-claude-loop--state state))
                (rata-claude-loop--classify code))))
    ;; The only shape that counts as success.
    (should-not (classify '(:result ((subtype . "success"))) 0))
    ;; Exit 0 but nothing was written, because every edit was denied.
    (should (eq 'denied
                (car (classify '(:result ((subtype . "success")
                                          (permission_denials
                                           . (((tool_name . "Edit"))))))
                               0))))
    ;; A denied WebFetch is tolerated: halting a good run over it is worse.
    (should-not (classify '(:result ((subtype . "success")
                                     (permission_denials
                                      . (((tool_name . "WebFetch"))))))
                          0))
    ;; Exit 0 but the task said it could not do it.
    (should (eq 'blocked (car (classify '(:result ((subtype . "success"))
                                          :report blocked
                                          :report-reason "no such API")
                                        0))))
    (should (equal "no such API"
                   (cdr (classify '(:result ((subtype . "success"))
                                    :report blocked
                                    :report-reason "no such API")
                                  0))))
    ;; Limits and errors.
    (should (eq 'max-turns (car (classify '(:result ((subtype . "error_max_turns"))) 1))))
    (should (eq 'budget (car (classify '(:result ((subtype . "error_max_budget_usd"))) 1))))
    (should (eq 'execution (car (classify '(:result ((subtype . "error_during_execution"))) 1))))
    (should (eq 'crash (car (classify '(:result ((subtype . "success") (is_error . t))) 0))))
    (should (eq 'crash (car (classify '(:result ((subtype . "success"))) 2))))
    ;; Died before reporting anything.
    (should (eq 'no-result (car (classify '(:result nil) 0))))
    ;; A timer got there first; its verdict is the accurate one.
    (should (equal '(timeout . "took too long")
                   (classify '(:outcome (timeout . "took too long")) 9)))))

(ert-deftest rata-test-claude-loop-note-status ()
  "The self-reported status line is parsed, last occurrence winning."
  (cl-flet ((note (text)
              (let ((rata-claude-loop--state (list :epoch 0)))
                (rata-claude-loop--note-status text)
                (cons (plist-get rata-claude-loop--state :report)
                      (plist-get rata-claude-loop--state :report-reason)))))
    (should (equal '(done) (note "all good\n\nRATA-TASK-STATUS: done")))
    (should (equal '(blocked . "the API does not exist")
                   (note "RATA-TASK-STATUS: blocked -- the API does not exist")))
    (should (equal '(blocked . "em dash reason")
                   (note "RATA-TASK-STATUS: blocked — em dash reason")))
    (should (equal '(nil) (note "no status here")))
    (should (eq 'done (car (note "RATA-TASK-STATUS: blocked -- x\nRATA-TASK-STATUS: done"))))))

;;; ============================================================
;;; Test 6 — claude-loop command line construction
;;; ============================================================

(ert-deftest rata-test-claude-loop-build-command ()
  "Every configured guard rail reaches the argv, along with the prompt."
  (let ((rata-claude-loop--state (list :root "/tmp/"))
        (rata-claude-loop-executable "claude")
        (rata-claude-loop-model "opus")
        (rata-claude-loop-max-turns 30)
        (rata-claude-loop-task-budget-usd 1.5)
        (rata-claude-loop-fallback-model "sonnet")
        (rata-claude-loop-extra-args '("--permission-mode" "acceptEdits")))
    (let ((argv (rata-claude-loop--build-command "do a thing" "/tmp/tasks.md")))
      (should (equal (car argv) "claude"))
      (should (member "--max-turns" argv))
      (should (member "30" argv))
      (should (member "--max-budget-usd" argv))
      (should (member "1.5" argv))
      (should (member "--fallback-model" argv))
      (should (member "--model" argv))
      (should (member "stream-json" argv))
      (should (string-match-p "do a thing" (nth 2 argv)))
      (should (string-match-p "RATA-TASK-STATUS" (nth 2 argv))))))

(ert-deftest rata-test-claude-loop-retry-command-repasses-flags ()
  "A retry re-passes every flag: `--resume' inherits none of them."
  (let ((rata-claude-loop--state (list :root "/tmp/" :session-id "abc-123"))
        (rata-claude-loop-executable "claude")
        (rata-claude-loop-model "opus")
        (rata-claude-loop-max-turns 30)
        (rata-claude-loop-fallback-model "sonnet")
        (rata-claude-loop-extra-args '("--permission-mode" "acceptEdits")))
    (let ((argv (rata-claude-loop--build-retry-command "verify failed" "boom")))
      (should (member "--resume" argv))
      (should (member "abc-123" argv))
      (should (member "--model" argv))
      (should (member "--max-turns" argv))
      (should (member "--fallback-model" argv))
      (should (member "--permission-mode" argv))
      (should (string-match-p "verify failed" (nth 2 argv)))
      (should (string-match-p "boom" (nth 2 argv)))
      ;; The guard against the classic retry failure mode.
      (should (string-match-p "not weaken" (nth 2 argv))))))

(ert-deftest rata-test-claude-loop-tail-truncation ()
  "Captured output is truncated from the front: failures are at the end."
  (should (equal (rata-claude-loop--tail "abcdef" 10) "abcdef"))
  (should (string-suffix-p "def" (rata-claude-loop--tail "abcdef" 3)))
  (should (equal (rata-claude-loop--tail-lines "a\nb" 5) "a\nb"))
  (should (string-suffix-p "c\nd" (rata-claude-loop--tail-lines "a\nb\nc\nd" 2))))

(ert-deftest rata-test-claude-loop-tool-argument-relative ()
  "Tool paths under the project root are shown relative to it."
  (let ((rata-claude-loop--state (list :root "/home/jens/proj/")))
    (should (equal (rata-claude-loop--tool-argument
                    '((file_path . "/home/jens/proj/src/a.el")))
                   "src/a.el"))
    (should (equal (rata-claude-loop--tool-argument
                    '((file_path . "/elsewhere/b.el")))
                   "/elsewhere/b.el"))))

;;; ============================================================
;;; Run all tests
;;; ============================================================

(ert-run-tests-batch-and-exit)
