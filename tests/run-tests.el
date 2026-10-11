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
;; `--batch' skips the init files, so Emacs has already stamped `after-init-time'
;; by the time init.el loads here -- and elpaca takes a different, post-init path
;; when it is set (queues finalised early, the last throttled orders left queued
;; while `use-package' bodies run).  Clearing it puts this harness on the path a
;; real startup takes, the same as `just batch' (FAIL-0020).
(setq after-init-time nil)
(load (expand-file-name "early-init.el" user-emacs-directory) nil t)
(load (expand-file-name "init.el" user-emacs-directory) nil t)
(message "=== Ratatoskr ERT: config loaded, running tests ===")

;; Nothing in tests/ may reach a network service (AGENTS.md), and nothing may read
;; `~/.authinfo.gpg' (SAFETY_RULES): the first thing a real jira.el request does is
;; ask auth-source for the token, which decrypts that file -- a GPG passphrase
;; prompt on stdin in batch, a silent corporate API call when gpg-agent has the key
;; cached (FAIL-0021).  jira.el has two chokepoints for every request -- Tempo has
;; its own -- so both are overridden here to fail the calling test loudly.  A
;; test that legitimately needs a request stubs the function itself with
;; `cl-letf', which shadows this.
(with-eval-after-load 'jira-api
  (dolist (fn '(jira-api-call jira-api-tempo-call))
    (advice-add fn :override
                (lambda (verb endpoint &rest _)
                  (error "rata-test: `%s' (%s %s) would reach the network; stub it in the test"
                         fn verb endpoint))
                '((name . rata-test-no-network)))))

;; The same fence for stdin.  In batch every minibuffer read -- `y-or-n-p',
;; `yes-or-no-p', `read-string', `read-passwd', `completing-read' -- reads
;; standard input: EOF when it is /dev/null, a silent hang when it is a socket
;; or a TTY.  `(require 'aidermacs)' did exactly that: its vterm backend
;; requires vterm, and vterm asks "Compile vterm-module? (y or n)" at load, so
;; the suite sat at test 83 of 109 until killed (FAIL-0022).  Three readers
;; are fenced, not one: `read-string' and `yes-or-no-p' are C primitives that
;; reach the minibuffer reader inside C, where advice on `read-from-minibuffer'
;; is invisible -- `y-or-n-p' goes through `read-string' in batch, `yes-or-no-p'
;; through neither.  Probed: all five prompts above signal this error.  A test
;; that needs an answer stubs the reader with `cl-letf'.
(dolist (reader '(read-from-minibuffer read-string yes-or-no-p))
  (advice-add reader :override
              (lambda (prompt &rest _)
                (error "rata-test: something prompted on stdin (%S); stub it in the test"
                       prompt))
              '((name . rata-test-no-stdin))))

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
    ("SPC a i o" . rata-agent-center-toggle)
    ("SPC a i n" . rata-agent-center-next-attention)
    ("SPC a i c w" . rata-agent-worktree-new)
    ("SPC a i c W" . rata-agent-worktree-finish)
    ("SPC a i c P" . rata-agent-prompt)
    ("SPC J l" . rata-jira-org-link-heading)
    ("SPC o b d d" . rata-dialogic-insert-block)
    ("SPC o b e" . org-hugo-export-wim-to-md)
    ("SPC o b s" . rata-blog-status)
    ("SPC o s" . rata-org-sort-tasks)
    ("SPC i o p" . org-id-get-create)
    ("SPC i o a" . rata-roam-alias-add-to-file)
    ;; agent-shell's context senders are not autoloaded upstream, so these
    ;; resolve only while their symbols stay in init-llm.el's :commands list.
    ("SPC a i c f" . rata-agent-shell-send-file)
    ("SPC a i c r" . agent-shell-send-region)
    ("SPC a i c d" . agent-shell-send-dwim)
    ;; init-mail.el binds its own wrappers, never mu4e symbols directly, so
    ;; these resolve on a host with no mu installed too (the wrapper then
    ;; explains what is missing instead of the key being dead).
    ("SPC a e e" . rata-mail)
    ("SPC a e u" . rata-mail-update)
    ("SPC a e d" . rata-mail-doctor)
    ("SPC a r h" . rata-elfeed-hn-open-item))
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

(ert-deftest rata-test-claude-loop-scan-phase-headings ()
  "A plan's Phase/Task headings are tasks; closed, fenced and look-alikes are not."
  (with-temp-buffer
    (insert "# Plan\n"                                 ; 1
            "## 0. Target\n"                           ; 2 not a task
            "## Tasks\n"                               ; 3 `Tasks' is not `Task'
            "## Phase 0 — Scaffold [done]\n"           ; 4 closed
            "## Phase 1 — Client\n"                    ; 5 open
            "```sh\n# Task: not a heading\n```\n"      ; 6-8 fenced
            "### Task 1.1 — probe  \n"                 ; 9 inside Phase 1: detail
            "## phase lowercase\n"                     ; 10 case-sensitive
            "## Phase 7 — Deferred [skipped]\n"        ; 11 closed
            "### Task 7.1 — orphan\n"                  ; 12 inside closed Phase 7
            "## Phases\n"                              ; 13 not a task
            "### Phase 8 — Nested  \n")                ; 14 open, any level
    (should (equal (rata-claude-loop--open-tasks)
                   '((5 . "Phase 1 — Client") (14 . "Phase 8 — Nested"))))
    (should (equal (rata-claude-loop--scan-buffer) '(5 . "Phase 1 — Client")))
    (should (= (rata-claude-loop--count-in-buffer) 2))))

(ert-deftest rata-test-claude-loop-nested-heading-runs-once ()
  "A Task heading under a Phase is the Phase's detail, never a second task.
Otherwise its work is sent once inside the Phase's prompt and again on its
own -- and a findings subsection such as `#### Phase 0 findings' becomes
work to do."
  (with-temp-buffer
    (insert "## Phase 1 — Client\n"
            "### Task 1.1 — probe\n"
            "#### Phase 1 findings\n"
            "## Phase 2 — Logs\n")
    (should (equal (rata-claude-loop--open-tasks)
                   '((1 . "Phase 1 — Client") (4 . "Phase 2 — Logs"))))
    (should (string-match-p "Task 1.1" (rata-claude-loop--body-at 1)))
    ;; Closing the outer heading does not promote the inner one.
    (should (rata-claude-loop--mark-in-buffer 1 'done))
    (should (equal (rata-claude-loop--open-tasks) '((4 . "Phase 2 — Logs"))))))

(ert-deftest rata-test-claude-loop-checkboxes-win-over-headings ()
  "Any checklist item, even a ticked one, turns heading tasks off.
Otherwise a phase would be sent with its sub-boxes as detail, and each of
those boxes would then run again as a task of its own."
  (with-temp-buffer
    (insert "## Phase 1 — Client\n- [X] done already\n")
    (should-not (rata-claude-loop--open-tasks))
    (erase-buffer)
    (insert "## Phase 1 — Client\n- [ ] sub-task\n")
    (should (equal (rata-claude-loop--open-tasks) '((2 . "sub-task")))))
  (let ((rata-claude-loop-heading-regexp nil))
    (with-temp-buffer
      (insert "## Phase 1 — Client\n")
      (should-not (rata-claude-loop--open-tasks)))))

(ert-deftest rata-test-claude-loop-mark-heading ()
  "A heading task is closed by appending a marker, which closes it for the scan."
  (with-temp-buffer
    (insert "## Phase 0 — A  \n## Phase 1 — B\n")
    (should (rata-claude-loop--mark-in-buffer 1 'done))
    (should (rata-claude-loop--mark-in-buffer 2 'skipped))
    (should (equal (buffer-string)
                   "## Phase 0 — A [done]\n## Phase 1 — B [skipped]\n"))
    (should-not (rata-claude-loop--open-tasks))
    ;; Already closed: no change, so the progress guard is never fooled.
    (should-not (rata-claude-loop--mark-in-buffer 1 'done))
    (should (equal (rata-claude-loop--find-task-line 1 "Phase 0 — A") nil))))

(ert-deftest rata-test-claude-loop-body-heading ()
  "A heading task's detail is its section, subsections and fences included."
  (with-temp-buffer
    (insert "## Phase 1 — Client\n"
            "intro line\n"
            "### Verification\n"
            "run the tests\n"
            "```sh\n# not a heading\n```\n"
            "## Phase 2 — Logs\n"
            "not part of phase 1\n")
    (should (equal (rata-claude-loop--body-at 1)
                   (concat "intro line\n### Verification\nrun the tests\n"
                           "```sh\n# not a heading\n```")))
    (should (equal (rata-claude-loop--body-at 8) "not part of phase 1"))))

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

(ert-deftest rata-test-claude-loop-cli-attempt-record ()
  "The CLI's result event and exit code become the backend-neutral record."
  (should (equal (rata-claude-loop--cli-attempt
                  '((subtype . "error_max_turns") (is_error . t)
                    (permission_denials . (((tool_name . "Edit")))))
                  1)
                 '(:result-p t :subtype "error_max_turns" :is-error t
                   :exit-code 1 :denials (((tool_name . "Edit"))))))
  (should (equal (rata-claude-loop--cli-attempt nil 0)
                 '(:result-p nil :subtype nil :is-error nil
                   :exit-code 0 :denials nil))))

(ert-deftest rata-test-claude-loop-classify-attempt-is-backend-neutral ()
  "Classification reads the record, never a backend's wire format.
A backend with no process reports no exit code; that must not crash the
classifier, and a denial in the record must count exactly as one in a
CLI result event does."
  (let ((rata-claude-loop--state nil))
    (should-not (rata-claude-loop--classify-attempt
                 '(:result-p t :subtype "success" :exit-code nil)))
    (should (eq 'no-result
                (car (rata-claude-loop--classify-attempt
                      '(:result-p nil :exit-code nil)))))
    (let ((verdict (rata-claude-loop--classify-attempt
                    '(:result-p t :subtype "success" :exit-code nil
                      :denials (((tool_name . "Bash")
                                 (tool_input . ((command . "just test")))))
                      :report done))))
      (should (eq 'unverified (car verdict)))
      (should (string-match-p "Bash(just:\\*)" (cdr verdict))))
    (should (eq 'blocked
                (car (rata-claude-loop--classify-attempt
                      '(:result-p t :subtype "success"
                        :report blocked :report-reason "no creds")))))))

(ert-deftest rata-test-claude-loop-backend-dispatch ()
  "Calls go to the run's backend, which outranks the configured one."
  (let* ((calls nil)
         (rata-claude-loop--backends
          `((one :live-p ,(lambda () (push 'one calls) 'one-live))
            (two :live-p ,(lambda () (push 'two calls) 'two-live))))
         (rata-claude-loop-backend 'one)
         (rata-claude-loop--state nil))
    (should (eq (rata-claude-loop--backend-call :live-p) 'one-live))
    (setq rata-claude-loop--state (list :backend 'two))
    (should (eq (rata-claude-loop--backend-call :live-p) 'two-live))
    (should (equal calls '(two one)))
    ;; An op a backend lacks is a bug, said as one.
    (should-error (rata-claude-loop--backend-call :start "t" "f" nil))
    (setq rata-claude-loop--state (list :backend 'gone))
    (should-error (rata-claude-loop--backend-call :live-p) :type 'user-error))
  ;; The shipped backend implements every op the contract names.
  (let ((cli (cdr (assq 'cli rata-claude-loop--backends))))
    (dolist (op '(:check :start :retry :attempt :live-p :stop :kill))
      (should (functionp (plist-get cli op))))))

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
              ;; `jira-tempo-mode' reverts its table as part of turning on, and
              ;; the revert is a live worklog request; the keymap is all this test
              ;; needs, so the refresh is stubbed rather than the harness guard
              ;; tripped (FAIL-0021).
              (cl-letf (((symbol-function 'jira-tempo--refresh) #'ignore))
                (funcall mode))
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

(ert-deftest rata-test-elfeed-toggle-unread-filter-preserves-view-terms ()
  "The all-posts toggle must change only Elfeed's unread term."
  (should (equal (rata-elfeed--toggle-unread-filter
                  "@6-months-ago +unread +emacs -news")
                 "@6-months-ago +emacs -news"))
  (should (equal (rata-elfeed--toggle-unread-filter
                  "@6-months-ago +emacs -news")
                 "@6-months-ago +emacs -news +unread")))

(ert-deftest rata-test-elfeed-toggle-unread-filter-command ()
  "The interactive toggle updates Elfeed's filter and reports its state."
  (let ((elfeed-search-filter "@6-months-ago +unread +emacs")
        filter message)
    (cl-letf (((symbol-function 'elfeed-search-set-filter)
               (lambda (value) (setq filter value)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message (apply #'format format-string args)))))
      (rata-elfeed-toggle-unread-filter))
    (should (equal filter "@6-months-ago +emacs"))
    (should (equal message "Elfeed: showing all posts"))))

(ert-deftest rata-test-elfeed-toggle-unread-filter-key-is-live ()
  "`f R' must reach the unread/all-posts toggle in Elfeed search buffers."
  (skip-unless (require 'elfeed nil t))
  (rata-elfeed-bind-view-keys)
  (should (eq (lookup-key (evil-get-auxiliary-keymap elfeed-search-mode-map 'normal)
                          (kbd "f R"))
              'rata-elfeed-toggle-unread-filter)))

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
;;; Test — Hacker News in elfeed (lisp/init-elfeed-hn.el)
;;; ============================================================
;;
;; Nothing here reaches hn.algolia.com or an article's site: the fence below
;; makes `rata-elfeed-hn--retrieve' -- the module's only network function --
;; fail the calling test, and every test that needs a reply swaps in
;; `rata-test-hn--with-net', which answers from tests/fixtures/hn/.

(require 'init-elfeed-hn)

(advice-add 'rata-elfeed-hn--retrieve :override
            (lambda (url &rest _)
              (error "rata-test: `rata-elfeed-hn--retrieve' (%s) would reach the network; stub it in the test"
                     url))
            '((name . rata-test-no-network)))

(defun rata-test-hn--fixture (name)
  "Return the contents of tests/fixtures/hn/NAME as a string."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "tests/fixtures/hn/" name) user-emacs-directory))
    (buffer-string)))

(defun rata-test-hn--json (name)
  "Parse fixture NAME the way `rata-elfeed-hn--fetch-json' does."
  (json-parse-string (rata-test-hn--fixture name)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defvar rata-test-hn--pending nil
  "Requests the fake network has received and not yet answered: (URL CALLBACK).")

(defvar rata-test-hn--requests nil
  "Every URL the fake network was asked for, oldest first.")

(defvar rata-test-hn--caps nil
  "The size cap each request was made with: an alist of URL to MAX-BYTES.")

(defvar rata-test-hn--routes nil
  "The fake network's answers: an alist of URL to result plist.")

(defmacro rata-test-hn--with-net (routes &rest body)
  "Run BODY with the network replaced by ROUTES, an alist of URL to result.
A request is held until `rata-test-hn--flush', so a test controls when a
reply arrives.  An unrouted URL answers (:error \"no fixture\")."
  (declare (indent 1))
  `(let ((rata-test-hn--pending nil)
         (rata-test-hn--requests nil)
         (rata-test-hn--caps nil)
         (rata-test-hn--routes ,routes))
     (cl-letf (((symbol-function 'rata-elfeed-hn--retrieve)
                (lambda (url max callback)
                  (setq rata-test-hn--requests (append rata-test-hn--requests (list url)))
                  (push (cons url max) rata-test-hn--caps)
                  (push (list url callback) rata-test-hn--pending))))
       (clrhash rata-elfeed-hn--cache)
       (clrhash rata-elfeed-hn--article-cache)
       ,@body)))

(defun rata-test-hn--drain ()
  "Run the timers a reply is delivered from."
  (dotimes (_ 5) (accept-process-output nil 0.01)))

(defun rata-test-hn--flush ()
  "Answer every pending request from `rata-test-hn--routes', then drain timers."
  (while rata-test-hn--pending
    (let ((requests (reverse rata-test-hn--pending)))
      (setq rata-test-hn--pending nil)
      (pcase-dolist (`(,url ,callback) requests)
        (funcall callback (or (cdr (assoc url rata-test-hn--routes))
                              (list :error "no fixture"))))
      (rata-test-hn--drain))))

(defun rata-test-hn--ok (body &optional type)
  "A successful fake response carrying BODY, of content TYPE."
  (list :ok t :type (or type "application/json") :body body))

(defun rata-test-hn--api (id)
  "The Algolia URL for item ID."
  (concat rata-elfeed-hn-api-url (number-to-string id)))

(ert-deftest rata-test-hn-item-id-from-each-feed-shape ()
  "The item id comes out of what elfeed already stored, for both HN feeds.
And only from the shapes those feeds write: a blog post that links to an
HN discussion is not an HN entry, or its article would be replaced."
  ;; news.ycombinator.com/rss: the content is the one link.
  (should (equal (rata-elfeed-hn-item-id
                  "<a href=\"https://news.ycombinator.com/item?id=49283063\">Comments</a>"
                  "https://example.com/article")
                 49283063))
  ;; hnrss.org, as stored in elfeed-db on 2026-10-06.
  (should (equal (rata-elfeed-hn-item-id
                  (concat "<p>Article URL: <a href=\"https://www.nature.com/a\">https://www.nature.com/a</a></p>\n"
                          "<p>Comments URL: <a href=\"https://news.ycombinator.com/item?id=49312008\">"
                          "https://news.ycombinator.com/item?id=49312008</a></p>\n<p>Points: 192</p>")
                  "https://www.nature.com/a")
                 49312008))
  ;; Ask HN: the link is the item itself.
  (should (equal (rata-elfeed-hn-item-id "<p>What do you use?</p>"
                                         "https://news.ycombinator.com/item?id=123")
                 123))
  ;; Not HN.
  (should-not (rata-elfeed-hn-item-id
               "Discussed <a href=\"https://news.ycombinator.com/item?id=5\">on HN</a>."
               "https://blog.example.com/post"))
  (should-not (rata-elfeed-hn-item-id nil nil))
  (should-not (rata-elfeed-hn-item-id "" "https://news.ycombinator.com/item?id=5&p=2")))

(ert-deftest rata-test-hn-parse-thread-edge-cases ()
  "Order, depth, deleted comments and counts from a hand-built reply."
  (let* ((thread (rata-elfeed-hn--thread-from-json (rata-test-hn--json "thread-edge.json")))
         (top (plist-get thread :comments)))
    (should (equal (plist-get thread :title) "Show HN: A test thread"))
    (should (equal (plist-get thread :points) 42))
    (should (equal (plist-get thread :url) "https://example.com/post"))
    ;; The poll option is not a comment; order is the reply's order.
    (should (equal (mapcar (lambda (c) (plist-get c :id)) top) '(1001 1004 1006)))
    ;; A deleted comment with no replies is gone ...
    (should (equal (mapcar (lambda (c) (plist-get c :id))
                           (plist-get (nth 0 top) :children))
                   '(1002)))
    ;; ... one with a live reply stays, so the reply keeps its parent.
    (should (plist-get (nth 1 top) :deleted))
    (should (equal (plist-get (car (plist-get (nth 1 top) :children)) :author) "carol"))
    (should (equal (plist-get (car (plist-get (nth 1 top) :children)) :depth) 1))
    (should (equal (plist-get (nth 0 top) :depth) 0))
    (should (equal (plist-get (nth 0 top) :replies) 1))
    (should (equal (plist-get (nth 1 top) :replies) 1))
    ;; alice, bob, carol, dave -- the placeholder is not a comment.
    (should (equal (plist-get thread :count) 4))))

(ert-deftest rata-test-hn-parse-real-thread ()
  "A reply captured from the live API parses whole, in order.
tests/fixtures/hn/item-8863.json is the Dropbox launch thread, captured
2026-10-06: 71 comments, none deleted."
  (let* ((json (rata-test-hn--json "item-8863.json"))
         (thread (rata-elfeed-hn--thread-from-json json)))
    (should (equal (plist-get thread :count) 71))
    (should (equal (plist-get thread :author) "dhouston"))
    (should (equal (mapcar (lambda (c) (plist-get c :id)) (plist-get thread :comments))
                   (mapcar (lambda (c) (alist-get 'id c)) (alist-get 'children json))))))

(ert-deftest rata-test-hn-fetch-json-results-not-signals ()
  "A good reply parses; a bad body and a failed request are results."
  (rata-test-hn--with-net
      (list (cons (rata-test-hn--api 1000) (rata-test-hn--ok (rata-test-hn--fixture "thread-edge.json")))
            (cons (rata-test-hn--api 1) (rata-test-hn--ok "<html>not json"))
            (cons (rata-test-hn--api 2) (list :error "HTTP 503")))
    (let (got)
      (dolist (id '(1000 1 2))
        (rata-elfeed-hn--fetch-json id (lambda (r) (push (cons id r) got))))
      (rata-test-hn--flush)
      (should (equal (alist-get 'title (plist-get (alist-get 1000 got) :ok))
                     "Show HN: A test thread"))
      (should (string-prefix-p "bad reply" (plist-get (alist-get 1 got) :error)))
      (should (equal (alist-get 2 got) '(:error "HTTP 503"))))))

(ert-deftest rata-test-hn-fetch-thread-caches-and-reports-failure ()
  "A thread is fetched once per session unless forced; a failure is a result."
  (rata-test-hn--with-net
      (list (cons (rata-test-hn--api 2000) (rata-test-hn--ok (rata-test-hn--fixture "ask-2000.json"))))
    (let (got)
      (rata-elfeed-hn--fetch-thread 2000 nil (lambda (r) (push r got)))
      (rata-test-hn--flush)
      (rata-elfeed-hn--fetch-thread 2000 nil (lambda (r) (push r got)))
      (rata-test-hn--drain)
      (should (= (length got) 2))
      (should (equal (plist-get (plist-get (car got) :ok) :count) 1))
      (should (equal (length rata-test-hn--requests) 1))
      (rata-elfeed-hn--fetch-thread 2000 t #'ignore)
      (should (equal (length rata-test-hn--requests) 2))
      ;; Unrouted: the request fails, and the failure arrives as a value.
      (setq got nil)
      (rata-elfeed-hn--fetch-thread 99 nil (lambda (r) (push r got)))
      (rata-test-hn--flush)
      (should (equal got '((:error "no fixture")))))))

(ert-deftest rata-test-hn-guard-drops-stale-replies ()
  "A reply for a buffer that has moved on, or died, does nothing."
  (let ((buf (generate-new-buffer " *hn-guard*"))
        (ran nil))
    (unwind-protect
        (with-current-buffer buf
          (setq rata-elfeed-hn--key 'entry-a)
          (let ((current (rata-elfeed-hn--guard buf (lambda (x) (push x ran))))
                (bumped (rata-elfeed-hn--guard buf (lambda (x) (push x ran)))))
            (funcall current 1)
            (should (equal ran '(1)))
            ;; `g', or `n' to another HN entry: the redraw bumps the generation.
            (cl-incf rata-elfeed-hn--generation)
            (funcall bumped 2)
            (should (equal ran '(1)))
            ;; Same generation, different entry.
            (let ((g (rata-elfeed-hn--guard buf (lambda (x) (push x ran)))))
              (setq rata-elfeed-hn--key 'entry-b)
              (funcall g 3)
              (should (equal ran '(1))))
            ;; An error inside is a message, never a signal out of a callback.
            (let ((g (rata-elfeed-hn--guard buf (lambda (_) (error "boom")))))
              (should-not (condition-case nil (progn (funcall g 4) nil) (error t))))
            (let ((g (rata-elfeed-hn--guard buf (lambda (x) (push x ran)))))
              (kill-buffer buf)
              (funcall g 5)
              (should (equal ran '(1))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest rata-test-hn-read-response ()
  "url.el's response buffer becomes a result: status, cap, charset."
  (cl-flet ((response (code ctype body &optional max)
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert "HTTP/1.1 " (number-to-string code) " X\nContent-Type: " ctype "\n\n")
                (setq-local url-http-end-of-headers (1- (point)))
                (insert (encode-coding-string body 'utf-8))
                (setq-local url-http-response-status code)
                (setq-local url-http-content-type ctype)
                (rata-elfeed-hn--read-response nil max))))
    (should (equal (response 200 "text/html; charset=UTF-8" "<p>héllo</p>")
                   '(:ok t :type "text/html" :body "<p>héllo</p>")))
    (should (equal (response 404 "text/html" "gone") '(:error "HTTP 404")))
    (should (equal (plist-get (response 200 "text/html" (make-string 3000 ?x) 2048) :error)
                   "over 2 KB"))
    (should (equal (rata-elfeed-hn--read-response '(:error (error http 500)) nil)
                   '(:error "HTTP 500")))))

(defconst rata-test-hn--feed-url "https://news.ycombinator.com/rss")

(defmacro rata-test-hn--with-elfeed (&rest body)
  "Run BODY with elfeed loaded over an in-memory database.
`elfeed-db' is bound non-nil, so `elfeed-db-ensure' never loads the real
database and nothing is written back; entries are shown with the
mail-style renderer into the current window's buffer list, not a popup."
  (declare (indent 0))
  `(progn
     (skip-unless (require 'elfeed nil t))
     (require 'elfeed-show)
     (require 'shr)
     (let ((elfeed-db (list :version 4))
           (elfeed-db-feeds (make-hash-table :test 'equal))
           (elfeed-show-entry-switch #'set-buffer)
           (elfeed-show-unique-buffers nil)
           (elfeed-show-refresh-function #'elfeed-show-refresh--mail-style)
           ;; Batch has no font metrics, so pixel filling breaks every word
           ;; onto its own line; character filling is what the asserts read.
           (shr-use-fonts nil))
       (puthash rata-test-hn--feed-url
                (elfeed-feed--create :id rata-test-hn--feed-url :url rata-test-hn--feed-url
                                     :title "Hacker News")
                elfeed-db-feeds)
       (unwind-protect (progn ,@body)
         (when (get-buffer "*elfeed-entry*")
           (kill-buffer "*elfeed-entry*"))))))

(defun rata-test-hn--entry (id title link content)
  "An elfeed entry from the news.ycombinator.com feed, not stored anywhere."
  (elfeed-entry--create :id (cons "news.ycombinator.com" (format "%s" id))
                        :title title :link link :date 1700000000
                        :content content :content-type 'html
                        :feed-id rata-test-hn--feed-url :tags '(hn)))

(defun rata-test-hn--rss-entry (id title)
  "An entry shaped like news.ycombinator.com/rss: the content is one link."
  (rata-test-hn--entry
   id title "https://example.com/post"
   (format "<a href=\"https://news.ycombinator.com/item?id=%d\">Comments</a>" id)))

(defun rata-test-hn--blog-entry ()
  "An entry from some other feed."
  (rata-test-hn--entry "blog" "A blog post" "https://blog.example.com/post"
                       "<p>Hello <b>world</b>, discussed <a href=\"https://news.ycombinator.com/item?id=5\">on HN</a>.</p>"))

(defun rata-test-hn--show (entry)
  "Show ENTRY through the real `elfeed-show-entry'; return its buffer."
  (elfeed-show-entry entry)
  (get-buffer "*elfeed-entry*"))

(defun rata-test-hn--blocks ()
  "Return (ID DEPTH GUTTER-WIDTH) per comment block in the buffer, in order."
  (let (out (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'rata-elfeed-hn-id nil))
      (push (list (get-text-property pos 'rata-elfeed-hn-id)
                  (get-text-property pos 'rata-elfeed-hn-depth)
                  (length (get-text-property pos 'line-prefix)))
            out)
      (setq pos (or (next-single-property-change pos 'rata-elfeed-hn-id) (point-max))))
    (nreverse out)))

(defun rata-test-hn--block-text (id)
  "Return comment ID's block as a string, with its properties."
  (let* ((start (text-property-any (point-min) (point-max) 'rata-elfeed-hn-id id))
         (end (next-single-property-change start 'rata-elfeed-hn-id nil (point-max))))
    (buffer-substring start end)))

(ert-deftest rata-test-hn-hook-keeps-elfeeds-own ()
  "Our function joins `elfeed-show-update-hook' without displacing elfeed's.
`add-hook' before elfeed-show loads would bind the variable first, and
elfeed's `defvar' -- which holds its readable and fetch-link functions --
would then never take effect."
  (should (featurep 'init-elfeed-hn))
  (skip-unless (require 'elfeed-show nil t))
  (should (memq 'rata-elfeed-hn-show-update elfeed-show-update-hook))
  (should (memq 'elfeed-show-auto-readable elfeed-show-update-hook))
  (should (memq 'elfeed-show-auto-fetch-link elfeed-show-update-hook)))

(ert-deftest rata-test-hn-entry-shows-thread ()
  "An HN entry draws, after elfeed's own text, one block per comment."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (list (cons (rata-test-hn--api 1000)
                    (rata-test-hn--ok (rata-test-hn--fixture "thread-edge.json"))))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
        (should (string-match-p "Comments: loading…" (buffer-string)))
        (rata-test-hn--flush)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should-not (string-match-p "loading…" text))
          (should (string-match-p "^4 comments · 42 points$" text))
          (should (< (string-match "^Title: Show HN" text)
                     (string-match "^4 comments" text))))
        ;; Live comments in order, two gutter columns per level; the deleted
        ;; parent of carol's reply stays as a placeholder.
        (should (equal (rata-test-hn--blocks)
                       '((1001 0 0) (1002 1 2) (1004 0 0) (1005 1 2) (1006 0 0))))
        (should (string-prefix-p "[deleted]" (rata-test-hn--block-text 1004)))
        (should (string-match-p "\\`alice · .* ago · 1 reply\n"
                                (substring-no-properties (rata-test-hn--block-text 1001))))
        (should (string-match-p "First comment, with emphasis and a link"
                                (substring-no-properties (rata-test-hn--block-text 1001))))))))

(ert-deftest rata-test-hn-comment-html-is-inert ()
  "Comment text is drawn as text: no Org link, no script, no Lisp."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (list (cons (rata-test-hn--api 1000)
                    (rata-test-hn--ok (rata-test-hn--fixture "thread-edge.json"))))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
        (rata-test-hn--flush)
        (let* ((block (rata-test-hn--block-text 1006))
               (at (string-match (regexp-quote "[[elisp:(delete-file \"x\")]]") block)))
          (should at)
          (should-not (string-match-p "alert" block))
          (should (string-match-p "(x)" block))
          (dolist (prop '(shr-url keymap button action follow-link))
            (should-not (get-text-property at prop block))))))))

(ert-deftest rata-test-hn-non-hn-entry-untouched ()
  "Any other entry draws exactly as it does without this module."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net nil
      (let* ((entry (rata-test-hn--blog-entry))
             (with (with-current-buffer (rata-test-hn--show entry) (buffer-string)))
             (without (let ((elfeed-show-update-hook
                             (remq 'rata-elfeed-hn-show-update elfeed-show-update-hook)))
                        (with-current-buffer (rata-test-hn--show entry) (buffer-string)))))
        (should (equal-including-properties with without))
        (should-not rata-test-hn--requests)))))

(ert-deftest rata-test-hn-reply-for-a-left-entry-is-dropped ()
  "Moving on before the reply arrives leaves the new entry clean."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (list (cons (rata-test-hn--api 1000)
                    (rata-test-hn--ok (rata-test-hn--fixture "thread-edge.json")))
              (cons (rata-test-hn--api 2000)
                    (rata-test-hn--ok (rata-test-hn--fixture "ask-2000.json"))))
      ;; HN entry, then a blog entry, then the reply.
      (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--blog-entry))
        (rata-test-hn--flush)
        (should-not (text-property-not-all (point-min) (point-max) 'rata-elfeed-hn-section nil))
        (should-not (string-match-p "Comments:\\|comments ·" (buffer-string))))
      ;; HN entry, then another HN entry: only the second thread is drawn.
      (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 2000 "Ask HN"))
        (rata-test-hn--flush)
        (should (equal (rata-test-hn--blocks) '((2001 0 0))))
        (should (= 1 (how-many "^1 comment · 7 points$" (point-min) (point-max))))))))

(ert-deftest rata-test-hn-failed-fetch-says-so ()
  "A failed fetch is a line in the buffer naming the reason and the retry key."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (list (cons (rata-test-hn--api 1000) (list :error "HTTP 503")))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
        (rata-test-hn--flush)
        (should (string-match-p "^Comments: fetch failed (HTTP 503) — , c to retry$"
                                (buffer-substring-no-properties (point-min) (point-max))))))))

(defun rata-test-hn--text ()
  "The current buffer's text, without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun rata-test-hn--section-text (name)
  "The text of section NAME in the current buffer, or nil."
  (when-let* ((b (rata-elfeed-hn--section-bounds name)))
    (buffer-substring-no-properties (car b) (cdr b))))

(defconst rata-test-hn--article-url "https://example.com/post")

(defun rata-test-hn--story-routes (article)
  "Routes for the edge thread, with ARTICLE as the reply for its article."
  (list (cons (rata-test-hn--api 1000)
              (rata-test-hn--ok (rata-test-hn--fixture "thread-edge.json")))
        (cons rata-test-hn--article-url article)))

(ert-deftest rata-test-hn-readable-text ()
  "eww's reader view keeps an article and rejects a cookie wall."
  (let ((dom (rata-elfeed-hn--readable-text (rata-test-hn--fixture "article.html"))))
    (should dom)
    (should (string-match-p "three properties we now think" (dom-texts dom))))
  (should-not (rata-elfeed-hn--readable-text (rata-test-hn--fixture "cookie-wall.html")))
  (should-not (rata-elfeed-hn--readable-text "")))

(ert-deftest rata-test-hn-story-and-article-replace-comments-word ()
  "A Comments-only entry shows the story and the readable article instead."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (rata-test-hn--story-routes
         (rata-test-hn--ok (rata-test-hn--fixture "article.html") "text/html"))
      (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
        ;; Both requests are out at once: the article does not wait for the thread.
        (should (equal (sort (copy-sequence rata-test-hn--requests) #'string<)
                       (sort (list (rata-test-hn--api 1000) rata-test-hn--article-url) #'string<)))
        (should (equal (alist-get rata-test-hn--article-url rata-test-hn--caps nil nil #'equal)
                       rata-elfeed-hn-article-max-bytes))
        (rata-test-hn--flush)
        (let ((story (rata-test-hn--section-text 'story))
              (text (rata-test-hn--text)))
          (should (string-match-p "^Show HN: A test thread$" story))
          (should (string-match-p "^example\\.com · 42 points · by op · .* ago · 4 comments$" story))
          (should (string-match-p "three properties we now think"
                                  (replace-regexp-in-string "\n" " " (rata-test-hn--section-text 'article))))
          ;; elfeed's own content -- the one word -- is gone.
          (should-not (string-match-p "^Comments$" text))
          (should (string-match-p "^4 comments · 42 points$" text))
          (should (< (string-match "Show HN: A test thread\n" text)
                     (string-match "three properties" text)
                     (string-match "^4 comments" text))))))))

(ert-deftest rata-test-hn-ask-hn-shows-post-text ()
  "An Ask HN entry shows the post's own text, and fetches no article."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (list (cons (rata-test-hn--api 2000)
                    (rata-test-hn--ok (rata-test-hn--fixture "ask-2000.json"))))
      (with-current-buffer
          (rata-test-hn--show
           (rata-test-hn--entry 2000 "Ask HN: How do you read Hacker News?"
                                "https://news.ycombinator.com/item?id=2000"
                                "<p>I mostly read it in Emacs.</p><p>Comments URL: <a href=\"https://news.ycombinator.com/item?id=2000\">x</a></p>"))
        (rata-test-hn--flush)
        (should (equal rata-test-hn--requests (list (rata-test-hn--api 2000))))
        (should (string-match-p "I mostly read it in Emacs these days\\."
                                (rata-test-hn--section-text 'article)))
        (should (string-match-p "^7 points · by asker · .* · 1 comment$"
                                (rata-test-hn--section-text 'story)))
        (should (equal (rata-test-hn--blocks) '((2001 0 0))))))))

(ert-deftest rata-test-hn-article-failures-degrade ()
  "Each way an article can fail leaves the link line and its reason.
The comments render regardless."
  (pcase-dolist (`(,reply ,reason)
                 `((,(rata-test-hn--ok "%PDF-1.7" "application/pdf") "application/pdf")
                   ((:error "over 2048 KB") "over 2048 KB")
                   (,(rata-test-hn--ok (rata-test-hn--fixture "cookie-wall.html") "text/html")
                    "no readable text")
                   ((:error "HTTP 403") "HTTP 403")
                   ((:error "timed out") "timed out")))
    (rata-test-hn--with-elfeed
      (rata-test-hn--with-net (rata-test-hn--story-routes reply)
        (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
          (rata-test-hn--flush)
          (should (equal (string-trim (rata-test-hn--section-text 'article))
                         (format "article not fetched (%s) — , o to open" reason)))
          (should (string-match-p "example\\.com · 42 points" (rata-test-hn--section-text 'story)))
          (should (= (length (rata-test-hn--blocks)) 5)))))))

(ert-deftest rata-test-hn-article-fetch-can-be-turned-off ()
  "With `rata-elfeed-hn-fetch-article' nil the article's site is never contacted."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (rata-test-hn--story-routes (rata-test-hn--ok (rata-test-hn--fixture "article.html") "text/html"))
      (let ((rata-elfeed-hn-fetch-article nil))
        (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
          (rata-test-hn--flush)
          (should (equal rata-test-hn--requests (list (rata-test-hn--api 1000))))
          (should (string-match-p "article not fetched (turned off)"
                                  (rata-test-hn--section-text 'article)))
          (should (= (length (rata-test-hn--blocks)) 5)))))))

(ert-deftest rata-test-hn-story-replaces-content-under-goodies-renderer ()
  "The content is replaced under elfeed-goodies' renderer too.
This config uses `elfeed-goodies/show-refresh--plain', which draws a
newline and the content with no marker property -- the mail-style
renderer's `elfeed-entry-content' marker is not there to find."
  (rata-test-hn--with-elfeed
    (rata-test-hn--with-net
        (rata-test-hn--story-routes (list :error "HTTP 403"))
      (let ((elfeed-show-refresh-function
             (if (fboundp 'elfeed-goodies/show-refresh--plain)
                 #'elfeed-goodies/show-refresh--plain
               ;; Its body, as of 2026-10-06, for when goodies is not loaded.
               (lambda ()
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert "\n")
                   (elfeed-insert-html (elfeed-deref (elfeed-entry-content elfeed-show-entry)))
                   (goto-char (point-min)))))))
        (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
          (rata-test-hn--flush)
          (let ((text (rata-test-hn--text)))
            (should (string-prefix-p "\n\nShow HN: A test thread\n" text))
            (should-not (string-match-p "^Comments$" text))
            (should (= (length (rata-test-hn--blocks)) 5))))))))

(defmacro rata-test-hn--with-thread (&rest body)
  "Run BODY in an elfeed entry buffer showing the edge thread, in normal state."
  (declare (indent 0))
  `(rata-test-hn--with-elfeed
     (rata-test-hn--with-net
         (rata-test-hn--story-routes (list :error "HTTP 403"))
       (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
         (rata-test-hn--flush)
         (evil-local-mode 1)
         (evil-normal-state)
         ,@body))))

(defun rata-test-hn--goto-comment (id)
  "Move point to the start of comment ID."
  (goto-char (text-property-any (point-min) (point-max) 'rata-elfeed-hn-id id)))

(defun rata-test-hn--hidden ()
  "The ids of the comment blocks that are invisible, in order."
  (cl-loop for b in (rata-elfeed-hn--blocks)
           when (invisible-p (nth 0 b)) collect (nth 3 b)))

(ert-deftest rata-test-hn-keys-resolve-in-elfeed-show ()
  "Every thread key resolves in normal state, and elfeed's own keys survive."
  (rata-test-hn--with-thread
    (should rata-elfeed-hn-thread-mode)
    (pcase-dolist (`(,key ,command ,_label) rata-elfeed-hn--keys)
      (should (equal (cons key (key-binding (kbd key))) (cons key command))))
    (let ((ours (mapcar (lambda (k) (key-binding (kbd k))) '("]]" "[[" "TAB"))))
      (rata-elfeed-hn-thread-mode -1)
      (should (equal ours (mapcar (lambda (k) (key-binding (kbd k))) '("]]" "[[" "TAB"))))
      (should-not (memq (key-binding (kbd "za")) '(rata-elfeed-hn-toggle-fold))))))

(ert-deftest rata-test-hn-keys-only-where-there-is-a-thread ()
  "The reused entry buffer drops the thread keys on a non-HN entry."
  (rata-test-hn--with-thread
    (rata-test-hn--show (rata-test-hn--blog-entry))
    (should-not rata-elfeed-hn-thread-mode)))

(ert-deftest rata-test-hn-fold-hides-exactly-the-replies ()
  "`za' hides a comment's replies and nothing else; again shows them."
  (rata-test-hn--with-thread
    (rata-test-hn--goto-comment 1001)
    (forward-line 1)                    ; anywhere in the comment will do
    (rata-elfeed-hn-toggle-fold)
    (should (equal (rata-test-hn--hidden) '(1002)))
    (should-not (invisible-p (1- (nth 1 (car (rata-elfeed-hn--block-at))))))
    (rata-elfeed-hn-toggle-fold)
    (should-not (rata-test-hn--hidden))
    (rata-elfeed-hn-fold)
    (rata-elfeed-hn-fold)                ; idempotent
    (rata-elfeed-hn-unfold)
    (should-not (rata-test-hn--hidden))
    ;; A comment with no replies has nothing to fold.
    (rata-test-hn--goto-comment 1006)
    (rata-elfeed-hn-toggle-fold)
    (should-not (rata-test-hn--hidden))))

(ert-deftest rata-test-hn-fold-all-leaves-top-level ()
  "`zM' leaves only depth-0 comments visible; `zR' shows everything."
  (rata-test-hn--with-thread
    (rata-elfeed-hn-fold-all)
    (should (equal (rata-test-hn--hidden) '(1002 1005)))
    (rata-elfeed-hn-unfold-all)
    (should-not (rata-test-hn--hidden))))

(ert-deftest rata-test-hn-large-thread-opens-folded ()
  "Over `rata-elfeed-hn-fold-threshold' comments, replies open folded."
  (let ((rata-elfeed-hn-fold-threshold 3))
    (rata-test-hn--with-thread
      (should (equal (rata-test-hn--hidden) '(1002 1005)))))
  (let ((rata-elfeed-hn-fold-threshold 4))
    (rata-test-hn--with-thread
      (should-not (rata-test-hn--hidden)))))

(ert-deftest rata-test-hn-sibling-and-parent-navigation ()
  "`zj'/`zk' move between comments at one depth, skipping replies; `zu' goes up."
  (rata-test-hn--with-thread
    (cl-flet ((at () (get-text-property (point) 'rata-elfeed-hn-id)))
      (goto-char (point-min))
      (rata-elfeed-hn-next-sibling)       ; from the story: the first comment
      (should (equal (at) 1001))
      (rata-elfeed-hn-next-sibling)       ; skips bob's reply
      (should (equal (at) 1004))
      (rata-elfeed-hn-next-sibling)
      (should (equal (at) 1006))
      (should-error (rata-elfeed-hn-next-sibling) :type 'user-error)
      (rata-elfeed-hn-previous-sibling)
      (should (equal (at) 1004))
      (rata-test-hn--goto-comment 1005)
      (should-error (rata-elfeed-hn-next-sibling) :type 'user-error) ; last reply under 1004
      (rata-elfeed-hn-parent)
      (should (equal (at) 1004))
      (should-error (rata-elfeed-hn-parent) :type 'user-error))))

(ert-deftest rata-test-hn-permalink-and-browser-commands ()
  "`, y' copies the comment's permalink; `, o'/`, O' bypass the routing."
  (rata-test-hn--with-thread
    (let ((kill-ring nil) opened)
      (rata-test-hn--goto-comment 1005)
      (rata-elfeed-hn-copy-permalink)
      (should (equal (car kill-ring) "https://news.ycombinator.com/item?id=1005"))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _)
                   (push (cons url (cl-some (lambda (h) (eq (cdr h) 'rata-elfeed-hn-browse-url))
                                            browse-url-handlers))
                         opened))))
        (rata-elfeed-hn-open-article)
        (rata-elfeed-hn-open-thread-in-browser))
      (should (equal opened '(("https://news.ycombinator.com/item?id=1000")
                              ("https://example.com/post")))))))

(ert-deftest rata-test-hn-item-url-routing ()
  "Item URLs, and nothing else, route to the HN buffer."
  (dolist (url '("https://news.ycombinator.com/item?id=1"
                 "http://news.ycombinator.com/item?id=42"
                 "https://www.news.ycombinator.com/item?id=42"))
    (should (rata-elfeed-hn--route-p url))
    (should (equal (rata-elfeed-hn--parse-item url)
                   (string-to-number (car (last (split-string url "=")))))))
  (dolist (url '("https://news.ycombinator.com/news"
                 "https://news.ycombinator.com/item?id="
                 "https://news.ycombinator.com/item?id=5&p=2"
                 "https://evil.example/news.ycombinator.com/item?id=1"
                 "https://news.ycombinator.com.evil.example/item?id=1"))
    (should-not (rata-elfeed-hn--route-p url)))
  (should (equal (rata-elfeed-hn--parse-item " 8863 ") 8863))
  (should (equal (rata-elfeed-hn--parse-item 8863) 8863))
  (should-not (rata-elfeed-hn--parse-item "news"))
  (require 'browse-url)
  (should (eq (cdr (cl-find-if (lambda (h) (functionp (car h))) browse-url-handlers
                               :key (lambda (h) (and (eq (cdr h) 'rata-elfeed-hn-browse-url) h))))
              'rata-elfeed-hn-browse-url))
  (should (eq (browse-url-select-handler "https://news.ycombinator.com/item?id=1")
              'rata-elfeed-hn-browse-url))
  (let ((rata-elfeed-hn-route-item-links nil))
    (should-not (eq (browse-url-select-handler "https://news.ycombinator.com/item?id=1")
                    'rata-elfeed-hn-browse-url))))

(ert-deftest rata-test-hn-open-item-buffer ()
  "An item opened by URL shows story, article and thread in `*HN <id>*'."
  (rata-test-hn--with-net
      (rata-test-hn--story-routes
       (rata-test-hn--ok (rata-test-hn--fixture "article.html") "text/html"))
    (require 'shr)                      ; so the binding below is dynamic
    (let ((shr-use-fonts nil))
      (cl-letf (((symbol-function 'pop-to-buffer) #'set-buffer))
        (unwind-protect
            (progn
              (rata-elfeed-hn-open-item "https://news.ycombinator.com/item?id=1000")
              (with-current-buffer "*HN 1000*"
                (should (derived-mode-p 'rata-elfeed-hn-item-mode))
                (should rata-elfeed-hn-thread-mode)
                ;; No entry here: the article URL comes with the thread.
                (should (equal rata-test-hn--requests (list (rata-test-hn--api 1000))))
                (rata-test-hn--flush)
                (should (equal (cadr rata-test-hn--requests) rata-test-hn--article-url))
                (should (string-match-p "^Show HN: A test thread$" (rata-test-hn--section-text 'story)))
                (should (string-match-p "three properties"
                                        (replace-regexp-in-string
                                         "\n" " " (rata-test-hn--section-text 'article))))
                (should (= (length (rata-test-hn--blocks)) 5))
                ;; `g' redraws from the network, not the caches: the thread,
                ;; then -- once the thread names it -- the article again.
                (revert-buffer)
                (rata-test-hn--flush)
                (should (= (length rata-test-hn--requests) 4))
                (should (= (length (rata-test-hn--blocks)) 5))))
          (when (get-buffer "*HN 1000*") (kill-buffer "*HN 1000*")))))))

(ert-deftest rata-test-hn-curl-args ()
  "curl follows redirects, bounds time and, when asked, size; URL comes last."
  (let ((args (rata-elfeed-hn--curl-args "https://example.com/a" 2048 20)))
    (should (member "--location" args))
    (should (equal (cadr (member "--max-time" args)) "20"))
    (should (equal (cadr (member "--max-filesize" args)) "2048"))
    (should (equal (last args 2) '("--" "https://example.com/a"))))
  (should-not (member "--max-filesize" (rata-elfeed-hn--curl-args "https://x" nil 20))))

(ert-deftest rata-test-hn-curl-result ()
  "curl's stdout, exit code and stderr become a result, never a signal."
  (let ((ok (encode-coding-string "<p>héllo</p>\n200 text/html; charset=UTF-8" 'utf-8)))
    (should (equal (rata-elfeed-hn--curl-result ok 0 "" nil)
                   '(:ok t :type "text/html" :body "<p>héllo</p>"))))
  (should (equal (rata-elfeed-hn--curl-result "gone\n404 text/html" 0 "" nil)
                 '(:error "HTTP 404")))
  (should (equal (rata-elfeed-hn--curl-result "%PDF\n200 application/pdf" 0 "" nil)
                 '(:ok t :type "application/pdf" :body "%PDF")))
  (should (equal (rata-elfeed-hn--curl-result "" 28 "curl: (28) Operation timed out" nil)
                 '(:error "timed out")))
  (should (equal (rata-elfeed-hn--curl-result "" 63 "" 2048) '(:error "over 2 KB")))
  (should (equal (rata-elfeed-hn--curl-result (concat (make-string 3000 ?x) "\n200 text/html") 0 "" 2048)
                 '(:error "over 2 KB")))
  (should (equal (rata-elfeed-hn--curl-result "" 6 "curl: (6) Could not resolve host: x\n" nil)
                 '(:error "Could not resolve host: x")))
  (should (equal (rata-elfeed-hn--curl-result "" 7 "" nil) '(:error "curl exited 7")))
  (should (equal (rata-elfeed-hn--curl-result "no status line" 0 "" nil)
                 '(:error "no response"))))

(ert-deftest rata-test-hn-curl-retrieve-plumbing ()
  "A real process through `rata-elfeed-hn--curl-retrieve', against a stub curl.
This is the path that replaced url.el for articles: url.el does not race
IPv6 against IPv4, so on a network with an unrouted IPv6 address every
site that publishes an AAAA record timed out."
  (let* ((program (expand-file-name "tests/fixtures/hn/fake-curl" user-emacs-directory))
         (args-file (make-temp-file "rata-fake-curl-args"))
         (process-environment
          (append (list (concat "RATA_FAKE_CURL_BODY="
                                (expand-file-name "tests/fixtures/hn/article.html" user-emacs-directory))
                        (concat "RATA_FAKE_CURL_ARGS=" args-file))
                  process-environment))
         result)
    (unwind-protect
        (progn
          (rata-elfeed-hn--curl-retrieve program "https://example.com/post" 4096
                                         (lambda (r) (setq result r)))
          (with-timeout (10 (ert-fail "the stub curl never finished"))
            (while (not result) (accept-process-output nil 0.05)))
          (should (eq (plist-get result :ok) t))
          (should (equal (plist-get result :type) "text/html"))
          (should (string-match-p "three properties we now think" (plist-get result :body)))
          (should (member "https://example.com/post"
                          (with-temp-buffer (insert-file-contents args-file)
                                            (split-string (buffer-string) "\n" t))))
          ;; A failing curl reports its exit, not a hang and not a signal.
          (setq result nil)
          (let ((process-environment (cons "RATA_FAKE_CURL_EXIT=28" process-environment)))
            (rata-elfeed-hn--curl-retrieve program "https://example.com/post" nil
                                           (lambda (r) (setq result r)))
            (with-timeout (10 (ert-fail "the stub curl never finished"))
              (while (not result) (accept-process-output nil 0.05))))
          (should (equal result '(:error "timed out")))
          (should-not (cl-find-if (lambda (b) (string-prefix-p " *rata-elfeed-hn-curl" (buffer-name b)))
                                  (buffer-list))))
      (delete-file args-file))))

(ert-deftest rata-test-hn-ok-result-keeps-image-bytes ()
  "Text is decoded; an image, SVG included, is kept as the bytes it is."
  (let ((png (unibyte-string #x89 ?P ?N ?G #x0d #x0a #x1a #x0a #xff #xd8)))
    (should (equal (plist-get (rata-elfeed-hn--ok-result "image/png" png) :body) png))
    (should-not (multibyte-string-p (plist-get (rata-elfeed-hn--ok-result "image/png" png) :body))))
  (let ((svg (encode-coding-string "<svg>é</svg>" 'utf-8)))
    (should (equal (plist-get (rata-elfeed-hn--ok-result "image/svg+xml" svg) :body) svg)))
  (should (equal (plist-get (rata-elfeed-hn--ok-result "text/html; charset=utf-8"
                                                       (encode-coding-string "é" 'utf-8))
                            :body)
                 "é")))

(defmacro rata-test-hn--with-image-article (images &rest body)
  "Show the edge thread with an article holding two images, replies IMAGES.
IMAGES is an alist of image URL to fake result.  Inside BODY,
`placed' lists the (DATA TYPE ALT) shr was asked to insert, newest first;
batch Emacs cannot display an image, so shr's inserter is stubbed."
  (declare (indent 1))
  `(rata-test-hn--with-elfeed
     (rata-test-hn--with-net
         (append (rata-test-hn--story-routes
                  (rata-test-hn--ok (rata-test-hn--fixture "article-images.html") "text/html"))
                 ,images)
       (let* ((placed nil)
              (shr-put-image-function
               (lambda (spec alt &optional _flags)
                 (push (list (car spec) (cadr spec) alt) placed)
                 (insert "[IMG]"))))
         (with-current-buffer (rata-test-hn--show (rata-test-hn--rss-entry 1000 "Show HN: A test thread"))
           ,@body)))))

(defconst rata-test-hn--png (unibyte-string #x89 ?P ?N ?G #x0d #x0a #x1a #x0a))

(ert-deftest rata-test-hn-article-images-arrive-through-retrieve ()
  "Article images are fetched by this module, not by shr through url.el.
shr's own fetch goes through `url-queue-retrieve', which stalls on an
unrouted IPv6 address like every url.el request (FAIL-0024).  A relative
src resolves against the article: `shr-insert-document' ignores a bound
`shr-base' and reads only a <base> element."
  (rata-test-hn--with-image-article
      (list (cons "https://example.com/img/one.png" (rata-test-hn--ok rata-test-hn--png "image/png"))
            (cons "https://cdn.example.net/two.png" (rata-test-hn--ok rata-test-hn--png "image/png")))
    (cl-letf (((symbol-function 'url-queue-retrieve)
               (lambda (url &rest _) (error "shr fetched %s itself" url))))
      (rata-test-hn--flush))
    (should (member "https://example.com/img/one.png" rata-test-hn--requests))
    (should (member "https://cdn.example.net/two.png" rata-test-hn--requests))
    (should (equal (alist-get "https://example.com/img/one.png" rata-test-hn--caps nil nil #'equal)
                   rata-elfeed-hn-image-max-bytes))
    (should (equal (sort (mapcar #'caddr placed) #'string<)
                   '("the new build graph" "the old build graph")))
    (should (cl-every (lambda (p) (and (equal (car p) rata-test-hn--png) (eq (cadr p) 'image/png)))
                      placed))
    (let ((article (rata-test-hn--section-text 'article)))
      (should (= 2 (how-many "\\[IMG\\]" (car (rata-elfeed-hn--section-bounds 'article))
                             (cdr (rata-elfeed-hn--section-bounds 'article)))))
      (should (string-match-p "three properties" (replace-regexp-in-string "\n" " " article))))
    ;; The relative link resolves too.
    ;; `text-property-any' compares with `eq', so scan with `equal'.
    (should (cl-loop for pos from (point-min) below (point-max)
                     thereis (equal (get-text-property pos 'shr-url)
                                    "https://example.com/posts/part-two")))))

(ert-deftest rata-test-hn-article-images-degrade-and-stop ()
  "A failed image keeps its placeholder; at most `rata-elfeed-hn-max-images'
are fetched; and leaving the entry stops the queue."
  (let ((rata-elfeed-hn-max-images 1))
    (rata-test-hn--with-image-article
        (list (cons "https://example.com/img/one.png" (list :error "HTTP 404")))
      (rata-test-hn--flush)
      (should (equal (cl-count-if (lambda (u) (string-match-p "\\.png\\'" u)) rata-test-hn--requests) 1))
      (should-not placed)
      (should (string-match-p "three properties"
                              (replace-regexp-in-string "\n" " " (rata-test-hn--section-text 'article))))))
  (rata-test-hn--with-image-article
      (list (cons "https://example.com/img/one.png" (rata-test-hn--ok rata-test-hn--png "image/png"))
            (cons "https://cdn.example.net/two.png" (rata-test-hn--ok rata-test-hn--png "image/png")))
    ;; Answer the article and thread only, then leave before the images.
    (let ((first (reverse rata-test-hn--pending)))
      (setq rata-test-hn--pending nil)
      (pcase-dolist (`(,url ,cb) first)
        (funcall cb (cdr (assoc url rata-test-hn--routes))))
      (rata-test-hn--drain))
    (rata-test-hn--show (rata-test-hn--blog-entry))
    (rata-test-hn--flush)
    (should-not placed)))

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
;;; Test — LLM providers drive gptel, ellama and aidermacs (lisp/init-llm.el)
;;; ============================================================

(defconst rata-test--llm-ollama-provider
  '(:name "Ollama" :protocol ollama :url "http://localhost:11434"
    :models ("qwen3.5-coder:9b-32k" "mistral:latest")
    :embedding-model "nomic-embed-text")
  "The home shape: local Ollama, no key.")

(defconst rata-test--llm-litellm-provider
  '(:name "LiteLLM" :protocol openai :url "https://litellm.example.com/v1/"
    :models ("gpt-x" "gpt-y"))
  "The work shape: an OpenAI-compatible proxy, keyed.  Trailing slash on
purpose -- the entry is hand-typed in local.el and both spellings must work.")

(ert-deftest rata-test-llm-ollama-provider-configures-all-three-tools ()
  "One Ollama entry becomes gptel's, ellama's and aider's own configuration.
D-022: endpoint and models are data in `rata-llm-providers\='; each tool
derives its shape from the same entry, so a machine changes one variable."
  (let* ((p rata-test--llm-ollama-provider)
         (gptel (rata-llm-gptel-backend-spec p))
         (ellama (rata-llm-ellama-provider-spec p)))
    (should (eq (car gptel) 'gptel-make-ollama))
    (should (equal (cadr gptel) "Ollama"))
    (let ((args (cddr gptel)))
      (should (equal (plist-get args :host) "localhost:11434"))
      (should (equal (plist-get args :protocol) "http"))
      (should (equal (plist-get args :endpoint) "/api/chat"))
      ;; Bare tags as symbols: gptel talks to Ollama directly, no litellm prefix.
      (should (equal (plist-get args :models) '(qwen3.5-coder:9b-32k mistral:latest)))
      (should-not (plist-get args :key)))
    (should (eq (rata-llm-gptel-default-model p) 'qwen3.5-coder:9b-32k))
    (should (eq (car ellama) 'make-llm-ollama))
    (let ((args (cdr ellama)))
      (should (equal (plist-get args :scheme) "http"))
      (should (equal (plist-get args :host) "localhost"))
      (should (eql (plist-get args :port) 11434))
      (should (equal (plist-get args :chat-model) "qwen3.5-coder:9b-32k"))
      (should (equal (plist-get args :embedding-model) "nomic-embed-text")))
    (should (equal (rata-llm-aider-model p) "ollama_chat/qwen3.5-coder:9b-32k"))
    (should (equal (rata-llm-aider-environment p nil)
                   '("OLLAMA_API_BASE=http://localhost:11434")))
    (should-not (rata-llm-auth-host p))))

(ert-deftest rata-test-llm-openai-provider-configures-all-three-tools ()
  "An OpenAI-compatible entry reaches all three tools, keyed but key-free.
The key is a closure over the auth-source host, resolved through
`rata-auth-get\=' when called and never at load; the config carries the
host, ~/.authinfo.gpg carries the secret.  Stubbed here: nothing in
tests/ opens that file."
  (let* ((p rata-test--llm-litellm-provider)
         (asked nil)
         (gptel (rata-llm-gptel-backend-spec p))
         (ellama (rata-llm-ellama-provider-spec p)))
    (should (equal (rata-llm-auth-host p) "litellm.example.com"))
    (should (eq (car gptel) 'gptel-make-openai))
    (let ((args (cddr gptel)))
      (should (equal (plist-get args :host) "litellm.example.com"))
      (should (equal (plist-get args :protocol) "https"))
      (should (equal (plist-get args :endpoint) "/v1/chat/completions"))
      (should (equal (plist-get args :models) '(gpt-x gpt-y)))
      (should (functionp (plist-get args :key)))
      (cl-letf (((symbol-function 'rata-auth-get)
                 (lambda (host &optional _user) (setq asked host) "sk-test")))
        (should (equal (funcall (plist-get args :key)) "sk-test")))
      (should (equal asked "litellm.example.com")))
    (should (eq (car ellama) 'make-llm-openai-compatible))
    (let ((args (cdr ellama)))
      ;; llm wants the base with exactly one trailing slash.
      (should (equal (plist-get args :url) "https://litellm.example.com/v1/"))
      (should (functionp (plist-get args :key)))
      (should (equal (plist-get args :chat-model) "gpt-x"))
      (should-not (plist-member args :embedding-model)))
    (should (equal (rata-llm-aider-model p) "openai/gpt-x"))
    (should (equal (rata-llm-aider-environment p "sk-test")
                   '("OPENAI_API_BASE=https://litellm.example.com/v1"
                     "OPENAI_API_KEY=sk-test")))
    (should (equal (rata-llm-aider-environment p nil)
                   '("OPENAI_API_BASE=https://litellm.example.com/v1")))
    ;; An explicit nil :auth-host means a keyless server, not "derive it".
    (let ((keyless (append '(:auth-host nil) p)))
      (should-not (rata-llm-auth-host keyless))
      (should-not (plist-get (cddr (rata-llm-gptel-backend-spec keyless)) :key)))
    (let ((named (append '(:auth-host "llm-proxy") p)))
      (should (equal (rata-llm-auth-host named) "llm-proxy")))))

(ert-deftest rata-test-llm-aider-environment-is-scoped-to-the-aider-child ()
  "The hook is installed, and what it sets stays inside aidermacs's `let\='.
aidermacs runs `aidermacs-before-run-backend-hook\=' inside a `let\=' of
`process-environment\=' (aidermacs-backends.el:91); pushing there hands the
key to the aider child and to nothing else Emacs spawns."
  (should (memq #'rata-llm-aider-set-environment aidermacs-before-run-backend-hook))
  (let ((rata-llm-providers (list rata-test--llm-litellm-provider))
        (before (getenv "OPENAI_API_KEY")))
    (cl-letf (((symbol-function 'rata-auth-get)
               (lambda (host &optional _user) (concat "key-for-" host))))
      (let ((process-environment (copy-sequence process-environment)))
        (rata-llm-aider-set-environment)
        (should (equal (getenv "OPENAI_API_BASE") "https://litellm.example.com/v1"))
        (should (equal (getenv "OPENAI_API_KEY") "key-for-litellm.example.com"))))
    (should (equal (getenv "OPENAI_API_KEY") before))))

(ert-deftest rata-test-llm-provider-problems-name-the-entry ()
  "A malformed entry is reported by index and name, one line per fault.
The loaded value is checked too: on a machine whose local.el entry is
wrong, this is the test that says so, in the same words as the startup
warning."
  (should-not (rata-llm-provider-problems (list rata-test--llm-ollama-provider
                                                rata-test--llm-litellm-provider)))
  (should-not (rata-llm-provider-problems rata-llm-providers))
  (should (equal (rata-llm-provider-problems "ollama")
                 '("rata-llm-providers is not a list")))
  (let ((problems (rata-llm-provider-problems
                   '((:name "Bad" :protocol litellm :url "litellm.example.com" :models ())
                     (:protocol ollama)))))
    (should (= (length problems) 4))
    (should (cl-every (lambda (s) (string-prefix-p "entry 0 (Bad)" s))
                      (seq-take problems 3)))
    (should (string-match-p ":protocol" (nth 0 problems)))
    (should (string-match-p ":url" (nth 1 problems)))
    (should (string-match-p ":models" (nth 2 problems)))
    (should (string-prefix-p "entry 1 (unnamed)" (nth 3 problems)))))

(ert-deftest rata-test-llm-tracked-default-is-localhost-only ()
  "The default in the tracked source names no host but localhost.
D-022: Ollama on localhost may stay in git because it is not identity;
anything else -- a work proxy, a homelab hostname -- belongs in local.el.
Reads the file on disk, not the loaded value, which local.el may have
replaced on this machine."
  (let ((default
         (with-temp-buffer
           (insert-file-contents
            (expand-file-name "lisp/init-llm.el" user-emacs-directory))
           (goto-char (point-min))
           (re-search-forward "^(defcustom rata-llm-providers$")
           (eval (read (current-buffer)) t))))
    (should (consp default))
    (should-not (rata-llm-provider-problems default))
    (dolist (provider default)
      (should (eq (plist-get provider :protocol) 'ollama))
      (should (equal (url-host (url-generic-parse-url (plist-get provider :url)))
                     "localhost")))))

(ert-deftest rata-test-llm-tools-start-on-the-default-provider ()
  "Once loaded, gptel, ellama and aidermacs all sit on the first provider.
This is the FAIL-0016 check for this module: the two :config bodies must
actually run and agree with the data, and the aidermacs :custom value must
be applied when its `defcustom\=' runs (it is void before the package loads,
like the ACP adapter pins -- so the package is loaded here first)."
  (let ((default (rata-llm-default-provider)))
    ;; `aidermacs-models', not `aidermacs': the umbrella pulls in the vterm
    ;; backend, and vterm prompts to compile its module at load (FAIL-0022).
    (skip-unless (and (require 'aidermacs-models nil t) (require 'gptel nil t)
                      (require 'ellama nil t)))
    (should (equal aidermacs-default-model (rata-llm-aider-model default)))
    (should (equal (gptel-backend-name gptel-backend) (plist-get default :name)))
    (should (eq gptel-model (rata-llm-gptel-default-model default)))
    (should (= (length ellama-providers) (length rata-llm-providers)))
    (should (equal (caar ellama-providers) (plist-get default :name)))
    (should (eq ellama-provider (cdar ellama-providers)))))

;;; ============================================================
;;; Test — Khoj's server comes from a variable local.el can set (lisp/init-khoj.el)
;;; ============================================================

(ert-deftest rata-test-khoj-server-url-comes-from-rata-variable ()
  "`khoj-server-url\=' is `rata-khoj-server-url\=' once khoj has loaded.
L-051: use-package :custom runs `custom-theme-set-variables\=' when the
package loads, after local.el, so a template line saying
\=(setq khoj-server-url ...) was overwritten the moment khoj loaded.  The
module now hands :custom the `rata-\=' variable, and local.el.example names
that one.  Loads khoj with its auto-index timer disabled: the package
would otherwise schedule `khoj--server-index-files\=' -- a network call --
sixty seconds in."
  (should (boundp 'rata-khoj-server-url))
  (should (stringp rata-khoj-server-url))
  (defvar khoj-auto-index)
  (defvar khoj--index-timer)
  (let ((khoj-auto-index nil))
    (skip-unless (require 'khoj nil t)))
  (when (and (boundp 'khoj--index-timer) khoj--index-timer)
    (cancel-timer khoj--index-timer))
  (should (equal khoj-server-url rata-khoj-server-url))
  ;; The template must name the variable that actually works.
  (with-temp-buffer
    (insert-file-contents (expand-file-name "local.el.example" user-emacs-directory))
    (should (search-forward "(setq rata-khoj-server-url" nil t))
    (goto-char (point-min))
    (should-not (search-forward "(setq khoj-server-url" nil t))))

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

(defun rata-test--agent-shell-needs-fragment-map ()
  "Skip the calling test when the installed agent-shell predates the fragment map.

`agent-shell-ui-fragment-map' and `agent-shell-ui-make-foldable-text' arrived
upstream on 2026-08-14.  The fix in `init-llm.el' extends that map, so on an
older clone there is nothing to test -- the GUI Enter bug is simply still
present and the remedy is `elpaca-update agent-shell', not a code change.  A
skip says that; a failure said `void-variable' and read like a broken config
(FAIL-0019).  With no lockfile, each machine's clone is its own vintage."
  (unless (and (boundp 'agent-shell-ui-fragment-map)
               (fboundp 'agent-shell-ui-make-foldable-text))
    (ert-skip "installed agent-shell predates `agent-shell-ui-fragment-map' (upstream 2026-08-14); update the package to run this test")))

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
  (rata-test--agent-shell-needs-fragment-map)
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

What Enter resolves to off the chrome is evil-collection's business and
varies with its vintage: with its `shell-maker' module and `repl-submit'
theme (upstream since mid-2026) normal state submits and insert state
inserts a newline; without them (the March 2026 clone on the Arch host)
normal state is `evil-ret' and insert state is `agent-shell-submit' via
comint's remap.  The first version of this test hard-coded the former and
failed on the latter (FAIL-0019).  So the assertion is the invariant the
fix must keep, not one theme's commands: off the chrome, neither spelling
of Enter is the fold toggle, and `RET' still resolves to a command.  (A nil
`<return>' is fine -- that is precisely the case where Emacs falls back to
translating it to `RET'.)"
  (require 'agent-shell)
  (require 'agent-shell-ui)
  (rata-test--agent-shell-needs-fragment-map)
  (let (failures)
    (dolist (state '(normal insert))
      (dolist (keys '("RET" "<return>"))
        (let ((got (rata-test--agent-shell-binding keys state 'prompt)))
          (when (eq got 'agent-shell-ui-toggle-fragment)
            (push (format "%s state, point off fold chrome: %s -> %s (the fold binding leaked)"
                          state keys got)
                  failures))
          (when (and (equal keys "RET") (not (commandp got)))
            (push (format "%s state, point off fold chrome: RET -> %S (not a command)"
                          state got)
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
;;; Org task ordering (init-org.el)
;;; ============================================================
;;
;; The task files are flat `** TODO' lists that nothing kept in order; these
;; pin the two things that now do: the stable sort and the move on state
;; change.  Everything runs in a temp buffer — nothing under second-brain is
;; touched — and `org-todo' is driven for real so the hook wiring itself is
;; under test, not just the helper it calls.

(defconst rata-test--task-file
  (concat "#+filetags: :hastodo:\n"
          "#+SEQ_TODO: TODO STRT WAIT | DONE\n\n"
          "* Tasks\n"
          "** DONE a\nCLOSED: [2026-01-01 Thu 10:00]\n"
          "** TODO b\nbody b\n*** sub of b\n"
          "** DONE c\nCLOSED: [2026-02-01 Sun 10:00]\n"
          "** STRT d\n"
          "** TODO e\n"
          "** WAIT f\n"
          "** DONE g\n")
  "A task list in the shape of work_tasks.org, deliberately out of order.")

(defun rata-test--task-order ()
  "Titles of the level-2 headings in the current buffer, in order."
  (mapcar #'substring-no-properties
          (org-map-entries (lambda () (org-get-heading t t t t)) "LEVEL=2")))

(defun rata-test--goto-task (title)
  "Move point to the level-2 heading whose title is TITLE."
  (goto-char (point-min))
  (re-search-forward (concat "^\\*\\* [A-Z]+ " (regexp-quote title) "$")))

(ert-deftest rata-test-org-sort-tasks-orders-by-state-then-closed ()
  "`rata-org-sort-tasks' sorts siblings: open states in #+SEQ_TODO order,
done states last with the newest CLOSED first, hand order otherwise kept.
Invoked from a task heading so the *siblings* are what gets sorted; the
sub-heading of b travels with its parent."
  (require 'org)
  (with-temp-buffer
    (insert rata-test--task-file)
    (org-mode)
    (rata-test--goto-task "b")
    (rata-org-sort-tasks)
    (should (equal (rata-test--task-order) '("b" "e" "d" "f" "c" "a" "g")))
    (rata-test--goto-task "b")
    (should (looking-at-p "\nbody b\n\\*\\*\\* sub of b\n"))
    ;; Idempotent: a second pass changes nothing.
    (rata-org-sort-tasks)
    (should (equal (rata-test--task-order) '("b" "e" "d" "f" "c" "a" "g")))))

(ert-deftest rata-test-org-state-change-moves-task-across-boundary ()
  "Finishing a task moves it to the head of the finished block with a CLOSED
stamp; reopening one moves it to the end of the open block; a change that
stays inside the open block (TODO -> STRT) leaves it where it is.  Driven
through `org-todo', so a hook that was never added would fail here."
  (require 'org)
  (with-temp-buffer
    (insert rata-test--task-file)
    (org-mode)
    (rata-test--goto-task "b")
    (rata-org-sort-tasks)
    (let ((org-log-done 'time)
          (rata-org-order-tasks-on-state-change t))
      (rata-test--goto-task "b")
      (org-todo "DONE")
      (should (equal (rata-test--task-order) '("e" "d" "f" "b" "c" "a" "g")))
      (rata-test--goto-task "b")
      (should (org-entry-get nil "CLOSED"))
      (rata-test--goto-task "g")
      (org-todo "TODO")
      (should (equal (rata-test--task-order) '("e" "d" "f" "g" "b" "c" "a")))
      (rata-test--goto-task "e")
      (org-todo "STRT")
      (should (equal (rata-test--task-order) '("e" "d" "f" "g" "b" "c" "a"))))))

(ert-deftest rata-test-org-state-change-leaves-other-files-alone ()
  "The move is scoped to `hastodo' files and to the variable that enables it."
  (require 'org)
  (dolist (case `((,(replace-regexp-in-string ":hastodo:" ":notes:" rata-test--task-file) . t)
                  (,rata-test--task-file . nil)))
    (with-temp-buffer
      (insert (car case))
      (org-mode)
      (let ((org-log-done nil)
            (rata-org-order-tasks-on-state-change (cdr case))
            (before (rata-test--task-order)))
        (rata-test--goto-task "b")
        (org-todo "DONE")
        (should (equal (rata-test--task-order) before))))))

(ert-deftest rata-test-org-log-done-stamps-closed ()
  "`org-log-done' is set once org loads; the finished block's order depends on it."
  (require 'org)
  (should (eq org-log-done 'time)))

;;; ============================================================
;;; init-mail.el -- pure helpers and the per-machine contract
;;; ============================================================
;;
;; Nothing here touches Bridge, mu or the network: mu4e's elisp is
;; version-locked to a binary that may not be on the test host, so the tests
;; cover the parts that decide *whether* mu4e loads and *what* the operator
;; is told when it cannot.

(ert-deftest rata-test-mail-mu4e-dir-candidates ()
  "The install prefix is derived from `bin/mu', for both packager layouts."
  (should (equal (rata-mail-mu4e-dir-candidates "/usr/bin/mu")
                 '("/usr/share/emacs/site-lisp/mu/mu4e"
                   "/usr/share/emacs/site-lisp/mu4e"
                   "/usr/share/emacs/site-lisp/mu")))
  ;; Homebrew's Cellar path, as `file-truename' of the bin/mu symlink yields it.
  (should (member "/home/linuxbrew/.linuxbrew/Cellar/mu/1.14.3/share/emacs/site-lisp/mu/mu4e"
                  (rata-mail-mu4e-dir-candidates
                   "/home/linuxbrew/.linuxbrew/Cellar/mu/1.14.3/bin/mu")))
  ;; And the prefix-level symlink farm the PATH entry lives in.
  (should (member "/home/linuxbrew/.linuxbrew/share/emacs/site-lisp/mu/mu4e"
                  (rata-mail-mu4e-dir-candidates "/home/linuxbrew/.linuxbrew/bin/mu"))))

(ert-deftest rata-test-mail-mu4e-dir-found-when-mu-installed ()
  "If `mu' is on PATH, its mu4e must be found -- otherwise the module
silently degrades to `rata-mail-unavailable' on a host that has the tool.
Skipped where mu is absent: the check is about the candidate list matching
the packager, which only a real install can show."
  (skip-unless (executable-find "mu"))
  (should rata-mail--mu4e-dir)
  (should (file-exists-p (expand-file-name "mu4e.el" rata-mail--mu4e-dir))))

(ert-deftest rata-test-mail-unconfigured-names-the-checklist ()
  "With no address set, every entry point stops with a `user-error' that
names local.el.example -- the same contract as `rata-sql-snowflake-uri'."
  (let ((rata-mail-address nil))
    (dolist (cmd '(rata-mail rata-mail-compose rata-mail-search rata-mail-update))
      (let ((err (should-error (funcall cmd) :type 'user-error)))
        (should (string-match-p "local\\.el\\.example" (cadr err)))))))

(ert-deftest rata-test-mail-port-probe ()
  "`rata-mail-port-open-p' is the `is Bridge up' question: true against a
listening socket, nil against a closed port."
  (let ((server (make-network-process :name "rata-test-mail-listener"
                                      :server t :host "127.0.0.1" :service t
                                      :noquery t)))
    (unwind-protect
        (let ((port (process-contact server :service)))
          (should (rata-mail-port-open-p "127.0.0.1" port))
          (delete-process server)
          (should-not (rata-mail-port-open-p "127.0.0.1" port)))
      (when (process-live-p server) (delete-process server)))))

(ert-deftest rata-test-mail-bridge-command-prefers-the-native-binary ()
  "The doctor's Bridge hints must be commands the host can run.  On Arch
`protonmail-bridge --cli' is the Qt launcher, which times out waiting for
a gRPC config the CLI frontend never writes -- so the Go binary wins
whenever it exists, the Flatpak is next, and a bare host is told how to
install rather than handed a command that is not there."
  (let ((rata-mail-bridge-native-binary "/usr/lib/protonmail/bridge/bridge")
        (rata-mail-bridge-flatpak-id "ch.protonmail.protonmail-bridge"))
    (should (equal (rata-mail-bridge-command-for "--cli" t t)
                   "/usr/lib/protonmail/bridge/bridge --cli"))
    (should (equal (rata-mail-bridge-command-for "--noninteractive" nil t)
                   "flatpak run ch.protonmail.protonmail-bridge --noninteractive"))
    (let ((bare (rata-mail-bridge-command-for "--cli" nil nil)))
      (should (string-prefix-p "protonmail-bridge --cli" bare))
      (should (string-match-p "pacman -S protonmail-bridge" bare))
      (should (string-match-p "flatpak install" bare)))
    ;; Never the launcher on PATH when the real binary is known.
    (should-not (string-prefix-p "protonmail-bridge "
                                 (rata-mail-bridge-command-for "--cli" t nil)))))

(ert-deftest rata-test-mail-cert-dir-matches-template ()
  "`cert export' is pointed at the directory of a `rata-mail-bridge-cert-candidates'
entry, and mbsyncrc.example's CertificateFile names one of those same
candidates -- otherwise the doctor's hint and the template disagree about
where the certificate lives."
  (let ((text (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "mbsyncrc.example" user-emacs-directory))
                (buffer-string)))
        (dirs (mapcar (lambda (c) (file-name-directory (expand-file-name c)))
                      rata-mail-bridge-cert-candidates)))
    (should (member (rata-mail-bridge-cert-dir) dirs))
    (should (string-match-p "^CertificateFile " text))
    (should (seq-some (lambda (c) (string-match-p (concat "^CertificateFile " (regexp-quote c) "$") text))
                      rata-mail-bridge-cert-candidates))))

(ert-deftest rata-test-mail-mbsyncrc-example-matches-module ()
  "mbsyncrc.example and init-mail.el describe the same Bridge.
The channel name is what `mu4e-get-mail-command' runs, host and port are
what `rata-mail-update' probes, and the two Proton-specific exclusions are
the difference between a mailbox and a duplicated one."
  (let ((text (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "mbsyncrc.example" user-emacs-directory))
                (buffer-string))))
    (should (string-match-p (format "^Channel %s$" (regexp-quote rata-mail-mbsync-channel)) text))
    (should (string-match-p (format "^Host %s$" (regexp-quote rata-mail-bridge-host)) text))
    (should (string-match-p (format "^Port %d$" rata-mail-bridge-imap-port) text))
    (should (string-match-p (format "port %d" rata-mail-bridge-imap-port) text))
    (should (string-match-p (format "port %d" rata-mail-bridge-smtp-port) text))
    (should (string-match-p "^Patterns .*!\"All Mail\"" text))
    (should (string-match-p "^Patterns .*!\"Labels/\\*\"" text))
    (should (string-match-p "^TLSType STARTTLS$" text))
    ;; The Flatpak certificate path in the template is one the module also trusts.
    (should (seq-some (lambda (cand)
                        (string-match-p (regexp-quote (string-remove-prefix "~/" cand)) text))
                      rata-mail-bridge-cert-candidates))
    ;; No real address leaked into the template.
    (should (string-match-p "CHANGE-ME@proton.me" text))))

;;; ============================================================
;;; init-agent-center: state model and registry
;;; ============================================================
;; Nothing here starts an agent: events are synthetic alists of the shape
;; `agent-shell--emit-event' builds, fed straight to the handler.

(defun rata-test-agent-center--ev (event &rest data)
  "Build an agent-shell event alist for EVENT with DATA as a plist."
  (let ((alist (list (cons :event event))))
    (when data
      (let (pairs)
        (while data
          (push (cons (pop data) (pop data)) pairs))
        (push (cons :data (nreverse pairs)) alist)))
    alist))

(defmacro rata-test-agent-center--with-registry (&rest body)
  "Run BODY against an empty private registry, with rendering stubbed out."
  (declare (indent 0))
  `(let ((rata-agent-center--registry (make-hash-table :test #'eq))
         (renders 0))
     (ignore renders)
     (cl-letf (((symbol-function 'rata-agent-center--schedule-render)
                (lambda () (cl-incf renders)))
               ((symbol-function 'rata-agent-center--schedule-activity-render)
                (lambda () (cl-incf renders))))
       ,@body)))

(ert-deftest rata-test-agent-center-next-state-table ()
  "Every row of the plan's state table is a transition."
  (let ((ev #'rata-test-agent-center--ev))
    ;; needs-input
    (should (eq (rata-agent-center--next-state 'working (funcall ev 'permission-request) nil)
                'needs-input))
    ;; error
    (should (eq (rata-agent-center--next-state 'working (funcall ev 'error :message "x") nil)
                'error))
    ;; done: a finished turn nobody is looking at
    (should (eq (rata-agent-center--next-state 'working (funcall ev 'turn-complete) nil)
                'done))
    ;; ...and ready when the shell is the selected window's buffer
    (should (eq (rata-agent-center--next-state 'working (funcall ev 'turn-complete) t)
                'ready))
    ;; working
    (dolist (e '(input-submitted permission-response tool-call-update))
      (should (eq (rata-agent-center--next-state 'ready (funcall ev e) nil) 'working)))
    ;; starting, and the handshake events between do not leave it
    (should (eq (rata-agent-center--next-state 'ready (funcall ev 'init-started) nil)
                'starting))
    (dolist (e '(init-client init-handshake init-session session-selected init-finished))
      (should (eq (rata-agent-center--next-state 'starting (funcall ev e) nil) 'starting)))
    ;; ready: prompt shown, or a `done' shell visited
    (should (eq (rata-agent-center--next-state 'starting (funcall ev 'prompt-ready) nil)
                'ready))
    (should (eq (rata-agent-center--next-state 'done (funcall ev 'visited) t) 'ready))
    ;; Visiting only clears `done'; it never hides a question or an error.
    (dolist (s '(needs-input error working))
      (should (eq (rata-agent-center--next-state s (funcall ev 'visited) t) s)))
    ;; A tool call updating while a permission question is open does not hide it:
    ;; only the answer does.
    (should (eq (rata-agent-center--next-state 'needs-input (funcall ev 'tool-call-update) nil)
                'needs-input))
    ;; Streamed chunks and unknown events change nothing.
    (dolist (e '(agent-message-chunk idle session-title-changed file-write no-such-event))
      (should (eq (rata-agent-center--next-state 'done (funcall ev e) nil) 'done)))))

(ert-deftest rata-test-agent-center-last-column-shows-only-the-unusual ()
  "The Last column carries an error or an unusual stop reason, nothing else.
`end_turn' and the cost were dropped to save panel width (2026-10-02)."
  (should (equal (rata-agent-center--last
                  '(:last-stop-reason "end_turn" :cost 0.12)) ""))
  (should (equal (rata-agent-center--last '()) ""))
  (should (equal (rata-agent-center--last
                  '(:last-stop-reason "max_tokens" :cost 0.12)) "max_tokens"))
  (should (equal (rata-agent-center--last
                  '(:last-stop-reason "end_turn" :error "request failed"))
                 "request failed")))

(ert-deftest rata-test-agent-center-state-order ()
  "Sort order is the plan's: attention first, idle last."
  (should (equal rata-agent-center-states
                 '(needs-input error done working starting ready)))
  (should (< (rata-agent-center--state-rank 'needs-input)
             (rata-agent-center--state-rank 'error)
             (rata-agent-center--state-rank 'done)
             (rata-agent-center--state-rank 'working)
             (rata-agent-center--state-rank 'starting)
             (rata-agent-center--state-rank 'ready)))
  ;; An unknown state sorts after every known one rather than signalling.
  (should (> (rata-agent-center--state-rank 'bogus)
             (rata-agent-center--state-rank 'ready))))

(ert-deftest rata-test-agent-center-reconcile-trusts-status ()
  "`agent-shell-status' overrides a recorded state events cannot explain."
  (should (eq (rata-agent-center--reconcile 'working 'blocked nil) 'needs-input))
  (should (eq (rata-agent-center--reconcile 'ready 'busy nil) 'working))
  (should (eq (rata-agent-center--reconcile 'done 'busy nil) 'working))
  ;; Recorded busy, status idle, no `turn-complete' seen: the turn ended unseen.
  (should (eq (rata-agent-center--reconcile 'working 'ready nil) 'done))
  (should (eq (rata-agent-center--reconcile 'working 'ready t) 'ready))
  (should (eq (rata-agent-center--reconcile 'needs-input 'ready nil) 'done))
  ;; Agreement, and the states status cannot see, are left alone.
  (dolist (s '(done ready error starting))
    (should (eq (rata-agent-center--reconcile s 'ready nil) s)))
  (should (eq (rata-agent-center--reconcile 'working 'busy nil) 'working))
  (should (eq (rata-agent-center--reconcile 'needs-input 'blocked nil) 'needs-input))
  ;; No status (shell gone, agent-shell unloaded): keep what we have.
  (should (eq (rata-agent-center--reconcile 'working nil nil) 'working)))

(ert-deftest rata-test-agent-center-registry-follows-events ()
  "A registered shell's entry tracks state, title, stop reason and cost."
  (rata-test-agent-center--with-registry
    (with-temp-buffer
      (let* ((buf (current-buffer))
             (ev #'rata-test-agent-center--ev)
             (handler (progn (rata-agent-center--add-entry
                              buf :layout "work" :project "~/src/x/" :agent "Claude")
                             (rata-agent-center--make-handler buf)))
             (get (lambda (k) (plist-get (rata-agent-center--entry buf) k))))
        (should (eq (funcall get :state) 'starting))
        (should (equal (funcall get :layout) "work"))
        (should (equal (funcall get :agent) "Claude"))
        (funcall handler (funcall ev 'prompt-ready))
        (should (eq (funcall get :state) 'ready))
        (funcall handler (funcall ev 'input-submitted :prompt "hi"))
        (should (eq (funcall get :state) 'working))
        (let ((since (funcall get :since)))
          ;; Same state again: the clock does not restart.
          (funcall handler (funcall ev 'tool-call-update :tool-call-id "t1"))
          (should (eq (funcall get :since) since)))
        (funcall handler (funcall ev 'permission-request :request-id 1))
        (should (eq (funcall get :state) 'needs-input))
        (funcall handler (funcall ev 'permission-response :request-id 1))
        (should (eq (funcall get :state) 'working))
        (funcall handler (funcall ev 'session-title-changed :title "Fix the parser"))
        (should (equal (funcall get :title) "Fix the parser"))
        (funcall handler (funcall ev 'turn-complete
                                  :stop-reason "end_turn"
                                  :usage '((:cost-amount . 0.12) (:cost-currency . "USD"))))
        (should (eq (funcall get :state) 'done))
        (should (equal (funcall get :last-stop-reason) "end_turn"))
        (should (equal (funcall get :cost) 0.12))
        (funcall handler (funcall ev 'error :code -1 :message "overloaded"))
        (should (eq (funcall get :state) 'error))
        (should (equal (funcall get :error) "overloaded"))
        ;; Every event that changed something asked for a render; none rendered.
        (should (> renders 0))
        (funcall handler (funcall ev 'clean-up))
        (should-not (rata-agent-center--entry buf))))))

(ert-deftest rata-test-agent-center-turn-complete-while-visible-is-ready ()
  "A turn that finishes in front of you is not `done' (nothing unread)."
  (rata-test-agent-center--with-registry
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (rata-agent-center--add-entry buf :state 'working)
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (funcall (rata-agent-center--make-handler buf)
                   (rata-test-agent-center--ev 'turn-complete)))
        (should (eq (plist-get (rata-agent-center--entry buf) :state) 'ready))))))

(ert-deftest rata-test-agent-center-erroring-callback-shows-error ()
  "A bug in the handler lands on the entry as `error', not in *Messages*.
agent-shell demotes a subscriber's error to a `message', which would hide it."
  (rata-test-agent-center--with-registry
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (rata-agent-center--add-entry buf :state 'working)
        (cl-letf (((symbol-function 'rata-agent-center--next-state)
                   (lambda (&rest _) (error "Boom in next-state"))))
          ;; Must not signal: the handler contains its own failure.
          (funcall (rata-agent-center--make-handler buf)
                   (rata-test-agent-center--ev 'input-submitted)))
        (let ((entry (rata-agent-center--entry buf)))
          (should (eq (plist-get entry :state) 'error))
          (should (string-match-p "Boom in next-state" (plist-get entry :error))))))))

(ert-deftest rata-test-agent-center-layout-capture ()
  "The layout is the current persp at start, else the persp holding the buffer."
  (should (featurep 'persp-mode))
  (let ((name "rata-test-agent-center"))
    (unwind-protect
        (with-temp-buffer
          (let ((buf (current-buffer)))
            ;; Opened now: the current layout, whatever holds the buffer.
            (should (equal (rata-agent-center--layout-for buf 'current)
                           (safe-persp-name (get-current-persp))))
            ;; Adopted later: the layout the buffer was added to wins.
            (persp-add-new name)
            (persp-add-buffer buf (persp-get-by-name name) nil nil)
            (should (equal (rata-agent-center--layout-for buf 'adopted) name))))
      (persp-remove-by-name name))))

(ert-deftest rata-test-agent-center-adopt-and-disable ()
  "Existing shells are adopted once; disable unsubscribes every token."
  (rata-test-agent-center--with-registry
    (let ((a (generate-new-buffer " *rata-test-shell-a*"))
          (b (generate-new-buffer " *rata-test-shell-b*"))
          (subscribed nil) (unsubscribed nil) (token 0))
      (unwind-protect
          (progn
            (dolist (buf (list a b))
              ;; Enough of a shell for the guard, without running the mode.
              (with-current-buffer buf (setq-local major-mode 'agent-shell-mode)))
            (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () (list a b)))
                      ;; Adoption waits for the feature, not an autoload stub.
                      ((symbol-function 'rata-agent-center--agent-shell-loaded-p)
                       (lambda () t))
                      ((symbol-function 'agent-shell-status) (lambda (&rest _) 'ready))
                      ((symbol-function 'agent-shell-subscribe-to)
                       (lambda (&rest args)
                         (push (plist-get args :shell-buffer) subscribed)
                         (cl-incf token)))
                      ((symbol-function 'agent-shell-unsubscribe)
                       (lambda (&rest args)
                         (push (plist-get args :subscription) unsubscribed))))
              (rata-agent-center--adopt)
              (rata-agent-center--adopt)   ; idempotent: no second subscription
              (should (= (length subscribed) 2))
              (should (rata-agent-center--entry a))
              (should (rata-agent-center--entry b))
              (should (plist-get (rata-agent-center--entry a) :token))
              (rata-agent-center-disable)
              (should (equal (sort unsubscribed #'<) '(1 2)))
              (should (= (hash-table-count rata-agent-center--registry) 0))
              (should-not (memq #'rata-agent-center--on-mode-hook agent-shell-mode-hook))))
        (kill-buffer a)
        (kill-buffer b)
        ;; Leave the real hook as init left it.
        (rata-agent-center-enable)))))

(ert-deftest rata-test-agent-center-sweep-drops-dead-buffers ()
  "Entries whose buffer died without a `clean-up' are dropped at sweep."
  (rata-test-agent-center--with-registry
    (let ((buf (generate-new-buffer " *rata-test-dead-shell*")))
      (rata-agent-center--add-entry buf)
      (kill-buffer buf)
      (rata-agent-center--sweep)
      (should (= (hash-table-count rata-agent-center--registry) 0)))))

;;; --- init-agent-center: the *Agents* panel (phase 2) ---

(defun rata-test-agent-center--panel-windows ()
  "Every window in the selected frame showing *Agents*, as (SIDE . WIDTH)."
  (let ((buf (get-buffer rata-agent-center-buffer-name)))
    (mapcar (lambda (w) (cons (window-parameter w 'window-side) (window-total-width w)))
            (seq-filter (lambda (w) (and buf (eq (window-buffer w) buf)))
                        (window-list nil 'nomini)))))

(ert-deftest rata-test-agent-center-panel-survives-layout-switch ()
  "Exactly one *Agents* side window after every layout switch while pinned,
and none after closing -- in either layout.
persp-mode saves each layout's window configuration, side windows included,
and restores it on switch (probed 2026-09-30, L-053): left alone, the panel
vanishes in a layout it was never opened in and comes back in one it was
closed in."
  (should (bound-and-true-p persp-mode))
  (let ((orig (safe-persp-name (get-current-persp)))
        (rata-agent-center-side 'right)
        (rata-agent-center-width 45))
    (unwind-protect
        (progn
          (persp-add-new "rata-ac-a")
          (persp-add-new "rata-ac-b")
          (persp-switch "rata-ac-a")
          (rata-agent-center-toggle)
          (should (equal (rata-test-agent-center--panel-windows) '((right . 45))))
          (dolist (layout '("rata-ac-b" "rata-ac-a" "rata-ac-b" "rata-ac-a"))
            (persp-switch layout)
            (should (equal (safe-persp-name (get-current-persp)) layout))
            (should (equal (rata-test-agent-center--panel-windows) '((right . 45)))))
          ;; A side window survives `delete-other-windows' (SPC w m).
          (delete-other-windows (get-mru-window nil nil t))
          (should (equal (rata-test-agent-center--panel-windows) '((right . 45))))
          ;; Closed: unpinned, and no layout's saved configuration brings it back.
          (rata-agent-center-close)
          (should-not (rata-test-agent-center--panel-windows))
          (dolist (layout '("rata-ac-b" "rata-ac-a" "rata-ac-b"))
            (persp-switch layout)
            (should-not (rata-test-agent-center--panel-windows))))
      (rata-agent-center-close)
      (persp-switch orig)
      (persp-remove-by-name "rata-ac-a")
      (persp-remove-by-name "rata-ac-b"))))

(ert-deftest rata-test-agent-center-panel-kept-out-of-saved-layouts ()
  "*Agents* is never written into a persp state file."
  (let ((buf (get-buffer-create rata-agent-center-buffer-name)))
    (should (persp-buffer-filtered-out-p buf persp-filter-save-buffers-functions))
    (should (memq #'rata-agent-center--persp-save-filter
                  persp-filter-save-buffers-functions))))

(ert-deftest rata-test-agent-center-age-strings ()
  "Time in state is one short unit, like `3m'."
  (should (equal (rata-agent-center--age 0) "0s"))
  (should (equal (rata-agent-center--age 59) "59s"))
  (should (equal (rata-agent-center--age 185) "3m"))
  (should (equal (rata-agent-center--age 3700) "1h"))
  (should (equal (rata-agent-center--age 90000) "1d")))

(ert-deftest rata-test-agent-center-long-title-is-truncated ()
  "A long session title is cut to its column, so the row stays one line wide."
  (with-temp-buffer
    (let* ((cols (append (rata-agent-center--row
                          (list :buffer (current-buffer) :state 'ready :agent "Claude"
                                :title "Refactor the jira sprint grouping" :since 0)
                          0)
                         nil))
           (title (aref (cadr cols) 2)))
      (should (<= (string-width title) rata-agent-center--title-width))
      (should (string-suffix-p "…" title)))))

(ert-deftest rata-test-agent-center-render-groups-and-order ()
  "A fixture registry renders grouped by layout, most urgent group and row first."
  (rata-test-agent-center--with-registry
    (let* ((mk (lambda (name) (generate-new-buffer (format " *rata-ac-%s*" name))))
           (w1 (funcall mk "w1")) (w2 (funcall mk "w2"))
           (h1 (funcall mk "h1")) (z1 (funcall mk "z1"))
           (panel nil))
      (unwind-protect
          (progn
            (rata-agent-center--add-entry w1 :layout "work" :project "~/src/x/"
                                          :agent "Claude" :title "Tidy" :state 'ready)
            (rata-agent-center--add-entry w2 :layout "work" :project "~/src/x/"
                                          :agent "Pi" :title "Fix parser" :state 'needs-input)
            (rata-agent-center--add-entry h1 :layout "home" :project "~/blog/"
                                          :agent "Claude" :title "Post" :state 'done)
            (rata-agent-center--add-entry z1 :layout "zeta" :project "~/z/"
                                          :agent "Claude" :title nil :state 'error)
            (rata-agent-center--put h1 :last-stop-reason "end_turn" :cost 0.12)
            (setq panel (rata-agent-center--refresh-buffer))
            (with-current-buffer panel
              (should (derived-mode-p 'rata-agent-center-mode))
              (let ((lines (split-string (buffer-substring-no-properties
                                          (point-min) (point-max))
                                         "\n" t)))
                (should (= (length lines) 7))
                ;; Groups by their most urgent row: needs-input, error, done.
                (should (string-match-p "\\`work — ~/src/x/" (nth 0 lines)))
                (should (string-match-p "input .*Pi .*Fix parser" (nth 1 lines)))
                (should (string-match-p "ready .*Claude .*Tidy" (nth 2 lines)))
                (should (string-match-p "\\`zeta — ~/z/" (nth 3 lines)))
                (should (string-match-p "error .*Claude" (nth 4 lines)))
                (should (string-match-p "\\`home — ~/blog/" (nth 5 lines)))
                (should (string-match-p "done .*Claude .*Post" (nth 6 lines)))
                ;; A normal end and the cost are left out to save width.
                (should-not (string-match-p "end_turn\\|\\$" (nth 6 lines))))
              ;; A row's id is its shell buffer: that is what RET acts on.
              (goto-char (point-min))
              (forward-line 1)
              (should (eq (tabulated-list-get-id) w2))
              ;; The badge carries the state's face.
              (should (search-forward "input" (line-end-position) t))
              (should (eq (get-text-property (match-beginning 0) 'face)
                          'rata-agent-center-needs-input))))
        (mapc #'kill-buffer (list w1 w2 h1 z1))
        (when (buffer-live-p panel) (kill-buffer panel))))))

(ert-deftest rata-test-agent-center-render-is-debounced-and-gated ()
  "Events arm one timer; a render with the panel hidden prints nothing."
  (let ((rata-agent-center--registry (make-hash-table :test #'eq))
        (rata-agent-center--render-timer nil))
    (when (get-buffer rata-agent-center-buffer-name)
      (kill-buffer rata-agent-center-buffer-name))
    (unwind-protect
        (progn
          (rata-agent-center--schedule-render)
          (let ((timer rata-agent-center--render-timer))
            (should (timerp timer))
            (rata-agent-center--schedule-render)
            (should (eq rata-agent-center--render-timer timer)))
          (rata-agent-center--render)
          (should-not rata-agent-center--render-timer)
          (should-not (get-buffer rata-agent-center-buffer-name)))
      (when (timerp rata-agent-center--render-timer)
        (cancel-timer rata-agent-center--render-timer)))))

(ert-deftest rata-test-agent-center-panel-keys ()
  "RET, o, q and g r are live in normal state in the panel."
  (let ((buf (get-buffer-create "*rata-test-agents*")))
    (unwind-protect
        (with-current-buffer buf
          (rata-agent-center-mode)
          (should (eq evil-state 'normal))
          (should (eq (key-binding (kbd "RET")) 'rata-agent-center-visit))
          (should (eq (key-binding (kbd "o")) 'rata-agent-center-show))
          (should (eq (key-binding (kbd "q")) 'rata-agent-center-close))
          (should (eq (key-binding (kbd "g r")) 'rata-agent-center-refresh))
          ;; Evil motion still works: this is a list, not an emacs-state buffer.
          (should (eq (key-binding (kbd "j")) 'evil-next-line)))
      (kill-buffer buf))))

(ert-deftest rata-test-agent-center-no-shackle-rule ()
  "shackle must not place *Agents*: it is a side window, and a rule would fight it."
  (should-not (seq-find (lambda (rule)
                          (and (stringp (car rule))
                               (string-match-p (regexp-quote (car rule))
                                               rata-agent-center-buffer-name)))
                        shackle-rules)))

;;; --- init-agent-center: navigation and actions (phase 3) ---

(defmacro rata-test-agent-center--with-fixture (bindings &rest body)
  "Run BODY with a private registry holding live buffers from BINDINGS.
Each binding is (VAR LAYOUT STATE SINCE); the buffers are killed after."
  (declare (indent 1))
  `(rata-test-agent-center--with-registry
     (let ,(mapcar (lambda (b) `(,(car b) (generate-new-buffer
                                            ,(format " *rata-ac-%s*" (car b)))))
                   bindings)
       (unwind-protect
           (progn
             ,@(mapcar (lambda (b)
                         `(progn
                            (rata-agent-center--add-entry
                             ,(car b) :layout ,(nth 1 b) :project "~/src/x/"
                             :agent "Claude" :title ,(symbol-name (car b))
                             :state ',(nth 2 b))
                            (rata-agent-center--put ,(car b) :since ,(nth 3 b))))
                       bindings)
             ,@body)
         (mapc (lambda (buf) (when (buffer-live-p buf) (kill-buffer buf)))
               (list ,@(mapcar #'car bindings)))))))

(ert-deftest rata-test-agent-center-most-urgent-picks-right-buffer ()
  "Next attention: most urgent state first, longest waiting within a state."
  (rata-test-agent-center--with-fixture ((a "l" ready 1) (b "l" working 2)
                                         (c "l" done 100) (d "l" needs-input 300)
                                         (e "l" error 50) (f "l" needs-input 200))
    (should (eq (plist-get (rata-agent-center--most-urgent) :buffer) f))
    (rata-agent-center--put f :state 'ready)
    (rata-agent-center--put d :state 'ready)
    (should (eq (plist-get (rata-agent-center--most-urgent) :buffer) e))
    (rata-agent-center--put e :state 'working)
    (should (eq (plist-get (rata-agent-center--most-urgent) :buffer) c))
    (rata-agent-center--put c :state 'ready)
    ;; `working' and `ready' never need you.
    (should-not (rata-agent-center--most-urgent))))

(ert-deftest rata-test-agent-center-next-attention-shows-the-shell ()
  "`SPC a i n' puts the most urgent shell in front of you; `done' becomes seen."
  (let ((here (rata-agent-center--current-layout)))
    (rata-test-agent-center--with-fixture ((c here done 100) (r here ready 1))
      (save-window-excursion
        (rata-agent-center-next-attention)
        (should (eq (window-buffer (selected-window)) c))
        (should (eq (plist-get (rata-agent-center--entry c) :state) 'ready))
        (should-error (rata-agent-center-next-attention) :type 'user-error)))))

(ert-deftest rata-test-agent-center-visiting-clears-done ()
  "A `done' shell becomes `ready' once it is the selected window's buffer."
  (should (memq #'rata-agent-center--on-window-change
                (default-value 'window-selection-change-functions)))
  (should (memq #'rata-agent-center--on-window-change
                (default-value 'window-buffer-change-functions)))
  (rata-test-agent-center--with-fixture ((seen "l" done 1) (unseen "l" done 1)
                                         (asking "l" needs-input 1))
    (save-window-excursion
      (set-window-buffer (selected-window) seen)
      (rata-agent-center--on-window-change (selected-frame))
      (should (eq (plist-get (rata-agent-center--entry seen) :state) 'ready))
      (should (eq (plist-get (rata-agent-center--entry unseen) :state) 'done))
      ;; A question is not answered by looking at it.
      (set-window-buffer (selected-window) asking)
      (rata-agent-center--on-window-change (selected-frame))
      (should (eq (plist-get (rata-agent-center--entry asking) :state) 'needs-input)))))

(ert-deftest rata-test-agent-center-attention-row-motion ()
  "]] and [[ move between rows that need you, skipping headings and idle rows."
  (rata-test-agent-center--with-fixture ((w1 "work" needs-input 1) (w2 "work" ready 1)
                                         (h1 "home" done 1) (h2 "home" working 1))
    (let ((panel (rata-agent-center--refresh-buffer)))
      (unwind-protect
          (with-current-buffer panel
            (goto-char (point-min))
            (rata-agent-center-next-attention-row)
            (should (eq (tabulated-list-get-id) w1))
            (rata-agent-center-next-attention-row)
            (should (eq (tabulated-list-get-id) h1))
            ;; None further: point stays put.
            (rata-agent-center-next-attention-row)
            (should (eq (tabulated-list-get-id) h1))
            (rata-agent-center-previous-attention-row)
            (should (eq (tabulated-list-get-id) w1)))
        (kill-buffer panel)))))

(ert-deftest rata-test-agent-center-fold-survives-rerender ()
  "Folding a layout hides its rows, and stays folded across re-renders."
  (let ((rata-agent-center--folded nil))
    (rata-test-agent-center--with-fixture ((w1 "work" ready 1) (w2 "work" done 1)
                                           (h1 "home" working 1))
      (let ((panel (rata-agent-center--refresh-buffer))
            (lines (lambda () (split-string (buffer-substring-no-properties
                                             (point-min) (point-max))
                                            "\n" t))))
        (unwind-protect
            (with-current-buffer panel
              (should (= (length (funcall lines)) 5))
              ;; From a row, the fold applies to the row's group.
              (goto-char (point-min))
              (forward-line 1)
              (should (eq (tabulated-list-get-id) w2))
              (rata-agent-center-toggle-group)
              (should (equal rata-agent-center--folded '("work")))
              (should (= (length (funcall lines)) 3))
              (should (string-match-p "\\`work — .*2 hidden" (car (funcall lines))))
              ;; Point is left on the folded heading.
              (should (= (line-number-at-pos) 1))
              (rata-agent-center--refresh-buffer)
              (should (= (length (funcall lines)) 3))
              ;; From the heading, it unfolds.
              (rata-agent-center-toggle-group)
              (should-not rata-agent-center--folded)
              (should (= (length (funcall lines)) 5)))
          (kill-buffer panel))))))

(ert-deftest rata-test-agent-center-interrupt-and-new-shell ()
  "K interrupts the row's shell after asking; c starts a shell in the row's project."
  (let ((dir (file-name-as-directory (make-temp-file "rata-ac-proj" t)))
        (interrupted nil) (started nil))
    (unwind-protect
        (rata-test-agent-center--with-fixture ((s (rata-agent-center--current-layout)
                                                  working 1))
          (rata-agent-center--put s :project (abbreviate-file-name dir))
          (let ((panel (rata-agent-center--refresh-buffer)))
            (unwind-protect
                (with-current-buffer panel
                  (goto-char (point-min))
                  (forward-line 1)
                  (should (eq (tabulated-list-get-id) s))
                  (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                            ((symbol-function 'agent-shell-interrupt)
                             (lambda (&optional force)
                               (setq interrupted (list (current-buffer) force))))
                            ((symbol-function 'agent-shell-new-shell)
                             (lambda () (interactive)
                               (setq started (expand-file-name default-directory)))))
                    (rata-agent-center-interrupt)
                    (should (equal interrupted (list s t)))
                    (save-window-excursion
                      (rata-agent-center-new-shell))
                    (should (equal started dir))))
              (kill-buffer panel))))
      (delete-directory dir t))))

(ert-deftest rata-test-agent-center-phase3-keys ()
  "]] [[ TAB za c K are live in normal state in the panel."
  (let ((buf (get-buffer-create "*rata-test-agents-3*")))
    (unwind-protect
        (with-current-buffer buf
          (rata-agent-center-mode)
          (should (eq (key-binding (kbd "]]")) 'rata-agent-center-next-attention-row))
          (should (eq (key-binding (kbd "[[")) 'rata-agent-center-previous-attention-row))
          (should (eq (key-binding (kbd "TAB")) 'rata-agent-center-toggle-group))
          (should (eq (key-binding (kbd "za")) 'rata-agent-center-toggle-group))
          (should (eq (key-binding (kbd "c")) 'rata-agent-center-new-shell))
          (should (eq (key-binding (kbd "K")) 'rata-agent-center-interrupt)))
      (kill-buffer buf))))

;;; --- init-agent-center: mode-line segment (phase 4) ---

(ert-deftest rata-test-agent-center-mode-line-text ()
  "The segment counts what needs you and what is busy; empty when nothing is."
  (should (equal (rata-agent-center--mode-line-text nil) ""))
  (should (equal (rata-agent-center--mode-line-text '((ready . 3) (starting . 1))) ""))
  (should (equal (substring-no-properties
                  (rata-agent-center--mode-line-text
                   '((working . 3) (done . 1) (needs-input . 2) (ready . 4))))
                 "⚠2 ✓1 ●3"))
  (should (equal (substring-no-properties
                  (rata-agent-center--mode-line-text '((error . 1) (working . 1))))
                 "✗1 ●1"))
  ;; Each count wears its state's face, and a click opens the panel.
  (let ((text (rata-agent-center--mode-line-text '((needs-input . 2)))))
    (should (eq (get-text-property 0 'face text) 'rata-agent-center-needs-input))
    (should (eq (lookup-key (get-text-property 0 'local-map text) [mode-line mouse-1])
                'rata-agent-center-toggle))))

(ert-deftest rata-test-agent-center-mode-line-counts-registry ()
  "The segment reads the registry, and is on `global-mode-string'."
  (should (member 'rata-agent-center-mode-line global-mode-string))
  (should (get 'rata-agent-center-mode-line 'risky-local-variable))
  (rata-test-agent-center--with-fixture ((a "l" needs-input 1) (b "l" working 1)
                                         (c "l" working 1) (d "l" ready 1))
    (should (equal (rata-agent-center--counts)
                   '((needs-input . 1) (working . 2) (ready . 1))))
    ;; Through the construct's own function: batch `format-mode-line' never
    ;; evaluates `:eval' (probed on 31.1, L-054), so it would print "" regardless.
    (should (equal rata-agent-center-mode-line '(:eval (rata-agent-center--mode-line-segment))))
    (should (equal (substring-no-properties (rata-agent-center--mode-line-segment))
                   " ⚠1 ●2")))
  (rata-test-agent-center--with-registry
    (should (equal (rata-agent-center--mode-line-segment) ""))))

(ert-deftest rata-test-agent-center-hooked-at-startup ()
  "The module is loaded by init and listens for new shells."
  (should (featurep 'init-agent-center))
  (should (memq #'rata-agent-center--on-mode-hook agent-shell-mode-hook)))

;;; --- init-agent-center: activity line (A2, plans/ai-agent-powerhouse.md) ---

(ert-deftest rata-test-agent-center-tool-activity-strings ()
  "A tool call reads as `Label: detail', from its title, command and kind."
  ;; Claude's ACP adapter titles a Bash call with the command in backticks.
  (should (equal (rata-agent-center--tool-activity
                  '((:kind . "execute") (:title . "`just test`") (:command . "just test")))
                 "Bash: just test"))
  (should (equal (rata-agent-center--tool-activity
                  '((:kind . "edit") (:title . "Edit `/s/x/lisp/init-org.el`")))
                 "Edit: /s/x/lisp/init-org.el"))
  ;; The verb in the title wins over the kind: a Write is kind `edit'.
  (should (equal (rata-agent-center--tool-activity
                  '((:kind . "edit") (:title . "Write /s/x/new.el")))
                 "Write: /s/x/new.el"))
  ;; A title that does not start with a verb gets the kind as its label.
  (should (equal (rata-agent-center--tool-activity
                  '((:kind . "search") (:title . "grep \"defun\" lisp")))
                 "Search: grep \"defun\" lisp"))
  (should-not (rata-agent-center--tool-activity nil))
  (should-not (rata-agent-center--tool-activity '((:kind . "read")))))

(ert-deftest rata-test-agent-center-activity-follows-events ()
  "Tool calls set the activity; message chunks only while no tool is in flight."
  (rata-test-agent-center--with-registry
    (with-temp-buffer
      (let* ((buf (current-buffer))
             (ev #'rata-test-agent-center--ev)
             (handler (progn (rata-agent-center--add-entry buf :state 'ready)
                             (rata-agent-center--make-handler buf)))
             (activity (lambda () (plist-get (rata-agent-center--entry buf) :activity)))
             (tool (lambda (id status)
                     (funcall ev 'tool-call-update :tool-call-id id
                              :tool-call `((:kind . "execute") (:title . "`just test`")
                                           (:command . "just test") (:status . ,status))))))
        (funcall handler (funcall ev 'input-submitted :prompt "fix it"))
        (should-not (funcall activity))
        (funcall handler (funcall ev 'agent-message-chunk :text-chunk "I'll look"))
        (funcall handler (funcall ev 'agent-message-chunk :text-chunk " at the parser.\nThen"))
        (should (equal (funcall activity) "I'll look at the parser.\nThen"))
        (funcall handler (funcall tool "t1" "in_progress"))
        (should (equal (funcall activity) "Bash: just test"))
        ;; While the tool runs, its line is not overwritten by chatter.
        (funcall handler (funcall ev 'agent-message-chunk :text-chunk "Running tests"))
        (should (equal (funcall activity) "Bash: just test"))
        ;; Finished, it stays until something newer arrives...
        (funcall handler (funcall tool "t1" "completed"))
        (should (equal (funcall activity) "Bash: just test"))
        ;; ...and the next message starts afresh rather than appending.
        (funcall handler (funcall ev 'agent-message-chunk :text-chunk "Tests pass."))
        (should (equal (funcall activity) "Tests pass."))
        ;; A non-text chunk (an image) changes nothing.
        (funcall handler (funcall ev 'agent-message-chunk :text-chunk nil))
        (should (equal (funcall activity) "Tests pass."))
        ;; A long stream is capped, not kept whole.
        (dotimes (_ 100)
          (funcall handler (funcall ev 'agent-message-chunk :text-chunk "0123456789")))
        (should (<= (length (funcall activity)) rata-agent-center--activity-max))
        ;; A new prompt clears what the last turn was doing.
        (funcall handler (funcall ev 'input-submitted :prompt "next"))
        (should-not (funcall activity))))))

(ert-deftest rata-test-agent-center-activity-line-format ()
  "The line is the first non-blank line, squeezed, project-relative and cut to width."
  (let ((line (lambda (state activity &optional width project)
                (rata-agent-center--activity-line
                 (list :state state :activity activity :project project)
                 (or width 60)))))
    (should (equal (funcall line 'working "\n  First   line \nsecond") "First line"))
    (should (equal (funcall line 'needs-input "Bash: rm -r build") "Bash: rm -r build"))
    ;; Unread output is worth a line; so is a failure.
    (should (equal (funcall line 'done "All done.") "All done."))
    (should (equal (funcall line 'error "Bash: just test") "Bash: just test"))
    ;; Paths under the shell's project lose the project prefix.
    (should (equal (funcall line 'working
                            (concat "Edit: " (expand-file-name "~/src/x/") "lisp/init-org.el")
                            60 "~/src/x/")
                   "Edit: lisp/init-org.el"))
    (let ((cut (funcall line 'working "Bash: just test-everything-forever" 12)))
      (should (<= (string-width cut) 12))
      (should (string-suffix-p "…" cut)))
    ;; Nothing to say: seen and idle, no activity, or only whitespace.
    (should-not (funcall line 'ready "Tests pass."))
    (should-not (funcall line 'working nil))
    (should-not (funcall line 'working " \n\t "))
    (should-not (funcall line 'working "text" 2))))

(ert-deftest rata-test-agent-center-activity-render-throttled ()
  "A burst of 50 chunks arms one render per interval; a state change is not held back."
  (let ((rata-agent-center--registry (make-hash-table :test #'eq))
        (rata-agent-center--render-timer nil)
        (rata-agent-center--render-due nil)
        (rata-agent-center--last-render (float-time))
        (rata-agent-center-activity-interval 1.0)
        (rata-agent-center-show-activity t)
        (delays nil))
    (with-temp-buffer
      (let* ((buf (current-buffer))
             (handler (progn (rata-agent-center--add-entry buf :state 'working)
                             (rata-agent-center--make-handler buf)))
             (chunks (lambda ()
                       (dotimes (i 50)
                         (funcall handler (rata-test-agent-center--ev
                                           'agent-message-chunk
                                           :text-chunk (format "c%d " i)))))))
        (cl-letf (((symbol-function 'rata-agent-center--panel-windows) (lambda (&rest _) '(t)))
                  ((symbol-function 'run-with-timer)
                   (lambda (delay &rest _) (push delay delays) (timer-create))))
          ;; Just rendered: the burst waits out the interval, in one timer.
          (funcall chunks)
          (should (= (length delays) 1))
          (should (>= (car delays) 0.8))
          ;; A permission request in the middle is shown at the normal debounce.
          (funcall handler (rata-test-agent-center--ev 'permission-request :request-id 1))
          (should (= (length delays) 2))
          (should (< (car delays) 0.5))
          ;; The timer fired long after the last render: the next burst is prompt.
          (setq rata-agent-center--render-timer nil
                rata-agent-center--render-due nil
                rata-agent-center--last-render (- (float-time) 10)
                delays nil)
          (funcall chunks)
          (should (equal (length delays) 1))
          (should (< (car delays) 0.5))
          ;; Turned off, activity schedules nothing at all.
          (setq rata-agent-center--render-timer nil rata-agent-center--render-due nil
                delays nil rata-agent-center-show-activity nil)
          (funcall chunks)
          (should-not delays))))))

(ert-deftest rata-test-agent-center-render-activity-line ()
  "The activity prints dim under its row, belongs to that row, and ]] skips it."
  (let ((rata-agent-center-show-activity t))
    (rata-test-agent-center--with-fixture ((w1 "work" needs-input 1) (w2 "work" ready 2)
                                           (h1 "home" working 1) (h2 "home" done 2))
      (rata-agent-center--put w1 :activity "Bash: rm -r build")
      (rata-agent-center--put w2 :activity "Seen already.")
      (rata-agent-center--put h1 :activity "Edit: lisp/init-org.el")
      (let ((panel (rata-agent-center--refresh-buffer))
            (lines (lambda () (split-string (buffer-substring-no-properties
                                             (point-min) (point-max))
                                            "\n" t))))
        (unwind-protect
            (with-current-buffer panel
              (let ((ls (funcall lines)))
                (should (= (length ls) 8))
                (should (string-match-p "input .*w1" (nth 1 ls)))
                (should (string-match-p "\\`  +↳ Bash: rm -r build\\'" (nth 2 ls)))
                ;; `ready' has nothing to report, whatever it last did.
                (should (string-match-p "ready .*w2" (nth 3 ls)))
                ;; Within a group `done' sorts before `working'.
                (should (string-match-p "done .*h2" (nth 5 ls)))
                (should (string-match-p "work .*h1" (nth 6 ls)))
                (should (string-match-p "↳ Edit: lisp/init-org.el" (nth 7 ls))))
              ;; The activity line is part of its row: RET, o and K act on it.
              (goto-char (point-min))
              (forward-line 2)
              (should (eq (tabulated-list-get-id) w1))
              (should (eq (get-text-property (+ (point) 5) 'face)
                          'rata-agent-center-activity))
              ;; ]] goes row to row, never onto a row's own activity line.
              (goto-char (point-min))
              (rata-agent-center-next-attention-row)
              (should (= (line-number-at-pos) 2))
              (rata-agent-center-next-attention-row)
              (should (eq (tabulated-list-get-id) h2))
              (rata-agent-center-previous-attention-row)
              (should (= (line-number-at-pos) 2))
              ;; Switched off, the rows are single lines again.
              (let ((rata-agent-center-show-activity nil))
                (rata-agent-center--refresh-buffer)
                (should (= (length (funcall lines)) 6))))
          (kill-buffer panel))))))

;;; --- init-agent-worktree: one worktree per task (B6, plans/ai-agent-powerhouse.md) ---
;; Every git call runs against a throwaway repository under `temporary-file-directory'
;; with the user's git config shut out; nothing starts an agent.

(ert-deftest rata-test-agent-worktree-branch-name ()
  "A task name becomes `agent/<slug>': lower case, dashes, bounded, Jira keys kept."
  (should (equal (rata-agent-worktree-branch-name "Fix Jira sprint grouping!")
                 "agent/fix-jira-sprint-grouping"))
  (should (equal (rata-agent-worktree-branch-name "  ABC-123: Fix the  parser ")
                 "agent/abc-123-fix-the-parser"))
  (should (equal (rata-agent-worktree-branch-name "fix_the/parser..again")
                 "agent/fix-the-parser-again"))
  ;; Bounded, and never ends on a dash after the cut.
  (let ((name (rata-agent-worktree-branch-name (make-string 80 ?a))))
    (should (<= (length name) (+ (length "agent/") rata-agent-worktree-slug-max)))
    (should-not (string-suffix-p "-" name)))
  (let ((name (rata-agent-worktree-branch-name
               "a b c d e f g h i j k l m n o p q r s t u v w x y z a b c")))
    (should (<= (length name) (+ (length "agent/") rata-agent-worktree-slug-max)))
    (should-not (string-suffix-p "-" name)))
  (should-error (rata-agent-worktree-branch-name "!!! ") :type 'user-error))

(ert-deftest rata-test-agent-worktree-parse-list ()
  "`git worktree list --porcelain' becomes (PATH . BRANCH) pairs, main first."
  (should (equal (rata-agent-worktree--parse-list
                  (concat "worktree /src/repo\nHEAD 1111\nbranch refs/heads/dev\n\n"
                          "worktree /src/repo/.agent-shell/worktrees/fix-x\nHEAD 2222\n"
                          "branch refs/heads/agent/fix-x\n\n"
                          "worktree /src/other\nHEAD 3333\ndetached\n\n"))
                 '(("/src/repo" . "dev")
                   ("/src/repo/.agent-shell/worktrees/fix-x" . "agent/fix-x")
                   ("/src/other"))))
  (should-not (rata-agent-worktree--parse-list "")))

(ert-deftest rata-test-agent-worktree-path ()
  "A branch's worktree sits under the main checkout's .agent-shell/worktrees/."
  (should (equal (rata-agent-worktree--path "/src/repo/" "agent/fix-x")
                 "/src/repo/.agent-shell/worktrees/fix-x"))
  (should (equal (rata-agent-worktree--path "/src/repo" "other/name")
                 "/src/repo/.agent-shell/worktrees/other-name")))

(defmacro rata-test-agent-worktree--with-repo (&rest body)
  "Run BODY in a fresh git repository with one commit on `main'.
`repo' is bound to its root (a directory name).  Git sees no user or
system config, so a hook or signing setting cannot leak in.  The
repository, every worktree under it and any layout named agent/* are
removed afterwards."
  (declare (indent 0))
  `(let* ((repo (file-name-as-directory
                 (file-truename (make-temp-file "rata-wt-" t))))
          (process-environment
           (append (list "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                         "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                   process-environment))
          (orig-layout (and (bound-and-true-p persp-mode)
                            (safe-persp-name (get-current-persp))))
          (default-directory repo))
     (unwind-protect
         (progn
           (rata-test-agent-worktree--git repo "init" "-q" "-b" "main")
           (write-region "x\n" nil (expand-file-name "f.txt" repo))
           (rata-test-agent-worktree--git repo "add" "f.txt")
           (rata-test-agent-worktree--git repo "commit" "-q" "-m" "init")
           ,@body)
       (when orig-layout
         (unless (equal (safe-persp-name (get-current-persp)) orig-layout)
           (persp-switch orig-layout))
         (dolist (name (persp-names))
           (when (string-prefix-p "agent/" name) (persp-remove-by-name name))))
       (dolist (buf (buffer-list))
         (when (string-prefix-p repo (buffer-local-value 'default-directory buf))
           (let (kill-buffer-query-functions) (kill-buffer buf))))
       (delete-directory repo t))))

(defun rata-test-agent-worktree--git (dir &rest args)
  "Run git ARGS in DIR; return its trimmed output, failing the test on error."
  (with-temp-buffer
    (let ((default-directory dir))
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (ert-fail (format "git %S failed: %s" args (buffer-string))))
      (string-trim (buffer-string)))))

(defmacro rata-test-agent-worktree--answering (answers &rest body)
  "Run BODY with `y-or-n-p' answering from the list ANSWERS, in order.
Binds `questions' to the prompts asked.  An unexpected extra question fails."
  (declare (indent 1))
  `(let ((answers ,answers) (questions nil) (started nil))
     (ignore started)
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt)
                  (push prompt questions)
                  (if answers (pop answers)
                    (ert-fail (format "Unexpected question: %s" prompt)))))
               ((symbol-function 'agent-shell-new-shell)
                (lambda (&rest _) (interactive) (push default-directory started))))
       ,@body)))

(ert-deftest rata-test-agent-worktree-create ()
  "A new worktree: branch from the current branch, base recorded, layout, shell."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering nil
      (let ((wt (rata-agent-worktree-create repo "agent/fix-x")))
        (should (equal wt (concat repo ".agent-shell/worktrees/fix-x")))
        (should (file-exists-p (expand-file-name "f.txt" wt)))
        (should (equal (rata-test-agent-worktree--git wt "symbolic-ref" "--short" "HEAD")
                       "agent/fix-x"))
        (should (equal (rata-agent-worktree--base repo "agent/fix-x") "main"))
        ;; The main checkout does not see the worktree as untracked files.
        (should (equal (rata-test-agent-worktree--git repo "status" "--porcelain") ""))
        ;; The shell starts inside the worktree ...
        (should (equal started (list (file-name-as-directory wt))))
        ;; ... in a layout named after the branch, which is now current.
        (when (bound-and-true-p persp-mode)
          (should (equal (safe-persp-name (get-current-persp)) "agent/fix-x")))
        ;; The same branch twice is refused before git is asked.
        (should-error (rata-agent-worktree-create repo "agent/fix-x") :type 'user-error)))))

(ert-deftest rata-test-agent-worktree-create-refuses-detached-head ()
  "No branch to come back to means no base; refuse rather than guess."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--git repo "checkout" "-q" "--detach")
    (rata-test-agent-worktree--answering nil
      (should-error (rata-agent-worktree-create repo "agent/x") :type 'user-error)
      (should-not started))))

(ert-deftest rata-test-agent-worktree-finish-refuses-dirty-and-unmerged ()
  "Finish refuses, without asking, while there is work that removal would lose."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering nil
      (let ((wt (rata-agent-worktree-create repo "agent/fix-x")))
        ;; Untracked file.
        (write-region "y\n" nil (expand-file-name "new.txt" wt))
        (should-error (rata-agent-worktree-finish-at wt) :type 'user-error)
        ;; Committed, so clean -- but not merged into main.
        (rata-test-agent-worktree--git wt "add" "new.txt")
        (rata-test-agent-worktree--git wt "commit" "-q" "-m" "work")
        (should-error (rata-agent-worktree-finish-at wt) :type 'user-error)
        ;; An unsaved buffer on a file in the worktree also blocks it.
        (rata-test-agent-worktree--git repo "merge" "-q" "--ff-only" "agent/fix-x")
        (with-current-buffer (find-file-noselect (expand-file-name "f.txt" wt))
          (insert "unsaved")
          (should-error (rata-agent-worktree-finish-at wt) :type 'user-error)
          (set-buffer-modified-p nil))
        (should-not questions)
        (should (file-directory-p wt))))))

(ert-deftest rata-test-agent-worktree-finish-removes-merged ()
  "Clean and merged: one question, then shells, layout and worktree go; transcripts
are kept in the main checkout; the branch goes only on a second yes."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering nil
      (let* ((wt (rata-agent-worktree-create repo "agent/fix-x"))
             (shell (generate-new-buffer " *rata-wt-shell*"))
             (transcript (expand-file-name ".agent-shell/transcripts/t1.md" wt)))
        (with-current-buffer shell (setq default-directory (file-name-as-directory wt)))
        (make-directory (file-name-directory transcript) t)
        (write-region "transcript\n" nil transcript)
        (write-region "y\n" nil (expand-file-name "new.txt" wt))
        (rata-test-agent-worktree--git wt "add" "new.txt")
        (rata-test-agent-worktree--git wt "commit" "-q" "-m" "work")
        (rata-test-agent-worktree--git repo "merge" "-q" "--ff-only" "agent/fix-x")
        ;; Declining the first question changes nothing.
        (setq answers (list nil))
        (rata-agent-worktree-finish-at wt)
        (should (file-directory-p wt))
        (should (buffer-live-p shell))
        ;; Yes to removal, no to deleting the branch.
        (setq answers (list t nil) questions nil)
        (rata-agent-worktree-finish-at wt)
        (should (= (length questions) 2))
        (should-not (file-exists-p wt))
        (should-not (buffer-live-p shell))
        (should (equal (with-temp-buffer
                         (insert-file-contents
                          (expand-file-name ".agent-shell/transcripts/t1.md" repo))
                         (buffer-string))
                       "transcript\n"))
        (when (bound-and-true-p persp-mode)
          (should-not (member "agent/fix-x" (persp-names))))
        (should (equal (rata-test-agent-worktree--git repo "branch" "--list" "agent/fix-x")
                       "agent/fix-x"))))))

(ert-deftest rata-test-agent-worktree-finish-deletes-branch-on-second-yes ()
  "A second yes deletes the merged branch and its recorded base."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering (list t t)
      (let ((wt (rata-agent-worktree-create repo "agent/fix-x")))
        (rata-agent-worktree-finish-at wt)
        (should-not (file-exists-p wt))
        (should (equal (rata-test-agent-worktree--git repo "branch" "--list" "agent/fix-x")
                       ""))))))

(ert-deftest rata-test-agent-worktree-finish-only-own-worktrees ()
  "Finish refuses the main checkout and worktrees it did not create."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering nil
      (should-error (rata-agent-worktree-finish-at repo) :type 'user-error)
      (let ((other (concat repo "../" (file-name-nondirectory
                                       (directory-file-name repo)) "-other")))
        (unwind-protect
            (progn
              (rata-test-agent-worktree--git repo "worktree" "add" "-q" "-b" "mine" other)
              (should-error (rata-agent-worktree-finish-at other) :type 'user-error)
              (should (file-directory-p other)))
          (delete-directory other t)))
      (should-not questions))))

(ert-deftest rata-test-agent-worktree-panel-label ()
  "A shell in an agent worktree is labelled `repo ⎇ branch' in the panel."
  (rata-test-agent-worktree--with-repo
    (rata-test-agent-worktree--answering nil
      (let ((wt (rata-agent-worktree-create repo "agent/fix-x")))
        (should (equal (rata-agent-worktree-project-label wt)
                       (format "%s ⎇ agent/fix-x"
                               (abbreviate-file-name (directory-file-name repo)))))
        (should-not (rata-agent-worktree-project-label repo))
        (should (memq #'rata-agent-worktree-project-label
                      rata-agent-center-project-label-functions))
        ;; The heading uses the label rather than the long worktree path.
        (should (string-match-p
                 "agent/fix-x — .* ⎇ agent/fix-x"
                 (rata-agent-center--group-heading
                  "agent/fix-x"
                  (list (list :project (abbreviate-file-name (file-name-as-directory wt))
                              :project-label (rata-agent-worktree-project-label wt))))))))))

(ert-deftest rata-test-agent-worktree-panel-keys ()
  "`C' and `X' in the panel start and finish a worktree."
  (let ((buf (get-buffer-create "*rata-test-agents-wt*")))
    (unwind-protect
        (with-current-buffer buf
          (rata-agent-center-mode)
          (should (eq (key-binding (kbd "C")) 'rata-agent-worktree-new))
          (should (eq (key-binding (kbd "X")) 'rata-agent-worktree-finish)))
      (kill-buffer buf))))

;;; ============================================================
;;; Agent prompt library (C12, lisp/init-agent-prompts.el)
;;; ============================================================

(ert-deftest rata-test-agent-prompt-expand-fills-present-context ()
  "Every placeholder with a value in the context is replaced."
  (should (equal "Review @a.el in demo:\n```diff\n+x\n```"
                 (rata-agent-prompt-expand
                  "Review {{file}} in {{project}}:\n{{diff}}"
                  '((file . "@a.el") (project . "demo")
                    (diff . "```diff\n+x\n```"))))))

(ert-deftest rata-test-agent-prompt-expand-leaves-gaps-visible ()
  "A known placeholder without a value and an unknown one both stay as
written, and both are reported -- nothing is dropped silently."
  (let ((tpl "Fix {{error}} near {{region}}; see {{nonsense}}.")
        (ctx '((region . "R") (error . nil) (diff . ""))))
    (should (equal "Fix {{error}} near R; see {{nonsense}}."
                   (rata-agent-prompt-expand tpl ctx)))
    (should (equal '("error" "nonsense") (rata-agent-prompt-unfilled tpl ctx)))
    ;; An empty string counts as missing, like nil.
    (should (equal "{{diff}}" (rata-agent-prompt-expand "{{diff}}" ctx)))
    (should (equal '("diff") (rata-agent-prompt-unfilled "{{diff}} {{diff}}" ctx)))))

(ert-deftest rata-test-agent-prompt-expand-is-one-pass ()
  "Text substituted from the buffer is not scanned again: a `{{file}}'
inside your region stays literal, and `\\1' is not a back-reference."
  (should (equal "code: x = \"{{file}}\" \\1 -- @f"
                 (rata-agent-prompt-expand
                  "code: {{region}} -- {{file}}"
                  '((region . "x = \"{{file}}\" \\1") (file . "@f"))))))

(ert-deftest rata-test-agent-prompt-parse-description ()
  "A leading HTML comment is the description and is not sent."
  (should (equal '("Review the diff" . "Look at {{diff}}.")
                 (rata-agent-prompt-parse "<!-- Review the diff -->\n\nLook at {{diff}}.\n")))
  (should (equal '(nil . "Just a body.")
                 (rata-agent-prompt-parse "Just a body.\n"))))

(ert-deftest rata-test-agent-prompt-files-extra-directory-wins ()
  "A per-machine prompt overrides a repository prompt of the same name;
a missing extra directory is not an error."
  (let* ((repo (make-temp-file "rata-prompts-repo-" t))
         (extra (make-temp-file "rata-prompts-extra-" t)))
    (unwind-protect
        (progn
          (write-region "a" nil (expand-file-name "shared.md" repo))
          (write-region "b" nil (expand-file-name "only-repo.md" repo))
          (write-region "c" nil (expand-file-name "shared.md" extra))
          (write-region "x" nil (expand-file-name "notes.txt" extra))
          (let ((rata-agent-prompt-directory repo)
                (rata-agent-prompt-extra-directory extra))
            (let ((files (rata-agent-prompt-files)))
              (should (equal '("only-repo" "shared") (sort (mapcar #'car files) #'string<)))
              (should (equal (expand-file-name "shared.md" extra)
                             (cdr (assoc "shared" files))))))
          (let ((rata-agent-prompt-directory repo)
                (rata-agent-prompt-extra-directory (expand-file-name "nope" extra)))
            (should (= 2 (length (rata-agent-prompt-files))))))
      (delete-directory repo t)
      (delete-directory extra t))))

(ert-deftest rata-test-agent-prompt-shipped-prompts-are-valid ()
  "Every prompt in the repository has a description and uses only known
placeholders, so a typo cannot reach a shell as a literal `{{difff}}'."
  (let ((files (directory-files rata-agent-prompt-directory t "\\.md\\'")))
    (should files)
    (dolist (file files)
      (let* ((parsed (rata-agent-prompt-parse
                      (with-temp-buffer (insert-file-contents file) (buffer-string))))
             (full (mapcar (lambda (p) (cons (intern p) "v")) rata-agent-prompt-placeholders)))
        (should (car parsed))
        (should (equal (list file nil)
                       (list file (rata-agent-prompt-unfilled (cdr parsed) full))))))))

(ert-deftest rata-test-agent-prompt-collect-from-file-buffer ()
  "Context collected from a visited file in a git repository.
A second changed file must stay out of {{diff}}: the diff is the visited
file's, so reading `buffer-file-name' from inside a temp buffer (where it
is nil, and the diff silently widens to the project) fails here."
  (rata-test-agent-worktree--with-repo
    (write-region "g\n" nil (expand-file-name "g.txt" repo))
    (rata-test-agent-worktree--git repo "add" "g.txt")
    (rata-test-agent-worktree--git repo "commit" "-qm" "g")
    (write-region "g2\n" nil (expand-file-name "g.txt" repo))
    (write-region "x\ny\n" nil (expand-file-name "f.txt" repo))
    (let ((buf (find-file-noselect (expand-file-name "f.txt" repo))))
      (with-current-buffer buf
        (let ((transient-mark-mode t))
          (goto-char (point-min))
          (set-mark (point))
          (forward-line 1)
          (activate-mark)
          (let ((ctx (rata-agent-prompt--collect)))
            (should (equal "@f.txt" (alist-get 'file ctx)))
            (should (equal (file-name-nondirectory (directory-file-name repo))
                           (alist-get 'project ctx)))
            (should (string-match-p "\\`f.txt:1-1\n```.*\nx\n```\\'" (alist-get 'region ctx)))
            (should (string-match-p "^\\+y$" (alist-get 'diff ctx)))
            (should (string-prefix-p "```diff\n" (alist-get 'diff ctx)))
            (should-not (string-match-p "g2" (alist-get 'diff ctx)))
            (should-not (alist-get 'error ctx)))
          ;; No region, no diff: both missing rather than empty text.
          (deactivate-mark)
          (rata-test-agent-worktree--git repo "commit" "-qm" "y" "--" "f.txt")
          (let ((ctx (rata-agent-prompt--collect)))
            (should-not (alist-get 'region ctx))
            (should-not (alist-get 'diff ctx))))))))

(ert-deftest rata-test-agent-prompt-diff-is-capped ()
  "A diff longer than the cap is cut, and says so."
  (let ((rata-agent-prompt-diff-max-chars 10))
    (should (equal "```diff\n0123456789\n[... diff truncated at 10 characters]\n```"
                   (rata-agent-prompt--fence-diff "0123456789abcdef")))))

(defmacro rata-test-agent-prompt--with-stubs (busy &rest body)
  "Run BODY with one prompt `t1' and agent-shell stubbed.
`inserted' and `queued' collect what reached the stubs."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "rata-prompts-" t))
          (shell (generate-new-buffer " *rata-test-shell*"))
          (rata-agent-prompt-directory dir)
          (rata-agent-prompt-extra-directory nil)
          inserted queued)
     (unwind-protect
         (progn
           (write-region "<!-- d -->\nHello {{project}} {{region}}" nil
                         (expand-file-name "t1.md" dir))
           (cl-letf (((symbol-function 'agent-shell-shell-buffer)
                      (lambda (&rest _) shell))
                     ((symbol-function 'agent-shell-insert)
                      (lambda (&rest args) (push args inserted)))
                     ((symbol-function 'shell-maker-busy) (lambda () ,busy))
                     ((symbol-function 'agent-shell--prompt-queue-read)
                      (lambda (&rest args) (plist-get args :initial)))
                     ((symbol-function 'agent-shell-prompt-queue)
                      (lambda (prompt) (push (cons (current-buffer) prompt) queued)))
                     ((symbol-function 'rata-agent-prompt--collect)
                      (lambda () '((project . "demo")))))
             ,@body))
       (kill-buffer shell)
       (delete-directory dir t))))

(ert-deftest rata-test-agent-prompt-inserts-without-submitting ()
  "The expanded prompt is inserted into the shell and never submitted."
  (rata-test-agent-prompt--with-stubs nil
    (rata-agent-prompt "t1")
    (should (= 1 (length inserted)))
    (let ((args (car inserted)))
      (should (equal "Hello demo {{region}}" (plist-get args :text)))
      (should (eq shell (plist-get args :shell-buffer)))
      (should-not (plist-get args :submit)))
    (should-not queued)))

(ert-deftest rata-test-agent-prompt-busy-shell-queues ()
  "A busy shell gets the prompt through its queue, editable first."
  (rata-test-agent-prompt--with-stubs t
    (rata-agent-prompt "t1")
    (should-not inserted)
    (should (equal (list (cons shell "Hello demo {{region}}")) queued))))

(ert-deftest rata-test-agent-prompt-loads-without-agent-shell ()
  "The module loads with agent-shell absent, and does not load it (L-052)."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (expand-file-name "lisp" user-emacs-directory))
         (status (call-process
                  emacs nil nil nil "-Q" "--batch" "-L" lisp
                  "--eval" "(require 'init-agent-prompts)"
                  "--eval" "(kill-emacs (if (featurep 'agent-shell) 2 0))")))
    (should (eq status 0))))

;;; ============================================================
;;; Run all tests
;;; ============================================================

(ert-run-tests-batch-and-exit)
