;;; -*- lexical-binding: t; -*-
;;; init-agent-prompts.el --- Reusable prompts for agent-shell

;; A prompt library (C12 in plans/ai-agent-powerhouse.md).  `SPC a i c P'
;; picks a prompt, fills its placeholders from the buffer you are in, and
;; inserts the result into that project's agent shell -- inserts, never
;; submits, so it can be read and edited before anything is spent.
;;
;; Prompts are Markdown files: prompts/*.md in this repository (versioned),
;; plus `rata-agent-prompt-extra-directory' for per-machine ones, which win
;; on a name clash.  The file name is the prompt's name; an optional first
;; line `<!-- description -->' is the annotation in the picker and is not
;; sent.  Placeholders are {{region}}, {{file}}, {{diff}}, {{error}} and
;; {{project}}.  One that cannot be filled, or that is not one of those, is
;; left in the text as written and named in the echo area: it is visible in
;; the shell before you send, which is the point of inserting.
;;
;; agent-shell is never required at load (L-052).  Owns no package.

(require 'cl-lib)
(require 'subr-x)
(require 'project)

(declare-function agent-shell "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-prompt-queue "agent-shell-prompt-queue")
(declare-function agent-shell--prompt-queue-read "agent-shell-prompt-queue")
(declare-function shell-maker-busy "shell-maker")
(declare-function flycheck-overlay-errors-at "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function rata-leader "init-evil")

;; The entry points this module calls first; everything else it calls only
;; after one of them has loaded agent-shell.  `autoload' leaves an existing
;; definition alone.
(autoload 'agent-shell-shell-buffer "agent-shell")
(autoload 'agent-shell--read-shell-buffer "agent-shell")

(defconst rata-agent-prompt--repo-directory
  (expand-file-name
   "prompts"
   (file-name-directory
    (directory-file-name
     (file-name-directory (or load-file-name buffer-file-name
                              (expand-file-name "lisp/" user-emacs-directory))))))
  "The prompts/ directory of the checkout this file was loaded from.")

(defcustom rata-agent-prompt-directory rata-agent-prompt--repo-directory
  "Directory of versioned prompt files (*.md)."
  :type 'directory :group 'convenience)

(defcustom rata-agent-prompt-extra-directory nil
  "Per-machine directory of prompt files, or nil.
A prompt here overrides a repository prompt of the same name.  Set it in
local.el; a directory that does not exist is ignored."
  :type '(choice (const nil) directory) :group 'convenience)

(defcustom rata-agent-prompt-diff-max-chars 20000
  "Longest {{diff}} inserted; a longer diff is cut and says so."
  :type 'integer :group 'convenience)

(defconst rata-agent-prompt-placeholders '("region" "file" "diff" "error" "project")
  "Every placeholder `rata-agent-prompt-expand' knows.")

(defconst rata-agent-prompt--placeholder-re "{{\\([a-z][a-z-]*\\)}}")

;;; ------------------------------------------------------------
;;; Pure
;;; ------------------------------------------------------------

(defun rata-agent-prompt--value (name context)
  "The non-empty string CONTEXT holds for placeholder NAME, else nil."
  (when (member name rata-agent-prompt-placeholders)
    (let ((v (alist-get (intern name) context)))
      (and (stringp v) (not (string-empty-p v)) v))))

(defun rata-agent-prompt-expand (template context)
  "TEMPLATE with each {{name}} replaced by its value in CONTEXT.
CONTEXT is an alist of placeholder symbols to strings.  A placeholder
with no value, or not in `rata-agent-prompt-placeholders', is kept as
written.  One pass: substituted text is never scanned again."
  (replace-regexp-in-string
   rata-agent-prompt--placeholder-re
   (lambda (m)
     (or (rata-agent-prompt--value
          (progn (string-match rata-agent-prompt--placeholder-re m) (match-string 1 m))
          context)
         m))
   template t t))

(defun rata-agent-prompt-unfilled (template context)
  "Names of the placeholders in TEMPLATE that CONTEXT cannot fill.
In order of first appearance, each once; unknown names included."
  (let ((pos 0) names)
    (while (string-match rata-agent-prompt--placeholder-re template pos)
      (let ((name (match-string 1 template)))
        (setq pos (match-end 0))
        (unless (or (member name names) (rata-agent-prompt--value name context))
          (push name names))))
    (nreverse names)))

(defun rata-agent-prompt-parse (text)
  "Split prompt file TEXT into (DESCRIPTION . BODY).
DESCRIPTION is a leading `<!-- ... -->' line, or nil; BODY is trimmed."
  (if (string-match "\\`[ \t\n]*<!--[ \t]*\\(.*?\\)[ \t]*-->[ \t]*\n?" text)
      (cons (match-string 1 text) (string-trim (substring text (match-end 0))))
    (cons nil (string-trim text))))

(defun rata-agent-prompt--fence (body &optional lang)
  "BODY in a Markdown code fence tagged LANG, longer than any run inside it."
  (let ((n 3) (pos 0))
    (while (string-match "`\\{3,\\}" body pos)
      (setq n (max n (1+ (- (match-end 0) (match-beginning 0))))
            pos (match-end 0)))
    (let ((fence (make-string n ?`)))
      (concat fence (or lang "") "\n" (string-trim-right body "\n+") "\n" fence))))

(defun rata-agent-prompt--fence-diff (diff)
  "DIFF fenced, cut at `rata-agent-prompt-diff-max-chars'."
  (rata-agent-prompt--fence
   (if (> (length diff) rata-agent-prompt-diff-max-chars)
       (format "%s\n[... diff truncated at %d characters]"
               (substring diff 0 rata-agent-prompt-diff-max-chars)
               rata-agent-prompt-diff-max-chars)
     diff)
   "diff"))

;;; ------------------------------------------------------------
;;; Prompt files
;;; ------------------------------------------------------------

(defun rata-agent-prompt-files ()
  "Alist of (NAME . FILE) for every prompt, sorted by name.
Extra-directory prompts override repository ones of the same name."
  (let (files)
    (dolist (dir (list rata-agent-prompt-directory rata-agent-prompt-extra-directory))
      (when (and dir (file-directory-p dir))
        (dolist (file (directory-files dir t "\\.md\\'"))
          (setf (alist-get (file-name-base file) files nil nil #'equal) file))))
    (sort files (lambda (a b) (string< (car a) (car b))))))

(defun rata-agent-prompt--read-file (file)
  "FILE parsed as (DESCRIPTION . BODY)."
  (rata-agent-prompt-parse
   (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defun rata-agent-prompt--read (prompt)
  "Read a prompt name with PROMPT, descriptions as annotations."
  (let* ((files (or (rata-agent-prompt-files)
                    (user-error "No prompts in %s" rata-agent-prompt-directory)))
         (descs (mapcar (lambda (f) (cons (car f) (car (rata-agent-prompt--read-file (cdr f)))))
                        files)))
    (completing-read
     prompt
     (lambda (str pred action)
       (if (eq action 'metadata)
           `(metadata (category . rata-agent-prompt)
                      (annotation-function
                       . ,(lambda (c)
                            (when-let* ((d (cdr (assoc c descs))))
                              (concat "  " (propertize d 'face 'completions-annotations))))))
         (complete-with-action action files str pred)))
     nil t)))

;;; ------------------------------------------------------------
;;; Context from the source buffer
;;; ------------------------------------------------------------

(defun rata-agent-prompt--root ()
  "The current project's root directory, or nil."
  (when-let* ((proj (project-current nil)))
    (expand-file-name (project-root proj))))

(defun rata-agent-prompt--relative (file root)
  "FILE relative to ROOT when inside it, else abbreviated."
  (if (and root (file-in-directory-p file root))
      (file-relative-name file root)
    (abbreviate-file-name file)))

(defun rata-agent-prompt--region (root)
  "The active region as `path:L-L' and a fenced block, or nil."
  (when (use-region-p)
    (let* ((beg (region-beginning)) (end (region-end))
           (first (line-number-at-pos beg))
           (last (save-excursion (goto-char end)
                                 (when (and (bolp) (> end beg)) (backward-char))
                                 (line-number-at-pos)))
           (where (if buffer-file-name
                      (rata-agent-prompt--relative buffer-file-name root)
                    (buffer-name)))
           (lang (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name major-mode))))
      (format "%s:%d-%d\n%s" where first last
              (rata-agent-prompt--fence (buffer-substring-no-properties beg end) lang)))))

(defun rata-agent-prompt--diff (root)
  "`git diff HEAD' of this file (of the project without one), or nil."
  (when root
    (let ((file (and buffer-file-name (rata-agent-prompt--relative buffer-file-name root))))
      (with-temp-buffer
        (setq default-directory root)
        (when (and (zerop (apply #'process-file "git" nil t nil "diff" "HEAD"
                                 (and file (list "--" file))))
                   (> (buffer-size) 0))
          (rata-agent-prompt--fence-diff (buffer-string)))))))

(defun rata-agent-prompt--error (root)
  "Diagnostics on the current line from flymake or flycheck, or nil."
  (let ((where (if buffer-file-name
                   (rata-agent-prompt--relative buffer-file-name root)
                 (buffer-name)))
        lines)
    (when (and (bound-and-true-p flymake-mode) (fboundp 'flymake-diagnostics))
      (dolist (d (flymake-diagnostics (line-beginning-position) (line-end-position)))
        (push (format "%s:%d: %s: %s" where
                      (line-number-at-pos (flymake-diagnostic-beg d))
                      (flymake-diagnostic-type d) (flymake-diagnostic-text d))
              lines)))
    (when (and (bound-and-true-p flycheck-mode) (fboundp 'flycheck-overlay-errors-at))
      (dolist (e (flycheck-overlay-errors-at (point)))
        (push (format "%s:%s: %s: %s" where (flycheck-error-line e)
                      (flycheck-error-level e) (flycheck-error-message e))
              lines)))
    (when lines (string-join (nreverse lines) "\n"))))

(defun rata-agent-prompt--collect ()
  "Context alist for `rata-agent-prompt-expand' from the current buffer."
  (let ((root (rata-agent-prompt--root)))
    `((region . ,(rata-agent-prompt--region root))
      (file . ,(and buffer-file-name
                    (concat "@" (rata-agent-prompt--relative buffer-file-name root))))
      (diff . ,(rata-agent-prompt--diff root))
      (error . ,(rata-agent-prompt--error root))
      (project . ,(and root (file-name-nondirectory (directory-file-name root)))))))

;;; ------------------------------------------------------------
;;; Commands
;;; ------------------------------------------------------------

(defun rata-agent-prompt--target-shell (pick)
  "The shell to insert into: chosen when PICK, else the project's, else new."
  (or (if pick
          (agent-shell--read-shell-buffer :prompt "Insert prompt into shell: ")
        (agent-shell-shell-buffer :no-error t :no-create t))
      (progn (agent-shell)
             (agent-shell-shell-buffer :no-error t :no-create t))
      (user-error "No agent shell to insert the prompt into")))

(defun rata-agent-prompt (name &optional pick-shell)
  "Insert prompt NAME, filled from this buffer, into an agent shell.
The project's shell, or a new one; with prefix PICK-SHELL, choose one.
The text is inserted, not submitted.  A busy shell gets it through its
prompt queue, editable in the minibuffer first.  Placeholders that could
not be filled stay in the text and are named in the echo area."
  (interactive (list (rata-agent-prompt--read "Agent prompt: ") current-prefix-arg))
  (let* ((file (or (cdr (assoc name (rata-agent-prompt-files)))
                   (user-error "No prompt named %s" name)))
         (template (cdr (rata-agent-prompt--read-file file)))
         (context (rata-agent-prompt--collect))
         (text (rata-agent-prompt-expand template context))
         (unfilled (rata-agent-prompt-unfilled template context)))
    (when (use-region-p) (deactivate-mark))
    (let ((shell (rata-agent-prompt--target-shell pick-shell)))
      (if (with-current-buffer shell (shell-maker-busy))
          (with-current-buffer shell
            (agent-shell-prompt-queue (agent-shell--prompt-queue-read :initial text)))
        (agent-shell-insert :text text :shell-buffer shell)))
    (when unfilled
      (message "Prompt %s: not filled: %s" name
               (mapconcat (lambda (n)
                            (format (if (member n rata-agent-prompt-placeholders)
                                        "{{%s}}" "{{%s}} (unknown)")
                                    n))
                          unfilled ", ")))))

(defun rata-agent-prompt-edit (name)
  "Open the file of prompt NAME."
  (interactive (list (rata-agent-prompt--read "Edit prompt: ")))
  (find-file (cdr (assoc name (rata-agent-prompt-files)))))

(defun rata-agent-prompt-new (name)
  "Start a new prompt NAME in `rata-agent-prompt-directory'."
  (interactive "sNew prompt name: ")
  (let ((file (expand-file-name (concat name ".md") rata-agent-prompt-directory)))
    (when (file-exists-p file) (user-error "Prompt %s already exists" name))
    (find-file file)
    (insert "<!-- One-line description -->\n\n"
            "Placeholders: {{region}} {{file}} {{diff}} {{error}} {{project}}\n")))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aicP" '(rata-agent-prompt :which-key "insert prompt from library")))

(provide 'init-agent-prompts)
;;; init-agent-prompts.el ends here
