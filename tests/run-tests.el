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
          (when-let* ((next (cadr items)))
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
    ("SPC J j" . jira-issues)
    ("SPC J l" . rata-jira-org-link-heading)
    ("SPC o b d d" . rata-dialogic-insert-block)
    ("SPC o b e" . org-hugo-export-wim-to-md)
    ("SPC o b s" . rata-blog-status)
    ("SPC i o p" . org-id-get-create)
    ("SPC i o a" . rata-roam-alias-add-to-file)
    ;; agent-shell's context senders are not autoloaded upstream, so these
    ;; resolve only while their symbols stay in init-llm.el's :commands list.
    ("SPC a i c f" . rata-agent-shell-send-file)
    ("SPC a i c r" . agent-shell-send-region)
    ("SPC a i c d" . agent-shell-send-dwim))
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

(ert-deftest rata-test-jira-issues-page-size-is-raised ()
  "The issues list asks for more than upstream\='s 30 per page.
On Jira Server/DC -- what `rata-jira-api-version\=' 2 means -- `search/jql\='
404s and jira.el falls back to the legacy `search\=' endpoint, which
paginates with `startAt\='/`total\='.  jira.el reads neither: it only looks for
`nextPageToken\=' (jira-issues.el:179) and only sends one
\(jira-issues.el:107).  `M-n\=' therefore always answers \"No more pages.\" and
the list is silently truncated to one page with no total shown.  Page size
is the only knob that does not patch upstream, so it must not drift back to
the default."
  (skip-unless (require 'jira-issues nil t))
  (should (integerp jira-issues-max-results))
  (should (> jira-issues-max-results 30)))

(ert-deftest rata-test-jira-issues-single-page-assumption-still-holds ()
  "jira.el still has no `startAt\=' paging, so the page-size workaround is still needed.
If upstream gains `startAt\=' support this test fails and
`rata-test-jira-issues-page-size-is-raised\=' can be reconsidered."
  ;; `find-library-name' resolves to the .el source; `locate-library' can hand
  ;; back a .elc, whose byte-compiled body would not contain the string either
  ;; and would pass vacuously.
  (let ((src (ignore-errors (find-library-name "jira-issues"))))
    ;; Not `skip-unless': a permanently skipped test reads as coverage and is
    ;; not.  If the source cannot be found, that is itself the failure.
    (should (and src (file-readable-p src)))
    (with-temp-buffer
      (insert-file-contents src)
      (should-not (string-match-p "startAt" (buffer-string))))))

(ert-deftest rata-test-jira-base-url-normalisation ()
  "A trailing slash in `rata-jira-base-url\=' is dropped, not passed through."
  (should (equal (directory-file-name "https://acme.atlassian.net/")
                 "https://acme.atlassian.net"))
  (should (equal (directory-file-name "https://acme.atlassian.net")
                 "https://acme.atlassian.net")))

(ert-deftest rata-test-jira-exclusion-jql-is-well-formed ()
  "`rata-jira-exclusion-jql' quotes each status and joins them into one clause.
Pure: string list in, JQL out, no instance needed."
  (should-not (rata-jira-exclusion-jql nil))
  (should (equal (rata-jira-exclusion-jql '("DONE"))
                 "status not in (\"DONE\")"))
  (should (equal (rata-jira-exclusion-jql '("A" "B C"))
                 "status not in (\"A\", \"B C\")"))
  ;; A quote inside a status name is escaped rather than closing the literal.
  (should (equal (rata-jira-exclusion-jql '("a\"b"))
                 "status not in (\"a\\\"b\")"))
  ;; And the configured list is what the operator asked for.
  (let ((jql (rata-jira-exclusion-jql rata-jira-excluded-statuses)))
    (dolist (status '("CLOSED" "DEPLOYED" "DONE" "REJECTED"))
      (should (string-match-p (regexp-quote (concat "\"" status "\"")) jql)))))

(ert-deftest rata-test-jira-default-jql-composes-with-upstream ()
  "The exclusion is added to jira.el's default arguments, never in place of them.
`rata-jira--default-jql-value' is a `:filter-return' advice, so whatever
upstream puts in the default list (`--myself', `jira-issues-default-type')
has to survive it, and an explicit `--jql=' has to win."
  (let ((out (rata-jira--default-jql-value '("--myself" "--type=Bug"))))
    (should (member "--myself" out))
    (should (member "--type=Bug" out))
    (should (member (concat "--jql=" (rata-jira-exclusion-jql
                                      rata-jira-excluded-statuses))
                    out)))
  ;; An explicit JQL is left alone: exactly one --jql= comes out.
  (let ((out (rata-jira--default-jql-value '("--myself" "--jql=project = X"))))
    (should (equal out '("--myself" "--jql=project = X"))))
  ;; Empty list of statuses: upstream's default, untouched.
  (let ((rata-jira-excluded-statuses nil))
    (should (equal (rata-jira--default-jql-value '("--myself")) '("--myself")))))

(ert-deftest rata-test-jira-default-query-reaches-the-transient ()
  "The finished statuses are actually excluded from the query `jira-issues' runs.
Three things have to hold together and only this test sees all three: jira.el
still computes its default through `jira-issues--transient-default-value' (a
private function -- `advice-add' on a renamed one succeeds and does nothing),
the advice is installed on it, and the resulting value is what
`jira-issues--refresh' reads back out of the prefix as `--jql='.
`transient-values' is bound to nil because a value the operator persisted with
`C-x C-s' on this machine would otherwise decide the answer."
  (should (require 'jira-issues nil t))
  (should (fboundp 'jira-issues--transient-default-value))
  (should (advice-member-p #'rata-jira--default-jql-value
                           'jira-issues--transient-default-value))
  (let* ((transient-values nil)
         (expected (rata-jira-exclusion-jql rata-jira-excluded-statuses))
         (args (transient-args 'jira-issues-menu)))
    ;; Read back exactly as jira-issues--refresh does (jira-issues.el:201).
    (should (equal (transient-arg-value "--jql=" args) expected))
    ;; ...and upstream's own default is still in force alongside it.
    (should (transient-arg-value "--myself" args))))

(ert-deftest rata-test-jira-agile-url-passes-through-jira-api ()
  "An Agile URL built by `rata-jira-agile-url' survives `jira-api--url' untouched.
The sprint commands reuse `jira-api-call' for auth and error handling by
handing it a full `/rest/agile/1.0/' URL, which works only because
`jira-api--url' passes an endpoint through when it already starts with the base
URL (jira-api.el:174).  This binds that assumption to upstream's code: if it
changes, this fails instead of every sprint move 404ing under `/rest/api/N/'."
  (let* ((base "https://jira.example.com")
         (url (rata-jira-agile-url base "sprint/42/issue")))
    (should (equal url "https://jira.example.com/rest/agile/1.0/sprint/42/issue"))
    ;; Trailing slash on the base and leading slash on the endpoint both fold away.
    (should (equal (rata-jira-agile-url "https://jira.example.com/" "/backlog/issue")
                   "https://jira.example.com/rest/agile/1.0/backlog/issue"))
    (should (require 'jira-api nil t))
    (should (equal (jira-api--url base url) url))
    ;; ...and a bare endpoint still gets the REST prefix, so the two families
    ;; do not collide.
    (should (string-match-p "/rest/api/[0-9]+/issue/X\\'" (jira-api--url base "issue/X")))))

(ert-deftest rata-test-jira-open-sprints-put-the-active-one-first ()
  "The active sprint leads the list and is labelled; closed sprints are dropped.
The operator's board is one never-ending sprint, so the default offered by
`rata-jira-move-to-sprint' has to be the active one, visibly."
  (let* ((sprints '(((id . 3) (name . "Future") (state . "future"))
                    ((id . 1) (name . "Old") (state . "closed"))
                    ((id . 2) (name . "Board") (state . "active")
                     (endDate . "2030-01-01T10:00:00.000+02:00"))))
         (open (rata-jira-open-sprints sprints)))
    (should (equal (mapcar (lambda (s) (alist-get 'id s)) open) '(2 3)))
    (should (equal (alist-get 'id (rata-jira-active-sprint open)) 2))
    (should (equal (rata-jira-sprint-label (car open)) "Board  [active]  ends 2030-01-01"))
    (should (equal (rata-jira-sprint-label (cadr open)) "Future  [future]"))
    (should-not (rata-jira-active-sprint '(((id . 3) (name . "F") (state . "future")))))))

(ert-deftest rata-test-jira-move-payloads-are-chunked-at-fifty ()
  "Issue keys are sent as a JSON array, at most 50 per request, in order."
  (should (equal (rata-jira-move-payloads '("A-1" "A-2"))
                 '((("issues" . ["A-1" "A-2"])))))
  (should-not (rata-jira-move-payloads nil))
  (let* ((keys (mapcar (lambda (i) (format "A-%d" i)) (number-sequence 1 120)))
         (bodies (rata-jira-move-payloads keys)))
    (should (= (length bodies) 3))
    (should (equal (mapcar (lambda (b) (length (alist-get "issues" b nil nil #'equal)))
                           bodies)
                   '(50 50 20)))
    (should (equal (aref (alist-get "issues" (car bodies) nil nil #'equal) 0) "A-1"))
    (should (equal (aref (alist-get "issues" (caddr bodies) nil nil #'equal) 19) "A-120"))
    ;; What actually goes on the wire.
    (should (equal (json-encode (car (rata-jira-move-payloads '("A-1"))))
                   "{\"issues\":[\"A-1\"]}"))))

(ert-deftest rata-test-jira-agile-error-message-uses-jiras-words ()
  "Jira's `errorMessages' and `errors' are joined into one line; nothing gives nil."
  (should (equal (rata-jira-agile-error-message
                  '((errorMessages . ["Sprint does not exist"])))
                 "Sprint does not exist"))
  (should (equal (rata-jira-agile-error-message
                  '((errorMessages . []) (errors . ((issues . "Issue X not found")))))
                 "issues: Issue X not found"))
  (should (equal (rata-jira-agile-error-message
                  '((errorMessages . ["a" "b"]) (errors . ((f . "c")))))
                 "a; b; f: c"))
  (should-not (rata-jira-agile-error-message nil))
  (should-not (rata-jira-agile-error-message '((errorMessages . [])))))

(ert-deftest rata-test-jira-sprint-keys-name-real-commands ()
  "Every sprint key binds an interactive `rata-jira-' command that exists.
The bindings are built from `rata-jira-sprint-keys' by `general', which binds a
symbol without checking it, so a typo here would be a dead key."
  (let ((defs (seq-filter #'consp rata-jira-sprint-keys)))
    (should (> (length defs) 1))
    (dolist (def defs)
      (unless (eq (car def) :ignore)
        (should (commandp (car def)))
        (should (string-prefix-p "rata-jira-" (symbol-name (car def))))
        (should (plist-get (cdr def) :which-key))))))

(ert-deftest rata-test-jira-sprint-info-reads-both-field-shapes ()
  "The Sprint field element is read whether it is an object or a Java toString.
Cloud and recent Server/DC send objects; older Server/DC sends
`...Sprint@1a2b[id=7,...,state=ACTIVE,name=Board,...]'.  Upstream's formatter
signals on the string form; this module must not."
  (should (equal (rata-jira-sprint-info '((id . 7) (name . "Board") (state . "active")))
                 '("Board" . "active")))
  (should (equal (rata-jira-sprint-info '((name . "Board") (state . "CLOSED")))
                 '("Board" . "closed")))
  (should (equal (rata-jira-sprint-info '((name . "Board")))
                 '("Board" . "")))
  (should (equal (rata-jira-sprint-info
                  (concat "com.atlassian.greenhopper.service.sprint.Sprint@1a2b"
                          "[id=7,rapidViewId=3,state=ACTIVE,name=Board, week 2,"
                          "startDate=2026-09-01T08:00:00.000+02:00,endDate=<null>,"
                          "completeDate=<null>,sequence=7,goal=]"))
                 '("Board, week 2" . "active")))
  (should (equal (rata-jira-sprint-info "Sprint@1[id=1,state=FUTURE,name=Next]")
                 '("Next" . "future")))
  (should-not (rata-jira-sprint-info "not a sprint"))
  (should-not (rata-jira-sprint-info nil))
  (should-not (rata-jira-sprint-info 42)))

(ert-deftest rata-test-jira-current-sprint-ignores-closed-history ()
  "The Sprint field lists every sprint the issue was ever in; only an open one counts.
An issue whose sprints are all closed is backlog, and active beats future."
  (should-not (rata-jira-current-sprint nil))
  (should-not (rata-jira-current-sprint ""))
  (should-not (rata-jira-current-sprint []))
  (should-not (rata-jira-current-sprint [((name . "Old") (state . "closed"))]))
  (should (equal (rata-jira-current-sprint
                  [((name . "Old") (state . "closed"))
                   ((name . "Later") (state . "future"))
                   ((name . "Board") (state . "active"))])
                 '("Board" . "active")))
  (should (equal (rata-jira-current-sprint '(((name . "Later") (state . "future"))))
                 '("Later" . "future")))
  ;; The column: name for the board, name plus state for anything else, "" for backlog.
  (should (equal (rata-jira-fmt-sprint [((name . "Board") (state . "active"))]) "Board"))
  (should (equal (rata-jira-fmt-sprint [((name . "Later") (state . "future"))])
                 "Later (future)"))
  (should (equal (rata-jira-fmt-sprint [((name . "Old") (state . "closed"))]) ""))
  (should (equal (rata-jira-fmt-sprint "") "")))

(ert-deftest rata-test-jira-group-issues-orders-board-then-backlog ()
  "Groups come active sprint, other open sprints by name, then Backlog, with counts.
Entries keep their order inside a group, and an empty group does not appear."
  (let* ((sprints '(("A-1" . ("Zeta" . "future"))
                    ("A-2" . nil)
                    ("A-3" . ("Board" . "active"))
                    ("A-4" . ("Alpha" . "future"))
                    ("A-5" . nil)
                    ("A-6" . ("Board" . "active"))))
         (entries (mapcar (lambda (s) (list (car s) (vector (car s)))) sprints))
         (groups (rata-jira-group-issues
                  entries (lambda (key) (cdr (assoc key sprints))))))
    (should (equal (mapcar (lambda (g) (substring-no-properties (car g))) groups)
                   '("Board  [active]  (2)" "Alpha  [future]  (1)"
                     "Zeta  [future]  (1)" "Backlog  (2)")))
    (should (equal (mapcar (lambda (g) (mapcar #'car (cdr g))) groups)
                   '(("A-3" "A-6") ("A-4") ("A-1") ("A-2" "A-5"))))
    (should (eq (get-text-property 0 'face (car (car groups))) 'rata-jira-group-heading))
    ;; Nothing in the backlog: no Backlog heading.
    (should (equal (mapcar #'car (rata-jira-group-issues
                                  (list (list "A-3" ["A-3"]))
                                  (lambda (_) '("Board" . "active"))))
                   (list (rata-jira-group-heading '("Board" . "active") 1))))
    (should-not (rata-jira-group-issues nil #'ignore))))

(ert-deftest rata-test-jira-custom-field-parent-resolves-to-its-id ()
  "A `(custom NAME)' column parent reaches the search request as `customfield_NNN'.
Without the advice, `jira-issues--api-get-issues' formats the parent with `%s'
and asks the server for a field named \"(custom Sprint)\": the column is blank
and nothing reports it (L-042).  The other advice fetches the field list
before the first search, so the id is known on the first `jira-issues' too."
  (should (require 'jira-issues nil t))
  (should (advice-member-p #'rata-jira--resolve-custom-parent 'jira-table-field-parent))
  (should (advice-member-p #'rata-jira--ensure-fields 'jira-issues--api-get-issues))
  (should (memq :rata-sprint jira-issues-table-fields))
  (should (equal (jira-table-field-name jira-issues-fields :rata-sprint) "Sprint"))
  (let ((jira-fields '(("Sprint" . "customfield_10020"))))
    (should (equal (jira-table-field-parent jira-issues-fields :rata-sprint)
                   "customfield_10020"))
    ;; Upstream's own custom columns are fixed by the same advice.
    (should (equal (jira-table-field-parent jira-issues-fields :sprints)
                   "customfield_10020"))
    ;; Ordinary fields are untouched.
    (should (eq (jira-table-field-parent jira-issues-fields :summary) 'summary)))
  (let ((jira-fields nil))
    (should-not (jira-table-field-parent jira-issues-fields :rata-sprint)))
  ;; The field list is read out of the `field' endpoint: Cloud sends `key',
  ;; Server/DC only `id'.  Upstream reads `key' alone, which is why every
  ;; custom field was nil on the operator's instance (FAIL-0017).
  (should (equal (rata-jira--fields-from-response
                  [((id . "customfield_10020") (key . "customfield_10020") (name . "Sprint"))
                   ((id . "summary") (key . "summary") (name . "Summary"))])
                 '(("Sprint" . "customfield_10020") ("Summary" . "summary"))))
  (should (equal (rata-jira--fields-from-response
                  [((id . "customfield_10005") (name . "Sprint") (custom . t))
                   ((id . "summary") (name . "Summary"))])
                 '(("Sprint" . "customfield_10005") ("Summary" . "summary"))))
  ;; ...and an all-nil list counts as unusable, so it is fetched again.
  (should-not (rata-jira--fields-usable-p nil))
  (should-not (rata-jira--fields-usable-p '(("Sprint" . nil) ("Summary" . nil))))
  (should (rata-jira--fields-usable-p '(("Sprint" . "customfield_10005"))))
  (should (advice-member-p #'rata-jira--get-fields-advice 'jira-api-get-fields)))

(defun rata-test--jira-issue (key summary sprints)
  "A raw Jira issue fixture with KEY, SUMMARY and a Sprint field of SPRINTS."
  `((key . ,key)
    (fields . ((summary . ,summary)
               (status . ((name . "Open") (statusCategory . ((name . "To Do")))))
               (customfield_10020 . ,sprints)))))

(defun rata-test--jira-marked-lines ()
  "Return the buffer lines carrying a tablist mark."
  (save-excursion
    (goto-char (point-min))
    (let (marked)
      (while (re-search-forward (tablist-marker-regexp) nil t)
        (push (buffer-substring-no-properties (line-beginning-position) (line-end-position))
              marked))
      (nreverse marked))))

(ert-deftest rata-test-jira-issues-list-groups-by-sprint ()
  "The real `jira-issues-mode' prints sprint headings, and tablist survives them.
Headings are Emacs's `tabulated-list-groups'; tablist predates them and three of
its commands assume every line is an entry.  This prints a fixture list through
the mode with no network and then marks (`m', `t', `U'), filters and sorts (`S')
in it, all of which must neither signal nor move a heading."
  (should (require 'jira-issues nil t))
  (let* ((jira-fields '(("Sprint" . "customfield_10020")))
         (jira-issues-table-fields '(:key :status-name :rata-sprint :summary))
         (rata-jira-group-by-sprint t)
         ;; The older Server/DC shape, as one issue among object-shaped ones.
         (legacy (concat "com.atlassian.greenhopper.service.sprint."
                         "Sprint@1a[id=9,rapidViewId=3,state=FUTURE,"
                         "name=Next up,startDate=<null>,"
                         "endDate=<null>,sequence=9,goal=]"))
         (issues (vector
                  (rata-test--jira-issue "A-3" "gamma" nil)
                  (rata-test--jira-issue "A-2" "beta"
                                         [((name . "Old") (state . "closed"))
                                          ((name . "Board") (state . "active"))])
                  (rata-test--jira-issue "A-1" "alpha" [((name . "Old") (state . "closed"))])
                  (rata-test--jira-issue "A-4" "delta" (vector legacy)))))
    (with-temp-buffer
      (jira-issues-mode)
      (should (eq tabulated-list-groups #'rata-jira--issue-groups))
      (should (seq-position tabulated-list-format "Sprint"
                            (lambda (col name) (equal (car col) name))))
      (let ((jira-issues--raw-issues issues)
            (lines (lambda ()
                     (split-string (buffer-substring-no-properties (point-min) (point-max))
                                   "\n" t))))
        (setq tabulated-list-entries
              (mapcar #'jira-issues--data-format-issue (append issues nil)))
        (tabulated-list-print)
        ;; Board first, then the future sprint, then the backlog; the closed
        ;; sprint A-1 carries puts it in the backlog, not in a group of its own.
        (let ((got (funcall lines)))
          (should (= (length got) 7))
          (should (string-prefix-p "Board  [active]  (1)" (nth 0 got)))
          (should (string-match-p "\\`  A-2 .*Board.*beta" (nth 1 got)))
          (should (string-prefix-p "Next up  [future]  (1)" (nth 2 got)))
          (should (string-match-p "\\`  A-4 .*Next up (future).*delta" (nth 3 got)))
          (should (string-prefix-p "Backlog  (2)" (nth 4 got)))
          (should (string-match-p "\\`  A-3 " (nth 5 got)))
          (should (string-match-p "\\`  A-1 " (nth 6 got))))
        ;; Marking.  `m' on an issue marks it; `t' and `U' walk every line.
        (goto-char (point-min))
        (forward-line 1)
        (tablist-mark-forward)
        (should (equal (jira-utils-marked-items) '("A-2")))
        (tablist-toggle-marks)
        (should (equal (sort (jira-utils-marked-items) #'string<) '("A-1" "A-3" "A-4")))
        (tablist-unmark-all-marks)
        ;; Not `jira-utils-marked-items': with nothing marked, tablist falls back
        ;; to the line at point, and that is the tablist convention, not a bug here.
        (should-not (rata-test--jira-marked-lines))
        ;; `m' on a heading is a no-op, not an error.
        (goto-char (point-min))
        (tablist-mark-forward)
        (should-not (rata-test--jira-marked-lines))
        ;; A regexp filter hides non-matching issues and leaves every heading alone.
        (setq tablist-current-filter '(=~ "Summary" "^b"))
        (tablist-apply-filter)
        (goto-char (point-min))
        (should-not (invisible-p (point)))
        (search-forward "A-2")
        (should-not (invisible-p (line-beginning-position)))
        (search-forward "Next up  [future]")
        (should-not (invisible-p (line-beginning-position)))
        (search-forward "A-4")
        (should (invisible-p (line-beginning-position)))
        (search-forward "Backlog")
        (should-not (invisible-p (line-beginning-position)))
        (search-forward "A-1")
        (should (invisible-p (line-beginning-position)))
        (setq tablist-current-filter nil)
        (tablist-apply-filter)
        ;; `S' sorts inside each group; the headings stay where they are.
        (tablist-sort "Summary")
        (let ((got (funcall lines)))
          (should (string-prefix-p "Board  [active]  (1)" (nth 0 got)))
          (should (string-prefix-p "Next up  [future]  (1)" (nth 2 got)))
          (should (string-prefix-p "Backlog  (2)" (nth 4 got)))
          (should (string-match-p "\\`  A-1 " (nth 5 got)))
          (should (string-match-p "\\`  A-3 " (nth 6 got))))
        ;; Sorting from a heading names the problem instead of "Cannot sort by nil".
        (goto-char (point-min))
        (should-error (tablist-sort) :type 'user-error)
        ;; Toggling grouping off prints a plain list, on brings the headings back.
        (rata-jira-toggle-sprint-grouping)
        (should-not tabulated-list-groups)
        (should (= (length (funcall lines)) 4))
        (should-not (seq-some (lambda (l) (string-prefix-p "Backlog" l)) (funcall lines)))
        (rata-jira-toggle-sprint-grouping)
        (should (= (length (funcall lines)) 7))))))

(ert-deftest rata-test-jira-org-keys-come-from-the-property-only ()
  "`rata-jira-org-keys-in-string' reads `:JIRA:' properties and nothing else.
A key in a title or a link is not a claim that the heading is that issue; the
property name is case-insensitive as org treats it; duplicates collapse."
  (should (equal (rata-jira-org-keys-in-string
                  (concat "* TODO Fix A-1 for real\n"
                          ":PROPERTIES:\n:JIRA: A-2\n:JIRA_URL: https://x/browse/A-3\n:END:\n"
                          "[[https://x/browse/A-4][A-4]]\n"
                          "** STRT other\n  :PROPERTIES:\n  :jira:   b-7  \n  :END:\n"
                          "** DONE again\n:PROPERTIES:\n:JIRA: A-2\n:END:\n"))
                 '("A-2" "B-7")))
  (should-not (rata-jira-org-keys-in-string "* TODO nothing\n")))

(ert-deftest rata-test-jira-org-entry-shape ()
  "An imported entry is a TODO heading, a `:JIRA:' drawer and a link -- no more.
The summary is one line, the tags are `rata-jira-org-tags', the key in the
drawer is what `rata-jira-org-keys-in-string' reads back, and the base URL's
trailing slash does not double up in the link."
  (let* ((rata-jira-org-tags '("work" "jira"))
         (issue (rata-test--jira-issue "PROJ-42" "Fix  the\n  thing  " nil))
         ;; Local time; the fixture's LANG must not leak into the day name.
         (entry (rata-jira-org-entry issue 2 "https://jira.example.com/"
                                     (encode-time '(0 30 9 11 9 2026 nil -1 nil)))))
    (should (string-prefix-p "** TODO Fix the thing :work:jira:\n:PROPERTIES:\n:JIRA: PROJ-42\n"
                             entry))
    (should (string-match-p "^:CREATED: \\[2026-09-11 Fri 09:30\\]\n:END:\n" entry))
    (should (string-suffix-p "[[https://jira.example.com/browse/PROJ-42][PROJ-42]]\n" entry))
    (should (equal (rata-jira-org-keys-in-string entry) '("PROJ-42")))
    ;; Nothing that goes stale: no status, type or assignee line.
    (should-not (string-match-p "Open\\|To Do" entry))
    ;; No tags configured, no tag string; an empty summary falls back to the key.
    (let ((rata-jira-org-tags nil))
      (should (string-prefix-p "* TODO PROJ-42\n"
                               (rata-jira-org-entry (rata-test--jira-issue "PROJ-42" "" nil)
                                                    1 "https://j"))))))

(defconst rata-test--jira-org-fixture
  (concat ":PROPERTIES:\n:ID:       00000000-0000-0000-0000-000000000000\n:END:\n"
          "#+title: work tasks\n#+filetags: :work:hastodo:\n"
          "#+SEQ_TODO: TODO STRT WAIT | DONE\n\n"
          "* Work tasks\nMy work tasks.\n** Kanban board\n"
          "#+BEGIN: kanban :mirrored t\n| TODO |\n|------|\n#+END:\n\n"
          "* Tasks                                                                :work:\n"
          "** TODO Hand-written task                                            :zenml:\n"
          "Quoted note from a colleague.\n#+begin_quote\nA brief for the loop.\n#+end_quote\n"
          "*** Sub-step\n"
          "** STRT Already linked\n:PROPERTIES:\n:JIRA: A-1\n:END:\n\n"
          "* Notes\nA section after Tasks that must stay after Tasks.\n")
  "A `work_tasks.org' look-alike: kanban block, hand-written entries, a linked one.")

(defun rata-test--jira-import-into-fixture (issues &optional fixture)
  "Import raw ISSUES into a temp copy of FIXTURE; return (RESULT . NEW-TEXT).
Kills the visiting buffer and deletes the file afterwards."
  (let ((file (make-temp-file "rata-jira-org-" nil ".org"
                              (or fixture rata-test--jira-org-fixture)))
        (rata-jira--org-keys-cache nil))
    (unwind-protect
        (let ((result (rata-jira-org-import-issues issues file "https://jira.example.com")))
          (cons result
                (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (when-let ((buf (find-buffer-visiting file))) (kill-buffer buf))
      (delete-file file))))

(ert-deftest rata-test-jira-import-appends-new-issues-only ()
  "The import appends under `Tasks', skips issues already there and touches nothing else.
Byte-for-byte: the file after the import is the fixture with the new entries
inserted after the last line of the `Tasks' subtree and nothing else changed --
not the hand-written body, not the quote, not the section after, not the
blank line before it.  A second import adds nothing."
  (let* ((rata-jira-org-tags '("work" "jira"))
         (rata-jira-org-refresh-kanban nil)
         (issues (list (rata-test--jira-issue "A-1" "already linked, must be skipped" nil)
                       (rata-test--jira-issue "A-2" "beta" nil)
                       (rata-test--jira-issue "A-3" "gamma" nil)
                       (rata-test--jira-issue "A-2" "beta again, a duplicate" nil)))
         (got (rata-test--jira-import-into-fixture issues))
         (normalised (replace-regexp-in-string "^:CREATED: .*$" ":CREATED: X" (cdr got)))
         (entry (lambda (key title)
                  (format "** TODO %s :work:jira:\n:PROPERTIES:\n:JIRA: %s\n:CREATED: X\n:END:\n[[https://jira.example.com/browse/%s][%s]]\n"
                          title key key key)))
         (expected (replace-regexp-in-string
                    (regexp-quote ":JIRA: A-1\n:END:\n\n* Notes")
                    (concat ":JIRA: A-1\n:END:\n"
                            (funcall entry "A-2" "beta") (funcall entry "A-3" "gamma")
                            "\n* Notes")
                    rata-test--jira-org-fixture t t)))
    (should (equal (car got) '(("A-2" "A-3") . ("A-1" "A-2"))))
    (should (equal normalised expected))
    ;; Idempotent: the same import on the result changes nothing.
    (let ((again (rata-test--jira-import-into-fixture issues (cdr got))))
      (should (equal (car again) (cons nil '("A-1" "A-2" "A-3" "A-2"))))
      (should (equal (cdr again) (cdr got))))
    ;; No `Tasks' heading is an error naming it, not a silent append somewhere.
    (should-error (rata-test--jira-import-into-fixture
                   (list (rata-test--jira-issue "A-9" "x" nil))
                   "* Not the heading\n")
                  :type 'user-error)))

(ert-deftest rata-test-jira-import-refreshes-the-kanban-block ()
  "With `rata-jira-org-refresh-kanban', a new heading lands on the kanban board too.
The fixture's block is `:mirrored t' with one TODO column, empty; after the
import it has to list the new heading, or the board lies about the file."
  (skip-unless (fboundp 'org-dblock-write:kanban))
  (let* ((rata-jira-org-refresh-kanban t)
         (got (rata-test--jira-import-into-fixture
               (list (rata-test--jira-issue "A-5" "epsilon" nil)))))
    (should (equal (car got) '(("A-5") . nil)))
    (should (string-match-p "^#\\+BEGIN: kanban :mirrored t\n\\(?:.*\n\\)*?|.*epsilon.*|\n\\(?:.*\n\\)*?#\\+END:"
                            (cdr got)))))

(ert-deftest rata-test-jira-link-heading-sets-what-the-import-reads ()
  "`rata-jira-org-link-heading' writes the property the import and the column key on.
It also tags the heading; it refuses a string that is not an issue key, and
a buffer with no heading at point."
  (require 'org)
  (let ((rata-jira-org-tags '("work" "jira")))
    (with-temp-buffer
      (org-mode)
      (insert "* TODO Written before Jira\nsome body\n")
      (goto-char (point-max))
      (rata-jira-org-link-heading "proj-7")
      (should (equal (org-entry-get (point-min) "JIRA") "PROJ-7"))
      (should (equal (rata-jira-org-keys-in-string (buffer-string)) '("PROJ-7")))
      (goto-char (point-min))
      (should (equal (sort (org-get-tags nil t) #'string<) '("jira" "work")))
      (should-error (rata-jira-org-link-heading "not a key") :type 'user-error))
    (with-temp-buffer
      (org-mode)
      (insert "no heading here\n")
      (should-error (rata-jira-org-link-heading "A-1") :type 'user-error))
    (with-temp-buffer
      (fundamental-mode)
      (should-error (rata-jira-org-link-heading "A-1") :type 'user-error))))

(ert-deftest rata-test-jira-issues-list-marks-issues-already-in-org ()
  "The Org column marks exactly the issues whose key the org file carries.
Printed through the real `jira-issues-mode' against a temp file, so the
formatter, the field registration and the file cache are all exercised; the
cache notices the file changing on disk."
  (should (require 'jira-issues nil t))
  (let* ((file (make-temp-file "rata-jira-org-" nil ".org"
                               "* Tasks\n** TODO x\n:PROPERTIES:\n:JIRA: A-2\n:END:\n"))
         (rata-jira-org-file file)
         (rata-jira--org-keys-cache nil)
         (rata-jira-org-mark "✓")
         (rata-jira-group-by-sprint nil)
         ;; `:status-name' stays: jira.el's initial sort column is Status.
         (jira-issues-table-fields '(:key :rata-org :status-name :summary))
         (issues (vector (rata-test--jira-issue "A-2" "beta" nil)
                         (rata-test--jira-issue "A-3" "gamma" nil)))
         (lines (lambda ()
                  (split-string (buffer-substring-no-properties (point-min) (point-max))
                                "\n" t))))
    (unwind-protect
        (with-temp-buffer
          (jira-issues-mode)
          (should (seq-position tabulated-list-format "Org"
                                (lambda (col name) (equal (car col) name))))
          (let ((jira-issues--raw-issues issues))
            (setq tabulated-list-entries
                  (mapcar #'jira-issues--data-format-issue (append issues nil)))
            (tabulated-list-print)
            (let ((got (funcall lines)))
              (should (string-match-p "\\`  A-2 +✓ +Open +beta" (nth 0 got)))
              (should (string-match-p "\\`  A-3 +Open +gamma" (nth 1 got))))
            ;; Link A-3 on disk; the next print picks it up without a request.
            (sleep-for 0.01)
            (with-temp-file file
              (insert "* Tasks\n** TODO x\n:PROPERTIES:\n:JIRA: A-2\n:END:\n"
                      "** TODO y\n:PROPERTIES:\n:JIRA: A-3\n:END:\n"))
            (rata-jira--redraw-issues)
            (should (string-match-p "\\`  A-3 +✓ +Open +gamma" (nth 1 (funcall lines))))))
      (delete-file file))))

(defun rata-test--use-package-forms-with-config ()
  "Return ((PKG . COMMANDS) ...) for `use-package\=' forms in lisp/ that have both.

Only forms carrying `:commands\=' AND a `:config\=' block are returned: those are
the ones where the question \"does this `:config\=' ever run?\" has teeth, because
the package is reached through an autoloaded command rather than eagerly.

Arguments are grouped by keyword by hand.  `plist-get\=' is wrong on a
`use-package\=' body: a keyword may take several values (`:general\=' does), and
`plist-get\=' would then read a value as a key."
  (let (result)
    (dolist (file (directory-files (expand-file-name "lisp" user-emacs-directory)
                                   t "\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (when (and (consp form) (eq (car form) 'use-package) (symbolp (cadr form)))
                  (let ((pkg (cadr form)) (key nil) (cmds nil) (has-config nil))
                    (dolist (arg (cddr form))
                      (if (keywordp arg)
                          (setq key arg)
                        (pcase key
                          (:commands (setq cmds (append cmds (if (listp arg) arg (list arg)))))
                          (:config   (setq has-config t)))))
                    ;; `:config' with a body of only comments still counts as
                    ;; nothing to run, so require an actual form.
                    (when (and cmds has-config)
                      (push (cons pkg cmds) result))))))
          (end-of-file nil))))
    (nreverse result)))

(ert-deftest rata-test-use-package-config-blocks-can-run ()
  "Every `:config\=' block in lisp/ is keyed on a feature something actually loads.

Regression test for .are/memory/failures/FAIL-0016.md, generalising FAIL-0009 one
layer down.  `:config\=' compiles to `(with-eval-after-load \='PKG ...)\=', and for a
multi-file package PKG is often *not* what gets loaded: the `;;;###autoload\='
cookies sit on the commands in the sub-files, so elpaca's autoloads point the
command at `PKG-sub.el\=', and use-package's own `:commands\=' stub — the one that
would have loaded PKG — is skipped by its `(unless (fboundp ...))\=' guard.  If no
sub-file requires the umbrella, the `:config\=' body never runs even once.

`use-package jira\='s\=' whole `:config\=' was dead for exactly this reason, which
left every jira.el key shadowed by evil.

Where the autoload file differs from the feature name, this asserts that loading
that file does reach the feature — statically first (a `require\=' in its source),
then by actually loading it, so a two-hop require chain is not a false positive."
  (let (failures)
    (pcase-dolist (`(,pkg . ,cmds) (rata-test--use-package-forms-with-config))
      (let* ((cmd (car cmds))
             (fn (and (fboundp cmd) (symbol-function cmd)))
             (file (and (consp fn) (eq (car fn) 'autoload) (cadr fn))))
        (cond
         ((not (fboundp cmd))
          (push (format "`use-package %s' declares :commands %s, which is not even fbound"
                        pkg cmd)
                failures))
         ;; Feature already loaded, or the command autoloads the feature's own
         ;; file: `:config' will run.
         ((or (featurep pkg) (null file) (equal file (symbol-name pkg))) nil)
         (t
          (let* ((src (ignore-errors (find-library-name file)))
                 (requires-pkg
                  (and src (file-readable-p src)
                       (with-temp-buffer
                         (insert-file-contents src)
                         (re-search-forward
                          (format "(require '%s)" (regexp-quote (symbol-name pkg)))
                          nil t)))))
            (unless (or requires-pkg
                        (progn (require (intern file) nil t) (featurep pkg)))
              (push (format (concat "`use-package %s' has a :config block, but %s autoloads "
                                    "%s.el, which never provides `%s' — the block never runs")
                            pkg cmd file pkg)
                    failures)))))))
    (when failures
      (ert-fail (concat "Dead use-package :config blocks:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

(ert-deftest rata-test-jira-buffers-keep-evil-and-mirror-keys ()
  "The Jira buffers stay in evil normal state, with jira.el's keys under `,\='.

Regression test for .are/memory/failures/FAIL-0016.md and D-015.  Two failures
are in scope and they pull in opposite directions:

* the original defect — `evil-set-initial-state\=' sat in the `use-package jira\='
  `:config\=' block, which never runs because the feature `jira\=' is never loaded
  here, so nothing configured these buffers at all;
* the current design — the operator wants evil motion in these buffers, so
  normal state is deliberate and jira.el's shadowed keys are mirrored under the
  local leader.  A mirror that is silently not installed looks exactly like the
  original defect from the user's side: a key that does nothing.

So this asserts evil is live, the mirror is reachable, and `RET\=' opens an issue."
  (should (require 'jira-issues nil t))
  (let ((buf (generate-new-buffer "*rata-test-jira-issues*")))
    (unwind-protect
        (with-current-buffer buf
          (jira-issues-mode)
          ;; Evil, not emacs state: `j\=' still moves.
          (should (eq evil-state 'normal))
          (should (eq (key-binding (kbd "j")) 'evil-next-line))
          ;; The key the operator actually pressed, now under the local leader.
          (should (eq (key-binding (kbd ", l")) 'jira-issues-menu))
          (should (eq (key-binding (kbd ", ?")) 'jira-issues-actions-menu))
          ;; This module's own sprint commands share the leader map (D-017).
          (should (eq (key-binding (kbd ", m s")) 'rata-jira-move-to-sprint))
          (should (eq (key-binding (kbd ", m b")) 'rata-jira-move-to-backlog))
          ;; The grouping toggle is list-only (D-018).
          (should (eq (key-binding (kbd ", m g")) 'rata-jira-toggle-sprint-grouping))
          ;; RET opens the issue rather than moving down a line.
          (should-not (eq (key-binding (kbd "RET")) 'evil-ret))
          (should (commandp (key-binding (kbd "RET"))))
          ;; What evil-collection already provides is not re-bound, and must
          ;; keep working: these are the reason the mirror is small.
          (should (eq (key-binding (kbd "q")) 'tablist-quit))
          (should (eq (key-binding (kbd "g r")) 'tablist-revert))
          (should (eq (key-binding (kbd "m")) 'tablist-mark-forward)))
      (kill-buffer buf)))
  ;; The detail buffer is a magit-section child; same mirror, its own map.
  (should (require 'jira-detail nil t))
  (let ((buf (generate-new-buffer "*rata-test-jira-detail*")))
    (unwind-protect
        (with-current-buffer buf
          (jira-detail-mode)
          (should (eq evil-state 'normal))
          (should (eq (key-binding (kbd ", ?")) 'jira-detail--actions-menu))
          (should (eq (key-binding (kbd ", w")) 'jira-detail--watchers-menu))
          (should (eq (key-binding (kbd ", m s")) 'rata-jira-move-to-sprint))
          (should-not (eq (key-binding (kbd ", m g")) 'rata-jira-toggle-sprint-grouping))
          (should (commandp (key-binding (kbd ", c"))))
          ;; magit-section folding survives, which is why `TAB\=' is left alone.
          (should (eq (key-binding (kbd "TAB")) 'magit-section-toggle)))
      (kill-buffer buf))))

(ert-deftest rata-test-jira-mirrored-keys-exist-upstream ()
  "Every mirrored key is still bound by jira.el, and every mirror is installed.

The local-leader mirror is built with `lookup-key\=' against jira.el's own mode
maps (see lisp/init-jira.el), so an upstream rename does not break the module —
it silently drops one leader key.  That is the failure this test exists to make
loud.  It checks both ends: the upstream key still resolves in jira.el's map,
and the mirrored `,\=' suffix resolves to something callable in a live buffer."
  (should (require 'jira-issues nil t))
  (should (require 'jira-detail nil t))
  (should (require 'jira-tempo nil t))
  (let (failures)
    (dolist (spec (list (list 'jira-issues-mode 'jira-issues-mode-map
                              rata-jira-issues-key-mirror)
                        (list 'jira-detail-mode 'jira-detail-mode-map
                              rata-jira-detail-key-mirror)
                        (list 'jira-tempo-mode 'jira-tempo-mode-map
                              rata-jira-tempo-key-mirror)))
      (pcase-let* ((`(,mode ,map-sym ,mirror) spec)
                   (map (symbol-value map-sym))
                   (buf (generate-new-buffer (format "*rata-test-%s*" mode))))
        (unwind-protect
            (with-current-buffer buf
              (funcall mode)
              (pcase-dolist (`(,upstream ,suffix ,label) mirror)
                (let ((up (lookup-key map (kbd upstream)))
                      (mine (key-binding (kbd (concat ", " suffix)))))
                  (when (or (null up) (numberp up))
                    (push (format "%s: jira.el no longer binds `%s\=' (%s)"
                                  mode upstream label)
                          failures))
                  (unless (commandp mine)
                    (push (format "%s: `, %s\=' (%s) is not a command: %S"
                                  mode suffix label mine)
                          failures)))))
          (kill-buffer buf))))
    (when failures
      (ert-fail (concat "Jira local-leader mirror out of sync with jira.el:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

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
;;; 10. LSP doc popup placement
;;; ============================================================

(ert-deftest rata-test-lsp-ui-doc-aligns-to-window-right ()
  "The lsp-ui-doc child frame hugs the current window's right edge.

Regression test for the popup landing in the corner of the *frame*: a
child frame is not a window, so no `display-buffer' rule constrains it,
and every one of lsp-ui's own placement knobs measures against the frame.
`window-edges' and `frame-pixel-width' are stubbed so this runs headless."
  (let ((orig (lambda (&rest _) (cons 1234 500))))
    ;; Point in the right half of a split: x=1000..1600 of a 2000px frame.
    (cl-letf (((symbol-function 'window-edges) (lambda (&rest _) '(1000 40 1600 900)))
              ((symbol-function 'frame-pixel-width) (lambda (&rest _) 2000)))
      ;; A 400px popup ends at the window's right edge, and the vertical
      ;; coordinate is whatever upstream decided.
      (should (equal (rata-lsp-ui-doc--align-right orig nil 400 100 1000 40)
                     (cons 1200 500)))
      ;; Wider than the window: clamped to the frame's left edge, never negative.
      (should (equal (rata-lsp-ui-doc--align-right orig nil 1800 100 1000 40)
                     (cons 0 500))))
    ;; Point in the left half: the popup must not cross into the other window.
    (cl-letf (((symbol-function 'window-edges) (lambda (&rest _) '(0 40 600 900)))
              ((symbol-function 'frame-pixel-width) (lambda (&rest _) 2000)))
      (should (equal (rata-lsp-ui-doc--align-right orig nil 400 100 0 40)
                     (cons 200 500))))))

;;; ============================================================
;;; Elfeed — the feeds.org tag contract
;;; ============================================================
;;
;; `feeds.org' is a data file and `init-elfeed.el' is code, and the tags are an
;; undeclared contract between them.  Every failure mode here is silent: a
;; renamed tag makes a view return zero entries, and a broken root tag makes
;; *every* feed vanish, both without an error.  The existing keybinding tests
;; cannot see any of it — `rata-test--walk-form' only inspects `rata-leader'
;; forms, and the elfeed filter keys go through `general-define-key'.

(defun rata-test--feeds-org-path ()
  "Return the path of the feeds file elfeed actually reads."
  (if (boundp 'rata-elfeed-feeds-file)
      rata-elfeed-feeds-file
    (expand-file-name "feeds.org" user-emacs-directory)))

(defconst rata-test--org-tag-group-re
  "^\\*+ .*?[ \t]+\\(:[[:alnum:]_@#%:]+:\\)[ \t]*$"
  "Match an org headline carrying a trailing tag group, group 1 = the tags.")

(defun rata-test--feeds-org-tags ()
  "Return every org tag used on a headline in feeds.org, as a list of strings."
  (let (tags)
    (with-temp-buffer
      (insert-file-contents (rata-test--feeds-org-path))
      (goto-char (point-min))
      (while (re-search-forward rata-test--org-tag-group-re nil t)
        (dolist (tag (split-string (match-string 1) ":" t))
          (cl-pushnew tag tags :test #'string=))))
    tags))

(defun rata-test--view-filter-tags (filter)
  "Return the +TAG terms of elfeed FILTER, minus the ubiquitous `unread'.
Date (@), feed (=) and title (~) terms are not tags and are skipped."
  (let (tags)
    (dolist (term (split-string filter "[ \t]+" t))
      (when (and (string-prefix-p "+" term)
                 (not (string= term "+unread")))
        (push (substring term 1) tags)))
    tags))

(ert-deftest rata-test-elfeed-root-tag-present ()
  "feeds.org must carry the tag `elfeed-org' looks for.
`rmh-elfeed-org-tree-id' is never set in this config, so the default
\"elfeed\" applies.  Remove or rename that tag on the top headline and
every feed disappears with no error and no empty-list warning — the
highest-consequence, lowest-visibility break in the whole module."
  (let ((root (if (boundp 'rmh-elfeed-org-tree-id) rmh-elfeed-org-tree-id "elfeed")))
    (should (member root (rata-test--feeds-org-tags)))))

(ert-deftest rata-test-elfeed-view-tags-exist-in-feeds-org ()
  "Every tag a `rata-elfeed-views' filter names must exist in feeds.org.
A view whose tag matches nothing is not an error in elfeed — it is an
empty entry list, indistinguishable from having read everything."
  (let ((known (rata-test--feeds-org-tags))
        failures)
    (pcase-dolist (`(,_key ,slug ,_label ,filter) rata-elfeed-views)
      (dolist (tag (rata-test--view-filter-tags filter))
        (unless (member tag known)
          (push (format "view `%s': +%s matches no feed in %s"
                        slug tag (file-name-nondirectory
                                  (rata-test--feeds-org-path)))
                failures))))
    (when failures
      (ert-fail (concat "Elfeed views filtering on nonexistent tags:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

(ert-deftest rata-test-elfeed-views-well-formed ()
  "`rata-elfeed-views' keys and slugs are unique and every view is a command.
The generated commands are bound with `general-define-key', which
`rata-test-keybindings-all-commandp' does not parse, so this is the only
thing standing between a typo'd slug and a dead `f' key."
  (let (keys slugs failures)
    (pcase-dolist (`(,key ,slug ,label ,filter) rata-elfeed-views)
      (should (stringp slug))
      (should (stringp label))
      (should (stringp filter))
      (when key
        (when (member key keys)
          (push (format "duplicate key %S (slug `%s')" key slug) failures))
        (push key keys))
      (when (member slug slugs)
        (push (format "duplicate slug `%s'" slug) failures))
      (push slug slugs)
      (let ((sym (rata-elfeed--view-symbol slug)))
        (unless (commandp sym t)
          (push (format "`%s' is not a command" sym) failures))))
    (should (commandp 'rata-elfeed-filter-view t))
    (when failures
      (ert-fail (concat "Malformed elfeed views:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

(ert-deftest rata-test-feeds-org-tag-conventions ()
  "feeds.org tags are lowercase and use only characters org accepts.
Org tags are `[[:alnum:]_@#%]' only, so a hyphen silently stops the whole
group being read as tags; and elfeed interns them, so `:Ntietz:' can
never be matched by typing `+ntietz'.  Also: every feed carries tags, or
it is unreachable from any view but `+unread'."
  (let (failures)
    (dolist (tag (rata-test--feeds-org-tags))
      (unless (string-match-p "\\`[[:alnum:]_@#%]+\\'" tag)
        (push (format "tag %S uses a character org does not accept in a tag" tag)
              failures))
      (unless (string= tag (downcase tag))
        (push (format "tag %S is not lowercase" tag) failures)))
    (with-temp-buffer
      (insert-file-contents (rata-test--feeds-org-path))
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ +\\(\\[\\[.*\\)$" nil t)
        (let ((line (match-string 0)))
          (unless (string-match-p ":[[:alnum:]_@#%:]+:[ \t]*\\'" line)
            (push (format "untagged feed: %s" (match-string 1)) failures)))))
    (when failures
      (ert-fail (concat "feeds.org tag convention violations:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

(ert-deftest rata-test-elfeed-retag-wired ()
  "Something must apply the feeds.org tags to entries already in the db.

Elfeed stamps a feed's tags onto an entry once, at fetch time.  So the
three tests above can pass — every view's tag really does exist in
feeds.org — while 22 of 36 views return zero entries, because the
backlog was fetched under the previous tag vocabulary.  That is what
happened after the tag-axis rework: the contract they check is between
two files, and nobody was checking it against the database.

`rata-elfeed-retag' closes that gap, so it has to stay reachable and its
two upstream entry points have to keep existing across package updates."
  (should (commandp 'rata-elfeed-retag))
  (should (memq 'rata-elfeed-retag elfeed-search-mode-hook))
  ;; `lookup-key' returns an integer for an incomplete prefix, so compare the
  ;; command rather than just testing for non-nil.
  (should (eq (rata-test--leader-lookup "SPC a r t") 'rata-elfeed-retag))
  ;; The retag is two upstream calls and nothing else; a rename in either
  ;; package would make it fail at the point of use, in a command the user
  ;; only presses when a filter already looks wrong.
  (skip-unless (require 'elfeed nil t))
  (should (fboundp 'elfeed-apply-autotags-now))
  (should (fboundp 'elfeed-db-save))
  (skip-unless (require 'elfeed-org nil t))
  (should (fboundp 'rmh-elfeed-org-process-advice)))

;;; ============================================================
;;; Test — dialogic formatting (lisp/init-dialogic.el)
;;; ============================================================

(ert-deftest rata-test-dialogic-block-regexp-anchors ()
  "The whole-block regexp must actually match a block.

Regression test for a silent failure, not a hypothetical one.  In an Emacs
regexp `^' is an anchor only at the start of the pattern or directly after
`\\(', `\\(?:' or `\\|'; written bare in the middle of a pattern it is a
literal caret.  The first version of `rata-dialogic--block-regexp' spelled
the closing delimiter `...^[ \t]*#\\+end_dialogue', which matched nothing,
so the audit cheerfully reported zero dialogue blocks in a buffer holding
two and the word count included every turn."
  (let ((re (rata-dialogic--block-regexp)))
    (let ((block "#+begin_dialogue\n- A :: one\n- Me :: two\n#+end_dialogue"))
      (should (string-match re block))
      ;; Group 1 is the body and nothing but the body.
      (should (equal (match-string 1 block) "- A :: one\n- Me :: two\n")))
    ;; Indented block, and an empty one.
    (should (string-match-p re "  #+begin_dialogue\n  - A :: one\n  #+end_dialogue"))
    (should (string-match-p re "#+begin_dialogue\n#+end_dialogue"))
    ;; The same trap in the any-block regexp used by the word count.
    (should (string-match-p rata-dialogic--any-block-regexp
                            "#+begin_src sql\nselect 1\n#+end_src"))))

(ert-deftest rata-test-dialogic-parse-turns ()
  "Turns parse into (SPEAKER . TEXT), with wrapped lines folded in."
  (should (equal (rata-dialogic-parse-turns
                  "- Skeptic :: Line one\n  wrapped on.\n- Me :: Reply.")
                 '(("Skeptic" . "Line one wrapped on.") ("Me" . "Reply."))))
  ;; An empty turn is still a turn — that is what the insert command writes.
  (should (equal (rata-dialogic-parse-turns "- Newcomer :: ")
                 '(("Newcomer" . ""))))
  (should (null (rata-dialogic-parse-turns "")))
  ;; A line with no `::' before any turn is ignored rather than fatal.
  (should (equal (rata-dialogic-parse-turns "stray text\n- Me :: ok")
                 '(("Me" . "ok")))))

(ert-deftest rata-test-dialogic-insert-and-bounds ()
  "Inserting a block produces a parseable block that `--block-bounds' finds."
  (with-temp-buffer
    (org-mode)
    (insert "* Head\n\nProse.")
    (rata-dialogic-insert-block "Skeptic")
    (insert "Does this hold?")
    (should (rata-dialogic--block-bounds))
    (rata-dialogic-insert-turn "Newcomer")
    (insert "And this?")
    (let ((body (progn
                  (string-match (rata-dialogic--block-regexp) (buffer-string))
                  (match-string 1 (buffer-string)))))
      (should (equal (mapcar #'car (rata-dialogic-parse-turns body))
                     (list "Skeptic" rata-dialogic-self-name "Newcomer"))))
    ;; The block must not be glued to the prose above it: ox-hugo would
    ;; otherwise fold it into that paragraph.
    (should (string-match-p "Prose\\.\n\n#\\+begin_dialogue" (buffer-string)))))

(ert-deftest rata-test-dialogic-audit-counts ()
  "The audit counts blocks and turns per heading and excludes block text."
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n\nintro.\n\n** Sub A\n\n"
            (mapconcat #'identity (make-list 20 "word") " ") "\n\n"
            "#+begin_dialogue\n- Skeptic :: One?\n- Me :: Yes.\n#+end_dialogue\n\n"
            "#+begin_dialogue\n- Ghost :: Two?\n#+end_dialogue\n\n"
            "#+begin_src sql\nselect count(*) from many words here\n#+end_src\n\n"
            "** Sub B\n\nshort.\n")
    (let* ((rows (rata-dialogic-audit-data))
           (sub-a (seq-find (lambda (r) (equal (plist-get r :heading) "Sub A")) rows)))
      (should (= 3 (length rows)))
      (should (= 2 (plist-get sub-a :blocks)))
      (should (= 3 (plist-get sub-a :turns)))
      ;; Exactly the 20 prose words: neither the turns nor the SQL count.
      (should (= 20 (plist-get sub-a :words)))
      (should (equal '("Skeptic" "Me" "Ghost") (plist-get sub-a :speakers)))
      ;; Both notes fire: over the per-heading cap, and a speaker off-cast.
      (let ((notes (rata-dialogic--audit-notes sub-a)))
        (should (= 2 (length notes)))
        (should (seq-find (lambda (n) (string-match-p "too chatty" n)) notes))
        (should (seq-find (lambda (n) (string-match-p "Ghost" n)) notes))))))

(ert-deftest rata-test-dialogic-exports-styled-html ()
  "A dialogue block must export as one <p> per turn inside a styled div.

Three things are asserted because three different mistakes are possible and
each is silent in the Org buffer:

  1. the wrapper div survives (ox-hugo supplies it for any special block);
  2. inline Org markup inside a turn is still transcoded, which is why the
     parse tree is rewritten rather than the exported string;
  3. the turns are separated by a blank line.  Without `:post-blank' on the
     generated paragraphs, Markdown reads the whole exchange as a single
     paragraph and every speaker lands in the same <p>.

The Blackfriday description-list syntax that ox-hugo would emit by default
\(\"Term\\n: description\") must NOT appear: this site renders with goldmark,
which has no definition-list extension, so those turns would show up as
literal \"Skeptic : ...\" text."
  (skip-unless (require 'ox-hugo nil t))
  (let ((out (org-export-string-as
              (concat "before\n\n"
                      "#+begin_dialogue\n"
                      "- Skeptic :: What about ~code~ here?\n"
                      "- Me :: Fine.\n"
                      "#+end_dialogue\n")
              'hugo t)))
    (should (string-match-p "<div class=\"dialogue\">" out))
    ;; Both the shared class and the per-speaker one, so CSS can style the
    ;; author's replies apart from an interruption.
    (should (string-match-p
             "<span class=\"dialogue-who dialogue-who--skeptic\">Skeptic</span>" out))
    (should (string-match-p
             "<span class=\"dialogue-who dialogue-who--me\">Me</span>" out))
    (should (string-match-p "`code`" out))
    (should-not (string-match-p "~code~" out))
    (should (string-match-p "Skeptic</span>[^\n]*\n\n<span" out))
    (should-not (string-match-p "^: " out))))

;;; ============================================================
;;; Test — blog export (lisp/init-blog.el)
;;; ============================================================

(defun rata-test--find-plist-with-name (form name)
  "Return the first plist inside FORM whose :name is NAME."
  (cond
   ((not (consp form)) nil)
   ((and (keywordp (car form)) (equal (plist-get form :name) name)) form)
   (t (or (rata-test--find-plist-with-name (car form) name)
          (rata-test--find-plist-with-name (cdr form) name)))))

(ert-deftest rata-test-blog-tag-matches-agenda-group ()
  "`rata-blog-tag' must equal the tag the \"Blog Posts\" agenda group selects on.

Regression test for the bug init-blog.el was written to fix.  The
org-super-agenda group `(:name \"Blog Posts\" :tag \"blog\")' has been in
init-org.el since the agenda was written, but no capture template ever
applied a :blog: filetag — so the group matched nothing and rendered as an
absent section.  That is the same shape of silent dead wiring as a leader
key bound in a deferred `:config' (FAIL-0009): the config is present, the
thing it refers to is not, and nothing complains.  Both ends are now
written down, so lock them together."
  (let ((group (rata-test--find-plist-with-name
                (rata-test--org-agenda-custom-commands) "Blog Posts")))
    (should group)
    (should (equal (plist-get group :tag) rata-blog-tag))))

(ert-deftest rata-test-blog-capture-template-tags-and-names ()
  "The \"blog-post\" capture template must tag the note and name the export.

Two separate silent failures: without `:blog:' in #+filetags: the post is
invisible to `rata-blog-files' and to the agenda group above; without a
value on :export_file_name: ox-hugo does not treat the subtree as a post
at all and `org-hugo-export-wim-to-md' falls through to the whole file."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/init-org.el" user-emacs-directory))
    (let ((source (buffer-string)))
      ;; The template body, verbatim from the source.
      (should (string-match-p "\"b\" \"blog-post\"" source))
      (should (string-match-p "#\\+filetags: :blog:" source))
      (should (string-match-p ":export_file_name: \\${slug}" source))
      (should-not (string-match-p ":export_file_name:$" source)))))

(ert-deftest rata-test-blog-parse-targets ()
  "`rata-blog--parse-targets' must resolve a post to its markdown file.

Pure path arithmetic, so it runs in batch without touching the operator's
notes.  The cases are the three shapes that actually occur in the roam
tree: a subtree naming both section and file (every existing post), a
subtree naming only the file, and a note that names neither."
  (let ((rata-hugo-dir "/tmp/rata-test-site/")
        (rata-blog-section "/posts/")
        (dir "/tmp/rata-test-roam/"))
    ;; 1. the shape blog-dbt.org uses: relative base dir + section + name.
    (should (equal
             (rata-blog--parse-targets
              (concat "#+title: DBT blog post\n"
                      "#+hugo_base_dir: ../hugo/\n"
                      "\n* Why i like dbt\n"
                      ":properties:\n"
                      ":export_hugo_section: /posts/\n"
                      ":export_file_name: why-i-like-dbt\n"
                      ":end:\n")
              dir "20230718-dbt")
             '(("why-i-like-dbt" "/tmp/hugo/content/posts/why-i-like-dbt.md" t))))
    ;; 2. no section on the subtree — falls back to `rata-blog-section'; no
    ;; base dir keyword — falls back to `rata-hugo-dir', which is the point of
    ;; setting `org-hugo-base-dir' globally.
    (should (equal
             (rata-blog--parse-targets
              ":properties:\n:export_file_name: solo\n:end:\n" dir "note")
             '(("solo" "/tmp/rata-test-site/content/posts/solo.md" t))))
    ;; 3. an empty :export_file_name: (what the old capture template wrote)
    ;; falls back to the note's slug rather than producing ".md", and is
    ;; flagged NOT-named: ox-hugo will not export it at all, so `rata-blog-status'
    ;; must say `unnamed' rather than `never' — the latter reads as "run the
    ;; export again", which cannot work.
    (should (equal
             (rata-blog--parse-targets
              ":properties:\n:export_file_name:\n:end:\n" dir "the-slug")
             '(("the-slug" "/tmp/rata-test-site/content/posts/the-slug.md" nil))))
    ;; 4. a note with no export property at all is still placed, so
    ;; `rata-blog-status' can report it as never exported rather than omit it.
    (should (equal (rata-blog--parse-targets "#+title: x\n" dir "plain")
                   '(("plain" "/tmp/rata-test-site/content/posts/plain.md" nil))))
    ;; 5. two posts in one note both resolve — `rata-blog-export-all' passes
    ;; ALL-SUBTREES to ox-hugo for exactly this case.
    (should (equal
             (mapcar #'car
                     (rata-blog--parse-targets
                      (concat ":properties:\n:export_file_name: one\n:end:\n"
                              ":properties:\n:export_file_name: two\n:end:\n")
                      dir "note"))
             '("one" "two")))))

(ert-deftest rata-test-blog-files-requires-org-roam ()
  "`rata-blog-files' must load org-roam, not gate on whether it is loaded.

Found by running `rata-blog-status' in a session where org-roam had not
been pulled in yet: the original `(when (fboundp \='org-roam-db-query) ...)'
guard — copied from `rata-org-roam-agenda-files', which only ever runs from
advice on `org-agenda' and so is always called with org-roam live —
returned nil, and the status buffer printed \"No notes tagged :blog:\" while
the database held ten of them.

That is L-029 again: an absence a reader cannot tell apart from an empty
result.  A user-facing entry point may not answer a question it did not
actually ask, so this asserts the shape of the source rather than the
behaviour, which is identical in the test environment where org-roam is
always loaded."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/init-blog.el" user-emacs-directory))
    (goto-char (point-min))
    (let ((start (progn (should (re-search-forward "^(defun rata-blog-files ()" nil t))
                        (match-beginning 0)))
          (end (progn (should (re-search-forward "^(defun rata-blog--md-path" nil t))
                      (match-beginning 0))))
      (let ((body (buffer-substring-no-properties start end)))
        (should (string-match-p "(require 'org-roam)" body))
        ;; Match the code pattern, not the bare word: the docstring names
        ;; `fboundp' to explain why it is wrong here.
        (should-not (string-match-p "(fboundp '?#?'?org-roam-db-query)" body))
        (should-not (string-match-p "(when (fboundp" body))))))

(ert-deftest rata-test-blog-unnamed-post-is-not-reported-as-pending ()
  "A post with an empty :EXPORT_FILE_NAME: must read `unnamed', not `never'.

Found on real data: `20260117021529-blog_post_my_emacs_workflow.org' carries
the empty property the old capture template wrote.  `rata-blog-status' first
listed it as `never' next to a plausible target path — but ox-hugo skips a
subtree whose export name is empty, so no amount of `SPC o b E' would ever
produce that file.  Reporting a state that implies a working remedy is the
L-029 shape once more, so the two cases are kept apart."
  (let* ((rata-hugo-dir "/tmp/rata-test-site/")
         (rata-blog-section "/posts/")
         (named (car (rata-blog--parse-targets
                      ":properties:\n:export_file_name: real-name\n:end:\n"
                      "/tmp/x/" "slug")))
         (unnamed (car (rata-blog--parse-targets
                        ":properties:\n:export_file_name:\n:end:\n"
                        "/tmp/x/" "slug"))))
    (should (nth 2 named))
    (should-not (nth 2 unnamed))
    ;; No markdown exists for either, so the only thing separating them is the
    ;; flag — which is the point.
    (should (eq (rata-blog--target-state "/nonexistent.org" unnamed) 'unnamed))
    (should (eq (rata-blog--target-state "/nonexistent.org" named) 'never))))

(ert-deftest rata-test-blog-state-classification ()
  "`rata-blog--state' must distinguish never-exported from stale."
  (let* ((tmp (make-temp-file "rata-blog-" t))
         (note (expand-file-name "note.org" tmp))
         (md (expand-file-name "note.md" tmp)))
    (unwind-protect
        (progn
          (write-region "x" nil note)
          (should (eq (rata-blog--state note md) 'never))
          (write-region "y" nil md)
          (should (eq (rata-blog--state note md) 'exported))
          ;; Touch the note into the future: an edited note with an old export.
          (set-file-times note (time-add (current-time) 60))
          (should (eq (rata-blog--state note md) 'stale)))
      (delete-directory tmp t))))

;;; ============================================================
;;; Test — agent-shell ACP adapter pins (lisp/init-llm.el)
;;; ============================================================

(defvar rata-test--acp-adapter-options
  '(agent-shell-anthropic-claude-acp-command
    agent-shell-pi-acp-command)
  "agent-shell options `init-llm.el' pins in its :custom block.
Each names a bare adapter executable.  The pin exists so that a rename
shows up in a diff, which only helps if something checks that the pin and
upstream still agree.  Add a row when the config pins another agent's
adapter.")

(ert-deftest rata-test-acp-adapter-commands-match-upstream ()
  "Pinned adapter commands must equal agent-shell's own standard values.

Regression test for .are/memory/failures/FAIL-0014.md.  Upstream renamed
the Claude adapter `claude-code-acp' -> `claude-agent-acp'; the pin in
`init-llm.el' kept the dead name and `SPC a i c c' failed with
\"Executable not found\" while the whole suite stayed green -- the adapter
is a binary on `exec-path', so batch mode had nothing to notice.

`use-package' :custom sets the value before the package declares the
`defcustom', but `custom-declare-variable' records `standard-value'
regardless, so that property is upstream's default rather than the pin.

A failure here means upstream moved: install the new adapter and update
the pin.  Do not just edit the expected value."
  (require 'agent-shell-anthropic)
  (require 'agent-shell-pi)
  (let (failures)
    (dolist (option rata-test--acp-adapter-options)
      (let ((standard (eval (car (get option 'standard-value)) t))
            (pinned (symbol-value option)))
        ;; A nil standard value would make every comparison below pass for the
        ;; wrong reason, so treat it as the failure it is.
        (unless (and standard (stringp (car standard)))
          (push (format "%s has no usable upstream standard-value (%S)"
                        option standard)
                failures))
        (unless (equal pinned standard)
          (push (format "%s is pinned to %S but agent-shell now defaults to %S"
                        option pinned standard)
                failures))))
    (when failures
      (ert-fail (concat "ACP adapter pins have drifted from upstream:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

;;; ============================================================
;;; Test — agent-shell fold chrome vs the GUI Enter key (lisp/init-llm.el)
;;; ============================================================

(defun rata-test--agent-shell-binding (keys state position)
  "Return what KEYS resolves to in an agent-shell buffer.

STATE is `normal' or `insert'.  POSITION is `chrome' to put point on
agent-shell's fold chrome, or `prompt' to put it on ordinary buffer text
of the kind the prompt line is made of.

Stands up the smallest buffer that reproduces real key lookup there:
`agent-shell-mode-map' as the local map (so the evil auxiliary keymaps
evil-collection hangs off it and off its `comint-mode-map' ancestor are
active), `agent-shell-ui-mode' on, and -- for `chrome' -- one run of text
propertized by `agent-shell-ui-make-foldable-text'.

`agent-shell-mode' itself is not called: it runs
`shell-maker-define-major-mode' machinery that wants a live shell, and the
local map is the only part of it that key lookup consults."
  (with-temp-buffer
    (use-local-map agent-shell-mode-map)
    (agent-shell-ui-mode 1)
    (evil-local-mode 1)
    (if (eq state 'insert) (evil-insert-state) (evil-normal-state))
    (evil-normalize-keymaps)
    (when (eq position 'chrome)
      (insert (agent-shell-ui-make-foldable-text :text "> Agent capabilities"
                                                 :hint "toggle"))
      (insert "\n"))
    (insert "plain text standing in for the prompt line\n")
    ;; Either way the text under test is the first thing in the buffer: the
    ;; chrome when it was inserted, the plain line when it was not.
    (goto-char (point-min))
    (key-binding (kbd keys))))

(ert-deftest rata-test-agent-shell-fold-chrome-answers-gui-return ()
  "The GUI Enter key must fold agent-shell's collapsible sections.

Regression test for the `> ...' headers (Agent capabilities, Notices,
Available models) being impossible to expand under evil.

The trap is key TRANSLATION, not keymap precedence.  agent-shell puts
`agent-shell-ui-fragment-map' on the fold chrome as a `keymap' text
property, and that map bound only `RET' (?\\r) and `mouse-1'.  A
text-property keymap outranks every emulation map, so `RET' on the chrome
always resolved correctly and evil looked innocent.  But a GUI frame
delivers `<return>', and Emacs falls back to translating `<return>' ->
`RET' only when *nothing* binds `<return>' -- while evil-collection's
`repl-submit' / `repl-newline' themes bind (\"RET\" \"<return>\" \"C-m\")
on `shell-maker-mode-map' and `comint-mode-map', both ancestors of
`agent-shell-mode-map'.  So `<return>' resolved to submit/newline and the
toggle was unreachable from the keyboard.  Terminal frames were fine: a
TTY sends `RET' directly.

`init-llm.el' fixes it by adding `<return>' to the fragment map.  This
test fails if that binding is dropped; its pair,
`rata-test-agent-shell-return-still-submits-off-chrome', fails if it is
widened into `agent-shell-mode-map' instead.  Neither is sufficient
alone -- the binding has to hold at one position and not the other."
  (require 'agent-shell)
  (require 'agent-shell-ui)
  (let (failures)
    ;; On the chrome, both spellings of Enter fold, in either state -- point,
    ;; not state, is what decides.
    (dolist (state '(normal insert))
      (dolist (keys '("RET" "<return>"))
        (let ((got (rata-test--agent-shell-binding keys state 'chrome)))
          (unless (eq got 'agent-shell-ui-toggle-fragment)
            (push (format "%s state, point on fold chrome: %s -> %s (want %s)"
                          state keys got 'agent-shell-ui-toggle-fragment)
                  failures)))))
    (when failures
      (ert-fail (concat "agent-shell fold chrome does not answer Enter:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

(ert-deftest rata-test-agent-shell-return-still-submits-off-chrome ()
  "Enter must keep submitting the prompt everywhere but the fold chrome.

The other half of `rata-test-agent-shell-fold-chrome-answers-gui-return'.
The fold binding is deliberately scoped to a text property so that it is
position-sensitive; a binding in `agent-shell-mode-map' would fold
everywhere and cost the operator prompt submission.  Both spellings of
Enter are checked, because the whole bug was one spelling behaving
differently from the other.

Normal state submits and insert state inserts a newline because
`evil-collection-repl-submit-state' defaults to normal.  A failure here
after changing that option is expected -- update the expectations.  A
failure here with that option untouched means the fold binding leaked out
of the chrome."
  (require 'agent-shell)
  (require 'agent-shell-ui)
  (let (failures)
    (dolist (expectation '((normal . shell-maker-submit)
                           (insert . newline)))
      (dolist (keys '("RET" "<return>"))
        (let* ((state (car expectation))
               (want (cdr expectation))
               (got (rata-test--agent-shell-binding keys state 'prompt)))
          (unless (eq got want)
            (push (format "%s state, point off fold chrome: %s -> %s (want %s)"
                          state keys got want)
                  failures)))))
    (when failures
      (ert-fail (concat "agent-shell prompt submission has regressed:\n"
                        (mapconcat #'identity (nreverse failures) "\n"))))))

;;; ============================================================
;;; Test — every snippet in snippets/ expands without error
;;; ============================================================

(ert-deftest rata-test-snippets-expand ()
  "Every snippet in `snippets/' must expand without signalling.

`are-audit' checks snippet headers and the `rata-' symbols a template
evaluates, but a grep cannot see unbalanced parens in an embedded elisp
form, a malformed field, or a `$(...)' transformation that errors — those
surface only when the template is actually run, halfway through expanding,
leaving a half-written block in the buffer.

Expansion happens in `fundamental-mode' with indentation disabled, not in
each snippet's own major mode.  Two reasons: the `*-ts-mode' directories
would pull treesit grammar installation into a batch run, and
`yas-indent-line' makes the result depend on a major mode's indent
function, which is a separate concern from whether the template is
well-formed (a snippet that needs literal indentation says so with
`# expand-env: ((yas-indent-line (quote fixed)))').

`yas-choose-value' consults `yas-prompt-functions', so it is stubbed to
take the first candidate rather than blocking on input."
  (skip-unless (fboundp 'yas-expand-snippet))
  (let* ((root (expand-file-name "snippets" user-emacs-directory))
         (yas-prompt-functions
          (list (lambda (_prompt choices &optional _display-fn) (car choices))))
         (checked 0)
         failures)
    (skip-unless (file-directory-p root))
    (dolist (mode-dir (directory-files root t "\\`[^.]"))
      (when (file-directory-p mode-dir)
        (dolist (file (directory-files mode-dir t "\\`[^.]"))
          (when (file-regular-p file)
            (setq checked (1+ checked))
            (let* ((parsed (with-temp-buffer
                             (insert-file-contents file)
                             ;; FILE is metadata only; the template is read
                             ;; from the current buffer.
                             (yas--parse-template file)))
                   (body (nth 1 parsed))
                   (env  (nth 5 parsed)))
              (if (null body)
                  (push (format "%s: no template body parsed"
                                (file-relative-name file root))
                        failures)
                (condition-case err
                    (with-temp-buffer
                      (fundamental-mode)
                      (yas-minor-mode 1)
                      (let ((yas-indent-line nil))
                        (yas-expand-snippet body nil nil env)))
                  (error (push (format "%s: %S"
                                       (file-relative-name file root) err)
                               failures)))))))))
    (should (> checked 0))
    (when failures
      (ert-fail (concat (format "%d of %d snippets failed to expand:\n  "
                                (length failures) checked)
                        (mapconcat #'identity (nreverse failures) "\n  "))))))

;;; ============================================================
;;; Run all tests
;;; ============================================================

(ert-run-tests-batch-and-exit)
