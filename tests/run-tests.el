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
;;; Test 1c — Core leader keys are reachable, not merely `commandp'
;;; ============================================================

(defvar rata-test--must-be-live-keys
  '(("SPC p p" . consult-projectile-switch-project)
    ("SPC p f" . consult-projectile-find-file)
    ("SPC p s" . consult-projectile-ripgrep)
    ("SPC p b" . consult-project-buffer)
    ("SPC p t" . projectile-run-project-tests)
    ("SPC p k" . projectile-kill-buffers)
    ("SPC b b" . consult-buffer)
    ("SPC f f" . find-file)
    ("SPC j d" . xref-find-definitions)
    ("SPC J j" . jira-issues))
  "Leader keys that must resolve immediately after init, with their commands.
Not exhaustive — a contract for the keys most likely to be broken by the
failure mode in .are/memory/failures/FAIL-0009.md.  Extend it when a
binding turns out to have been dead in the running editor.")

(defun rata-test--leader-lookup (keys)
  "Resolve KEYS (a `kbd' string) the way evil resolves it in normal state.
`rata-leader' binds through general with :states, which stores the
binding in the normal-state auxiliary keymap of
`general-override-mode-map' — not in the global map, so plain
`key-binding' in batch mode finds nothing."
  (lookup-key (evil-get-auxiliary-keymap general-override-mode-map 'normal)
              (kbd keys)))

(ert-deftest rata-test-keybindings-live-after-init ()
  "Core leader keys must be bound in a fully initialised Emacs.

Regression test for .are/memory/failures/FAIL-0009.md.  A `rata-leader'
form inside a deferred `use-package' :config block is never evaluated
until something else loads that package, so the key stays undefined
while `rata-test-keybindings-all-commandp' still passes — that test
checks the command symbol, not the key.  `SPC p f' was dead in the
running editor for exactly this reason."
  (should (boundp 'general-override-mode-map))
  (let (failures)
    (pcase-dolist (`(,keys . ,expected) rata-test--must-be-live-keys)
      (let ((actual (rata-test--leader-lookup keys)))
        (unless (eq actual expected)
          (push (format "%s → %s (expected `%s')"
                        keys
                        ;; `lookup-key' returns an integer when the sequence
                        ;; runs past a prefix that is not fully defined.
                        (if (and actual (not (numberp actual)))
                            (format "`%s'" actual)
                          "UNDEFINED")
                        expected)
                failures))))
    (when failures
      (ert-fail (concat "Leader keys not live after init:\n"
                        (mapconcat #'identity (nreverse failures) "\n")))))
  ;; Vim-idiomatic goto keys are plain normal-state bindings (general-define-key
  ;; without :keymaps), so they live in `evil-normal-state-map', not the leader
  ;; override map the curated contract above checks.
  (should (eq (lookup-key evil-normal-state-map (kbd "gd")) 'xref-find-definitions))
  (should (eq (lookup-key evil-normal-state-map (kbd "gr")) 'xref-find-references)))

;;; ============================================================
;;; Test 1d — EVERY global leader key is live after init (exhaustive)
;;; ============================================================
;;
;; The curated `rata-test--must-be-live-keys' above is a hand-picked contract.
;; This test is the exhaustive version: it parses every `rata-leader' form in
;; every active module, drops the `:keymaps'-scoped (mode-local) forms and the
;; `:ignore' group labels, and asserts that each remaining *global* key resolves
;; in the running editor.  It absorbs the standalone FAIL-0009 probe
;; (.are/memory/failures/FAIL-0009-probe.el) into the gate, so the 113 dead keys
;; that sweep fixed cannot silently come back the next time a binding is written
;; in a deferred `:config' instead of a top-level `with-eval-after-load'.

(defun rata-test--leader-bodies-in-file (file)
  "Return the body (cdr) of every `rata-leader' form found in FILE."
  (let (forms found)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (error nil)))
    (cl-labels ((walk (f)
                  (when (consp f)
                    (if (eq (car f) 'rata-leader)
                        (push (cdr f) found)
                      (let ((s f))
                        (while (consp s)
                          (when (consp (car s)) (walk (car s)))
                          (setq s (cdr s))))))))
      (mapc #'walk forms))
    found))

(defun rata-test--global-leader-keys-in-body (body)
  "Return the global string keys in a `rata-leader' BODY.
Returns nil for a `:keymaps'-scoped form (those are mode-local and are
legitimately dead until the mode loads).  `:ignore' group labels are skipped."
  (unless (memq :keymaps body)
    (let (keys (items body) skip)
      (while items
        (let ((it (car items)))
          (cond (skip (setq skip nil))
                ((keywordp it) (setq skip t))
                ((stringp it)
                 (let ((v (cadr items)))
                   (unless (and (consp v) (eq (car v) 'quote)
                                (eq (car-safe (cadr v)) :ignore))
                     (push it keys))
                   (setq items (cdr items))))))
        (setq items (cdr items)))
      keys)))

(defun rata-test--space-leader-key (keys)
  "Space out KEYS for `kbd', keeping SPC/TAB/RET/ESC/DEL tokens intact."
  (let (out (i 0) (n (length keys)))
    (while (< i n)
      (let ((rest (substring keys i)))
        (if (eq 0 (string-match "\\`\\(SPC\\|TAB\\|RET\\|ESC\\|DEL\\)" rest))
            (let ((tok (match-string 1 rest)))
              (push tok out)
              (setq i (+ i (length tok))))
          (push (string (aref keys i)) out)
          (setq i (1+ i)))))
    (mapconcat #'identity (nreverse out) " ")))

(ert-deftest rata-test-all-global-leader-keys-live-after-init ()
  "Every global (non-`:keymaps') leader key must resolve after full init.
Exhaustive regression for .are/memory/failures/FAIL-0009.md.  A global
`rata-leader' form written in a deferred `use-package' :config/:init is not
evaluated until that package loads, leaving the key dead at startup; it must be
hoisted to a top-level `(with-eval-after-load 'general ...)'."
  (should (boundp 'general-override-mode-map))
  (let ((aux (evil-get-auxiliary-keymap general-override-mode-map 'normal))
        dead)
    (dolist (file (rata-test--all-init-files))
      (dolist (body (rata-test--leader-bodies-in-file file))
        (dolist (k (rata-test--global-leader-keys-in-body body))
          (let ((res (lookup-key
                      aux (kbd (concat "SPC " (rata-test--space-leader-key k))))))
            (unless (and res (not (numberp res)))
              (push (format "  %-22s SPC %s"
                            (file-name-nondirectory file) k)
                    dead))))))
    (when dead
      (ert-fail (concat "Dead global leader keys after init "
                        "(hoist to top-level with-eval-after-load):\n"
                        (mapconcat #'identity (sort dead #'string<) "\n"))))))

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

(ert-deftest rata-test-claude-loop-classify-unverified ()
  "Work that was never executed fails, however cheerfully it reports."
  (cl-flet ((classify (state code)
              (let ((rata-claude-loop--state state))
                (rata-claude-loop--classify code))))
    ;; The run this check was written for: three denied Bash calls, the edits
    ;; on disk, exit 0, and `done' in the final message.
    (let ((verdict (classify '(:result ((subtype . "success")
                                        (permission_denials
                                         . (((tool_name . "Bash")
                                             (tool_input
                                              . ((command . "python3 hello.py")))))))
                               :report done)
                             0)))
      (should (eq 'unverified (car verdict)))
      (should (string-match-p "never run" (cdr verdict)))
      ;; It must name the fix: retrying alone hits the same wall.
      (should (string-match-p "Bash(python3:\\*)" (cdr verdict))))
    ;; Self-reported, and it wins the wording over the inferred version.
    (should (equal '(unverified . "could not run pytest")
                   (classify '(:result ((subtype . "success"))
                               :report unverified
                               :report-reason "could not run pytest")
                             0)))
    ;; Opting out restores the old tolerance.
    (let ((rata-claude-loop-verification-denial-tools nil))
      (should-not (classify '(:result ((subtype . "success")
                                       (permission_denials
                                        . (((tool_name . "Bash")))))
                              :report done)
                            0)))
    ;; A denied Edit is the stronger finding and keeps its own kind.
    (should (eq 'denied
                (car (classify '(:result ((subtype . "success")
                                          (permission_denials
                                           . (((tool_name . "Edit"))
                                              ((tool_name . "Bash"))))))
                               0))))))

(ert-deftest rata-test-claude-loop-denial-pattern ()
  "A denial suggests the narrowest --allowedTools pattern that would fit it."
  (cl-flet ((pattern (denial) (rata-claude-loop--denial-pattern denial)))
    (should (equal "Bash(python3:*)"
                   (pattern '((tool_name . "Bash")
                              (tool_input . ((command . "python3 hello.py")))))))
    ;; An absolute path names the program, not the path.
    (should (equal "Bash(python3:*)"
                   (pattern '((tool_name . "Bash")
                              (tool_input
                               . ((command . "/usr/bin/python3 hello.py")))))))
    ;; Some events carry `input' rather than `tool_input'.
    (should (equal "Bash(just:*)"
                   (pattern '((tool_name . "Bash")
                              (input . ((command . "just test")))))))
    ;; Nothing parseable: the bare tool name is wider than ideal, and honest.
    (should (equal "Bash" (pattern '((tool_name . "Bash")))))
    (should (equal "Bash" (pattern '((tool_name . "Bash")
                                     (tool_input . ((command . "FOO=1 make")))))))
    (should (equal "WebFetch" (pattern '((tool_name . "WebFetch")))))
    (should-not (pattern '((tool_use_id . "x"))))))

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
    (should (equal '(unverified . "could not run pytest")
                   (note "RATA-TASK-STATUS: unverified -- could not run pytest")))
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

(ert-deftest rata-test-claude-loop-prompt-demands-verification ()
  "The prompt asks for a run, not a reading, and offers a way to say so."
  (let ((prompt (rata-claude-loop--prompt "do a thing" "/tmp/tasks.md")))
    (should (string-match-p "verify" prompt))
    (should (string-match-p "not verification" prompt))
    (should (string-match-p "RATA-TASK-STATUS: unverified" prompt))
    (should (string-match-p "never able to execute" prompt))))

(ert-deftest rata-test-claude-loop-allowed-tools-reach-argv ()
  "Allowed tools and the appended system prompt survive into both commands.
`--allowedTools' is variadic, so whatever follows its patterns has to be a
flag; anything else would be swallowed as one more tool pattern."
  (let ((rata-claude-loop--state (list :root "/tmp/" :session-id "abc-123"))
        (rata-claude-loop-executable "claude")
        (rata-claude-loop-allowed-tools '("Bash(just:*)" "Bash(python3:*)"))
        (rata-claude-loop-append-system-prompt "be terse")
        (rata-claude-loop-extra-args '("--permission-mode" "acceptEdits")))
    (dolist (argv (list (rata-claude-loop--build-command "do a thing" "/tmp/t.md")
                        (rata-claude-loop--build-retry-command "verify failed" "x")))
      (should (member "--allowedTools" argv))
      (should (member "--append-system-prompt" argv))
      (should (member "be terse" argv))
      (let* ((tail (cdr (member "--allowedTools" argv)))
             (after (nthcdr 2 tail)))
        (should (equal (seq-take tail 2) '("Bash(just:*)" "Bash(python3:*)")))
        ;; Nothing, or a flag -- never a bare word.
        (should (or (null after) (string-prefix-p "-" (car after))))))))

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
;;; Test 7 — claude-loop task detail, budget, failure policy, journal
;;; ============================================================

(ert-deftest rata-test-claude-loop-body-markdown ()
  "Detail indented under a checkbox is collected, dedented, and bounded."
  (with-temp-buffer
    (insert "- [ ] alpha\n"
            "    it must handle the empty case\n"
            "    and keep the old name\n"
            "- [ ] beta\n"
            "    beta's own detail\n")
    (should (equal (rata-claude-loop--body-at 1)
                   "it must handle the empty case\nand keep the old name"))
    ;; The next task's line is not this task's detail.
    (should (equal (rata-claude-loop--body-at 4) "beta's own detail"))))

(ert-deftest rata-test-claude-loop-body-absent ()
  "A task with nothing under it has no body, rather than an empty one."
  (with-temp-buffer
    (insert "- [ ] alpha\n- [ ] beta\n")
    (should-not (rata-claude-loop--body-at 1))))

(ert-deftest rata-test-claude-loop-body-org ()
  "An Org entry's body is collected; drawers and planning lines are not.
A property drawer in a prompt is noise, and SCHEDULED is a fact about the
operator's calendar rather than about the work."
  (with-temp-buffer
    (insert "* TODO org task\n"
            "SCHEDULED: <2026-08-20 Thu>\n"
            ":PROPERTIES:\n:ID: 1234\n:END:\n"
            "the real description\n"
            "* TODO next task\n"
            "not part of the first\n")
    (org-mode)
    (should (equal (rata-claude-loop--body-at 1) "the real description"))))

(ert-deftest rata-test-claude-loop-head-truncation ()
  "Task detail is truncated from the end: a description is defined at the top."
  (should (equal (rata-claude-loop--head "abcdef" 10) "abcdef"))
  (should (string-prefix-p "abc" (rata-claude-loop--head "abcdef" 3))))

(ert-deftest rata-test-claude-loop-prompt-carries-body ()
  "Detail under a task reaches the prompt, and nothing is added without it."
  (let ((with-body (rata-claude-loop--prompt "do a thing" "/tmp/tasks.md"
                                             "must not break the old name"))
        (without (rata-claude-loop--prompt "do a thing" "/tmp/tasks.md" nil)))
    (should (string-match-p "must not break the old name" with-body))
    (should (string-match-p "do a thing" with-body))
    ;; The status-line request has to stay last, or it is buried by the detail.
    (should (string-match-p "RATA-TASK-STATUS.*\\'"
                            (replace-regexp-in-string "\n" " " with-body)))
    (should-not (string-match-p "Detail written under" without))))

(ert-deftest rata-test-claude-loop-budget-spent ()
  "The run budget reports itself spent only once it is reached."
  (let ((rata-claude-loop--state (list :cost 0.5)))
    (let ((rata-claude-loop-run-budget-usd nil))
      (should-not (rata-claude-loop--budget-spent)))
    (let ((rata-claude-loop-run-budget-usd 1.0))
      (should-not (rata-claude-loop--budget-spent)))
    (let ((rata-claude-loop-run-budget-usd 0.5))
      (should (rata-claude-loop--budget-spent)))))

(ert-deftest rata-test-claude-loop-failure-action ()
  "The failure policy is honoured, except that one task always halts."
  (let ((rata-claude-loop--state (list :single nil)))
    (let ((rata-claude-loop-on-task-failure 'halt))
      (should (eq (rata-claude-loop--failure-action "boom") 'halt)))
    (let ((rata-claude-loop-on-task-failure 'skip))
      (should (eq (rata-claude-loop--failure-action "boom") 'skip))))
  ;; A single-task run has nothing to continue to, whatever the policy says.
  (let ((rata-claude-loop--state (list :single t))
        (rata-claude-loop-on-task-failure 'skip))
    (should (eq (rata-claude-loop--failure-action "boom") 'halt))))

(ert-deftest rata-test-claude-loop-journal-record ()
  "A journal line is valid JSON, names its event, and omits absent fields."
  (let* ((line (rata-claude-loop--journal-record
                "task-end" (list :index 2 :status 'done :reason nil
                                 :cost 0.25 :task "alpha")))
         (parsed (json-parse-string line :object-type 'alist)))
    (should (string-suffix-p "\n" line))
    (should (equal (alist-get 'event parsed) "task-end"))
    (should (equal (alist-get 'status parsed) "done"))
    (should (equal (alist-get 'index parsed) 2))
    (should (alist-get 'time parsed))
    ;; nil is dropped rather than serialised as null: absent keys filter better.
    (should-not (assq 'reason parsed))))

(ert-deftest rata-test-claude-loop-summary-line ()
  "A summary line reports the verdict, the attempts, the cost and the reason."
  (let ((line (rata-claude-loop--summary-line
               (list :index 3 :task "alpha" :status 'failed :attempts 2
                     :seconds 65 :cost 0.5 :reason "verify command failed"))))
    (should (string-match-p "⊘" line))
    (should (string-match-p "\\[3\\]" line))
    (should (string-match-p "alpha" line))
    (should (string-match-p "2 attempts" line))
    (should (string-match-p "\\$0\\.50" line))
    (should (string-match-p "verify command failed" line))))

;;; ============================================================
;;; 8. Per-machine configuration (local.el) -- D-012
;;; ============================================================

(ert-deftest rata-test-sql-snowflake-parameters-not-committed ()
  "The Snowflake identity is absent from the tracked source.
It lives in the gitignored `local.el\='.  This asserts the property the
audit check enforces textually, from the loaded config: whatever the
running Emacs has, the file on disk must not carry it."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/init-sql.el" user-emacs-directory))
    (dolist (var '("account" "user" "role" "warehouse" "database" "schema"))
      (goto-char (point-min))
      (should (re-search-forward
               (format "(defvar rata-sql-snowflake-%s nil" var) nil t)))))

(ert-deftest rata-test-sql-snowflake-uri-refuses-partial-config ()
  "Building a URI from unset parameters is refused, and names what is missing.
A URI made of nils is accepted here and fails much later, inside a
Leiningen nREPL boot, where the real cause is invisible."
  (let ((rata-sql-snowflake-account nil)
        (rata-sql-snowflake-user nil)
        (rata-sql-snowflake-role nil)
        (rata-sql-snowflake-warehouse nil)
        (rata-sql-snowflake-database nil)
        (rata-sql-snowflake-schema nil))
    (let ((err (should-error (rata-sql-snowflake-uri) :type 'user-error)))
      (should (string-match-p "rata-sql-snowflake-account" (cadr err)))
      (should (string-match-p "local.el.example" (cadr err)))))
  ;; One parameter short is still short -- the common case after a partial copy.
  (let ((rata-sql-snowflake-account "acct")
        (rata-sql-snowflake-user "u")
        (rata-sql-snowflake-role "r")
        (rata-sql-snowflake-warehouse "w")
        (rata-sql-snowflake-database "d")
        (rata-sql-snowflake-schema nil))
    (let ((err (should-error (rata-sql-snowflake-uri) :type 'user-error)))
      (should (string-match-p "rata-sql-snowflake-schema" (cadr err)))
      (should-not (string-match-p "rata-sql-snowflake-account" (cadr err)))))
  ;; Fully configured: a URI, with the parameters in it.
  (let ((rata-sql-snowflake-account "acct")
        (rata-sql-snowflake-user "u@example.com")
        (rata-sql-snowflake-role "r")
        (rata-sql-snowflake-warehouse "w")
        (rata-sql-snowflake-database "d")
        (rata-sql-snowflake-schema "s"))
    (let ((uri (rata-sql-snowflake-uri)))
      (should (string-prefix-p "jdbc:snowflake://acct.snowflakecomputing.com/" uri))
      (should (string-match-p "authenticator=externalbrowser" uri))
      ;; The user is hexified, so the @ must not survive raw.
      (should (string-match-p "user=u%40example\\.com" uri)))))

(ert-deftest rata-test-local-example-is-committed ()
  "`local.el.example\=' exists and is not gitignored.
It is the checklist a fresh machine works from, so an ignored or missing
template is the whole failure mode this design exists to prevent."
  (let ((example (expand-file-name "local.el.example" user-emacs-directory)))
    (should (file-exists-p example))
    ;; `git check-ignore --quiet' exits 0 when the path IS ignored, so a
    ;; committable template is a NON-zero exit.
    (should-not (zerop (call-process "git" nil nil nil "-C" user-emacs-directory
                                     "check-ignore" "--no-index" "--quiet"
                                     "local.el.example")))))

(ert-deftest rata-test-jira-base-url-has-no-trailing-slash ()
  "The Jira base URL reaches jira.el without a trailing slash.
jira.el derives its auth-source host by stripping only \"https://\"
\(jira-api.el:99,108).  A trailing slash therefore produces the host
\"acme.atlassian.net/\", no `machine\=' line matches, and the request 401s
as though the token were wrong.  L-018."
  ;; jira is deferred via :commands, so the variable does not exist until the
  ;; package loads.  Load it: a `skip-unless (boundp ...)' here would skip on
  ;; every run and read as coverage.
  (skip-unless (require 'jira-api nil t))
  (skip-unless (and (stringp jira-base-url) (not (string= "" jira-base-url))))
  (should-not (string-suffix-p "/" jira-base-url))
  ;; And the derived host, computed exactly as jira.el does it.
  (should-not (string-match-p
               "/" (replace-regexp-in-string "https://" "" jira-base-url))))

(ert-deftest rata-test-jira-base-url-normalisation ()
  "A trailing slash in `rata-jira-base-url\=' is dropped, not passed through."
  (should (equal (directory-file-name "https://acme.atlassian.net/")
                 "https://acme.atlassian.net"))
  (should (equal (directory-file-name "https://acme.atlassian.net")
                 "https://acme.atlassian.net")))

;;; ============================================================
;;; 9. Work agenda is dated
;;; ============================================================
;;
;; The "w" agenda gained a dated `agenda' block so that deadlines appear under
;; day headers instead of in a flat "Due Soon" bucket.  Both halves of that fail
;; silently -- the view still opens, just wrong -- so they are asserted here:
;;
;;   * lose the `agenda' block in a later edit and the date headers go with it;
;;   * put `org-agenda-tag-filter-preset' in a block instead of the command's
;;     global settings slot and the filter is unreliable by documentation
;;     (org-agenda.el:3834), which shows up as foreign tasks in a work view.
;;
;; Read from source rather than from the live variable: `org-super-agenda' is
;; deferred `:after org', so `org-agenda-custom-commands' still holds its default
;; in a batch Emacs that has not opened an agenda.

(require 'cl-lib)

(defun rata-test--find-setq-value (form variable)
  "Return the quoted value of a (setq VARIABLE \\='(...)) form nested in FORM.
Walks car and cdr separately: the module source contains dotted pairs
\(`:hook (org-mode . auto-fill-mode)'), which a list walker chokes on."
  (cond
   ((not (consp form)) nil)
   ((and (eq (car-safe form) 'setq) (eq (nth 1 form) variable))
    (cadr (nth 2 form)))
   (t (or (rata-test--find-setq-value (car form) variable)
          (rata-test--find-setq-value (cdr form) variable)))))

(defun rata-test--org-agenda-custom-commands ()
  "Return `org-agenda-custom-commands' as written in lisp/init-org.el."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/init-org.el" user-emacs-directory))
    (goto-char (point-min))
    (let (form value)
      (while (setq form (ignore-errors (read (current-buffer))))
        (unless value
          (setq value (rata-test--find-setq-value form 'org-agenda-custom-commands))))
      value)))

(ert-deftest rata-test-work-agenda-has-dated-block ()
  "The work agenda leads with an `agenda' block, so it prints day headers.
A `tags-todo' block has no date axis; that is why the view could only
bucket things as \"Due Soon\" before."
  (let* ((entry (assoc "w" (rata-test--org-agenda-custom-commands)))
         (blocks (nth 2 entry)))
    (should entry)
    (should (memq 'agenda (mapcar #'car blocks)))
    ;; The dashboard's dated block is the pattern this copied -- keep it too.
    (should (memq 'agenda (mapcar #'car (nth 2 (assoc "d" (rata-test--org-agenda-custom-commands))))))))

(ert-deftest rata-test-work-agenda-filter-is-global ()
  "`org-agenda-tag-filter-preset\=' sits in the command's global settings slot.
Its docstring (org-agenda.el:3834) is explicit that defining it for one
block of a block agenda \"will not work reliably\"."
  (let* ((entry (assoc "w" (rata-test--org-agenda-custom-commands)))
         (global (nth 3 entry)))
    (should (assq 'org-agenda-tag-filter-preset global))
    (should (equal (eval (cadr (assq 'org-agenda-tag-filter-preset global)) t)
                   '("+work")))
    ;; ...and nowhere else: a per-block copy is the failure this guards.
    (dolist (block (nth 2 entry))
      (should-not (assq 'org-agenda-tag-filter-preset (nth 2 block))))))

(ert-deftest rata-test-work-agenda-backlog-keeps-far-deadlines ()
  "The backlog discards dated items only after \"Due later\" has claimed its own.
org-super-agenda applies groups in list order, so a `:discard' placed
first would swallow every deadline -- including the ones beyond the
calendar's horizon, which then appear in neither block."
  (skip-unless (require 'org nil t))
  (let* ((entry (assoc "w" (rata-test--org-agenda-custom-commands)))
         (backlog (cl-find 'tags-todo (nth 2 entry) :key #'car))
         (groups (eval (cadr (assq 'org-super-agenda-groups (nth 2 backlog))) t))
         (due-later (cl-position-if (lambda (g) (equal (plist-get g :name) "Due later"))
                                    groups))
         (discard (cl-position-if (lambda (g) (plist-member g :discard)) groups)))
    (should due-later)
    (should discard)
    (should (< due-later discard))
    ;; Selectors inside one group are OR'ed (org-super-agenda.el:1222), so this
    ;; one discard drops an item carrying either a SCHEDULED or a DEADLINE.
    (let ((selectors (plist-get (nth discard groups) :discard)))
      (should (plist-member selectors :scheduled))
      (should (plist-member selectors :deadline)))
    ;; The boundary has to line up with the calendar: "Due later" must start the
    ;; day after the last day the `agenda' block shows, or a deadline falls
    ;; through the gap between the two blocks.
    (should (equal (plist-get (nth due-later groups) :deadline)
                   `(after ,(rata-org-work-agenda-horizon))))))

(ert-deftest rata-test-work-agenda-horizon-is-calendrical ()
  "The horizon is exactly the calendar's last day, DST or no DST.
Computed by absolute day number rather than by adding 86400-second days,
which would land on 23:00 the previous day across a DST boundary and
report a horizon one day short."
  (skip-unless (require 'org nil t))
  (should (= (org-time-string-to-absolute (rata-org-work-agenda-horizon))
             (+ (org-today) (1- rata-org-work-agenda-span))))
  (let ((rata-org-work-agenda-span 1))
    (should (= (org-time-string-to-absolute (rata-org-work-agenda-horizon))
               (org-today))))
  ;; A whole year of start dates, each side of both European DST switches.
  (dolist (offset (number-sequence 0 364))
    (let ((rata-org-work-agenda-span (1+ offset)))
      (should (= (org-time-string-to-absolute (rata-org-work-agenda-horizon))
                 (+ (org-today) offset))))))

;;; ============================================================
;;; Run all tests
;;; ============================================================

(ert-run-tests-batch-and-exit)
