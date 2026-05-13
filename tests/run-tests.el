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

;;; ============================================================
;;; Run all tests
;;; ============================================================

(ert-run-tests-batch-and-exit)
