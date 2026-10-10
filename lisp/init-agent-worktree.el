;;; -*- lexical-binding: t; -*-
;;; init-agent-worktree.el --- One git worktree per agent task

;; Several agents on one repository at once, each in its own git worktree and
;; its own persp layout, so they cannot overwrite each other's work (B6 in
;; plans/ai-agent-powerhouse.md).  `SPC a i c w' / `C' in *Agents* starts one;
;; `SPC a i c W' / `X' finishes it.
;;
;; Upstream has `agent-shell-new-worktree-shell', but it takes no arguments:
;; a random name, a `read-directory-name' prompt, and a branch named after the
;; directory, cut from HEAD.  We need to choose the branch and know its base,
;; so the `git worktree add' is ours; the shell is started the way the panel's
;; `c' starts one.  Layout: <main checkout>/.agent-shell/worktrees/<slug>, the
;; directory upstream uses, kept out of `git status' by .git/info/exclude.
;;
;; Finishing is the destructive half, so it refuses rather than asks while
;; anything would be lost: uncommitted or untracked files, an unsaved buffer,
;; a branch not merged into the base it was cut from.  Only worktrees this
;; module created (their branch carries `rataAgentBase' in the repo config)
;; can be finished.  agent-shell writes transcripts inside the worktree, where
;; they are ignored and `git worktree remove' would delete them without a
;; word, so they are copied to the main checkout first.  Branch deletion is a
;; second question and uses `git branch -d', which refuses unmerged work too.

(require 'cl-lib)
(require 'subr-x)
(require 'init-agent-center)

(declare-function agent-shell-new-shell "agent-shell")
(declare-function persp-add-new "persp-mode")
(declare-function persp-kill "persp-mode")
(declare-function persp-names "persp-mode")
(declare-function persp-switch "persp-mode")
(declare-function evil-define-key* "evil-core")
(declare-function rata-leader "init-evil")

(defcustom rata-agent-worktree-prefix "agent/"
  "Prefix of every branch an agent worktree is created on."
  :type 'string :group 'convenience)

(defcustom rata-agent-worktree-slug-max 40
  "Longest slug (the branch name after the prefix)."
  :type 'integer :group 'convenience)

(defconst rata-agent-worktree-directory ".agent-shell/worktrees"
  "Where worktrees go, relative to the main checkout (upstream's directory).")

(defconst rata-agent-worktree--base-key "rataAgentBase"
  "Repo-config key, under branch.<name>, recording the branch it was cut from.
Its presence is also what marks a worktree as one this module may finish.")

;;; ------------------------------------------------------------
;;; Pure
;;; ------------------------------------------------------------

(defun rata-agent-worktree-branch-name (task)
  "Branch name for TASK: `rata-agent-worktree-prefix' plus a slug.
Lower case, runs of anything but letters and digits become one dash, cut
to `rata-agent-worktree-slug-max' without a trailing dash.  A Jira key
like ABC-123 survives as abc-123."
  (let* ((slug (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase task)))
         (slug (string-trim slug "-+" "-+"))
         (slug (string-trim-right
                (substring slug 0 (min (length slug) rata-agent-worktree-slug-max))
                "-+")))
    (when (string-empty-p slug)
      (user-error "No letters or digits in %S to name a branch after" task))
    (concat rata-agent-worktree-prefix slug)))

(defun rata-agent-worktree--parse-list (porcelain)
  "PORCELAIN (`git worktree list --porcelain') as ((PATH . BRANCH) ...).
The main checkout comes first, as git lists it.  A detached worktree has
a nil BRANCH."
  (let (result)
    (dolist (block (split-string porcelain "\n\n" t "[\n ]+"))
      (let (path branch)
        (dolist (line (split-string block "\n" t))
          (cond ((string-prefix-p "worktree " line) (setq path (substring line 9)))
                ((string-prefix-p "branch refs/heads/" line)
                 (setq branch (substring line 18)))))
        (when path (push (cons path branch) result))))
    (nreverse result)))

(defun rata-agent-worktree--path (main-root branch)
  "Where BRANCH's worktree goes under MAIN-ROOT."
  (let ((slug (string-replace
               "/" "-" (string-remove-prefix rata-agent-worktree-prefix branch))))
    (expand-file-name (file-name-concat rata-agent-worktree-directory slug)
                      main-root)))

;;; ------------------------------------------------------------
;;; Git
;;; ------------------------------------------------------------

(defun rata-agent-worktree--git (dir &rest args)
  "Run git ARGS in DIR; return (EXIT-CODE . TRIMMED-OUTPUT).
Arguments go to git directly, never through a shell."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (cons (apply #'process-file "git" nil t nil args)
            (string-trim (buffer-string))))))

(defun rata-agent-worktree--git! (dir &rest args)
  "Run git ARGS in DIR and return its output; a `user-error' if it fails."
  (let ((res (apply #'rata-agent-worktree--git dir args)))
    (unless (zerop (car res))
      (user-error "git %s failed: %s" (string-join args " ") (cdr res)))
    (cdr res)))

(defun rata-agent-worktree--list (dir)
  "Worktrees of the repository at DIR, main first, or nil outside one."
  (let ((res (rata-agent-worktree--git dir "worktree" "list" "--porcelain")))
    (when (zerop (car res))
      (rata-agent-worktree--parse-list (cdr res)))))

(defun rata-agent-worktree--base (dir branch)
  "The branch BRANCH was cut from, as recorded at creation, or nil."
  (let ((res (rata-agent-worktree--git
              dir "config" "--get"
              (format "branch.%s.%s" branch rata-agent-worktree--base-key))))
    (and (zerop (car res)) (cdr res))))

(defun rata-agent-worktree--at (dir)
  "The (PATH . BRANCH) of the worktree containing DIR, or nil.
The innermost one, since agent worktrees sit inside the main checkout."
  (let ((dir (file-name-as-directory (file-truename dir))))
    (car (sort (seq-filter (lambda (wt)
                             (file-in-directory-p
                              dir (file-name-as-directory (file-truename (car wt)))))
                           (rata-agent-worktree--list dir))
               (lambda (a b) (> (length (car a)) (length (car b))))))))

(defun rata-agent-worktree--ensure-ignored (main-root)
  "Keep the worktrees out of MAIN-ROOT's `git status', via info/exclude.
The file is shared by every worktree, so ignoring .agent-shell/ here also
hides agent-shell's own transcripts inside each worktree."
  (unless (zerop (car (rata-agent-worktree--git
                       main-root "check-ignore" "-q" rata-agent-worktree-directory)))
    (let ((exclude (expand-file-name
                    "info/exclude"
                    (rata-agent-worktree--git! main-root "rev-parse" "--path-format=absolute"
                                               "--git-common-dir"))))
      (make-directory (file-name-directory exclude) t)
      (write-region "/.agent-shell/\n" nil exclude t 'silent))))

;;; ------------------------------------------------------------
;;; Creating
;;; ------------------------------------------------------------

(defun rata-agent-worktree--switch-layout (name)
  "Create persp layout NAME if needed and switch to it; no-op without persp."
  (when (and (bound-and-true-p persp-mode) (fboundp 'persp-switch))
    (unless (member name (persp-names)) (persp-add-new name))
    (persp-switch name)))

(defun rata-agent-worktree-create (dir branch)
  "Create BRANCH in a new worktree of DIR's repository and start a shell in it.
BRANCH is cut from the branch checked out at DIR, which is recorded as its
base.  The shell opens in a layout named BRANCH.  Return the worktree path."
  (let* ((main-root (or (car (car (rata-agent-worktree--list dir)))
                        (user-error "Not in a git repository: %s" dir)))
         (base (let ((res (rata-agent-worktree--git dir "symbolic-ref" "--short" "-q" "HEAD")))
                 (if (zerop (car res)) (cdr res)
                   (user-error "HEAD is detached in %s: no branch to merge back into" dir))))
         (path (rata-agent-worktree--path main-root branch)))
    (when (zerop (car (rata-agent-worktree--git
                       dir "show-ref" "--verify" "-q" (concat "refs/heads/" branch))))
      (user-error "Branch %s already exists" branch))
    (when (file-exists-p path)
      (user-error "Directory already exists: %s" path))
    (rata-agent-worktree--git! dir "check-ref-format" "--branch" branch)
    (rata-agent-worktree--ensure-ignored main-root)
    (make-directory (file-name-directory path) t)
    (rata-agent-worktree--git! dir "worktree" "add" "-q" "-b" branch path base)
    (rata-agent-worktree--git! dir "config"
                               (format "branch.%s.%s" branch rata-agent-worktree--base-key)
                               base)
    (rata-agent-worktree--switch-layout branch)
    ;; Never open the shell in the dedicated panel window.
    (when (window-parameter (selected-window) 'window-side)
      (select-window (rata-agent-center--main-window)))
    (let ((default-directory (file-name-as-directory path)))
      (call-interactively #'agent-shell-new-shell))
    (message "Worktree %s on %s (from %s)" (abbreviate-file-name path) branch base)
    path))

(defun rata-agent-worktree--context-dir ()
  "The directory a command means: the panel line's shell or project, else here."
  (or (when (derived-mode-p 'rata-agent-center-mode)
        (if (get-text-property (line-beginning-position) 'rata-agent-center-heading)
            (when-let* ((project (get-text-property (line-beginning-position)
                                                    'rata-agent-center-project)))
              (expand-file-name project))
          (when-let* ((shell (tabulated-list-get-id))
                      ((buffer-live-p shell)))
            (buffer-local-value 'default-directory shell))))
      default-directory))

(defun rata-agent-worktree-new (task)
  "Start an agent on TASK in a new worktree, branch and layout of its own.
In *Agents* the repository is the one on the current line."
  (interactive (list (read-string "Task: ")))
  (let* ((dir (rata-agent-worktree--context-dir))
         (branch (read-string "Branch: " (rata-agent-worktree-branch-name task))))
    (rata-agent-worktree-create dir branch)))

;;; ------------------------------------------------------------
;;; Finishing
;;; ------------------------------------------------------------

(defun rata-agent-worktree--buffers-in (path)
  "Live buffers visiting a file in PATH or with their directory there."
  (let ((root (file-name-as-directory (file-truename path))))
    (seq-filter (lambda (buf)
                  (let ((file (buffer-local-value 'buffer-file-name buf))
                        (dir (buffer-local-value 'default-directory buf)))
                    (or (and file (file-in-directory-p file root))
                        (and dir (not (file-remote-p dir))
                             (file-in-directory-p dir root)))))
                (buffer-list))))

(defun rata-agent-worktree--keep-transcripts (path main-root)
  "Copy agent-shell transcripts from worktree PATH into MAIN-ROOT's.
A name already taken there gets the worktree's directory name appended."
  (let ((from (expand-file-name ".agent-shell/transcripts" path))
        (to (expand-file-name ".agent-shell/transcripts" main-root)))
    (when (file-directory-p from)
      (make-directory to t)
      (dolist (file (directory-files from t directory-files-no-dot-files-regexp))
        (let ((target (expand-file-name (file-name-nondirectory file) to)))
          (when (file-exists-p target)
            (setq target (expand-file-name
                          (format "%s-%s.%s" (file-name-base file)
                                  (file-name-nondirectory path)
                                  (or (file-name-extension file) ""))
                          to)))
          (copy-file file target nil t))))))

(defun rata-agent-worktree-finish-at (dir)
  "Remove the agent worktree containing DIR, its shells and its layout.
Refuses while anything would be lost; asks before acting, and again
before deleting the branch."
  (let* ((wt (or (rata-agent-worktree--at dir)
                 (user-error "Not in a git worktree: %s" dir)))
         (path (car wt))
         (branch (cdr wt))
         (main-root (car (car (rata-agent-worktree--list dir))))
         (base (and branch (rata-agent-worktree--base main-root branch))))
    (when (file-equal-p path main-root)
      (user-error "%s is the main checkout, not an agent worktree" path))
    (unless base
      (user-error "%s was not created by rata-agent-worktree-new; finish it by hand" path))
    (let ((status (rata-agent-worktree--git! path "status" "--porcelain")))
      (unless (string-empty-p status)
        (user-error "%s has uncommitted or untracked files:\n%s" branch status)))
    (when-let* ((unsaved (seq-filter (lambda (b) (and (buffer-file-name b)
                                                       (buffer-modified-p b)))
                                     (rata-agent-worktree--buffers-in path))))
      (user-error "Unsaved buffers in %s: %s" branch
                  (mapconcat #'buffer-name unsaved ", ")))
    (unless (zerop (car (rata-agent-worktree--git
                         main-root "merge-base" "--is-ancestor" branch base)))
      (user-error "%s is not merged into %s" branch base))
    (when (y-or-n-p (format "Finish %s: kill its shells and layout, remove %s? "
                            branch (abbreviate-file-name path)))
      (let ((default-directory (file-name-as-directory main-root)))
        ;; Already asked, and nothing unsaved: no per-buffer questions.
        (let (kill-buffer-query-functions)
          (mapc #'kill-buffer (rata-agent-worktree--buffers-in path)))
        (rata-agent-worktree--keep-transcripts path main-root)
        (when (and (bound-and-true-p persp-mode) (member branch (persp-names)))
          (persp-kill branch t))
        (rata-agent-worktree--git! main-root "worktree" "remove" path)
        (if (y-or-n-p (format "Also delete branch %s (merged into %s)? " branch base))
            (progn (rata-agent-worktree--git! main-root "branch" "-d" branch)
                   (message "Removed %s and deleted %s" (abbreviate-file-name path) branch))
          (message "Removed %s; branch %s kept" (abbreviate-file-name path) branch))))))

(defun rata-agent-worktree--read (dir)
  "Pick one of the agent worktrees of DIR's repository."
  (let* ((main-root (or (car (car (rata-agent-worktree--list dir)))
                        (user-error "Not in a git repository: %s" dir)))
         (own (seq-filter (lambda (wt) (and (cdr wt)
                                            (rata-agent-worktree--base main-root (cdr wt))))
                          (cdr (rata-agent-worktree--list dir)))))
    (unless own (user-error "No agent worktrees in %s" main-root))
    (car (rassoc (completing-read "Finish worktree: " (mapcar #'cdr own) nil t)
                 own))))

(defun rata-agent-worktree-finish ()
  "Finish an agent worktree: the panel line's, the current one, or one picked."
  (interactive)
  (let* ((dir (rata-agent-worktree--context-dir))
         (wt (rata-agent-worktree--at dir))
         (main-root (car (car (rata-agent-worktree--list dir)))))
    (rata-agent-worktree-finish-at
     (if (and wt (not (file-equal-p (car wt) main-root)))
         (car wt)
       (rata-agent-worktree--read dir)))))

;;; ------------------------------------------------------------
;;; The panel
;;; ------------------------------------------------------------

(defun rata-agent-worktree-project-label (dir)
  "`repo ⎇ branch' when DIR is in an agent worktree, else nil.
On `rata-agent-center-project-label-functions'."
  (unless (file-remote-p dir)
    (when-let* ((list (rata-agent-worktree--list dir))
                (main-root (car (car list)))
                (wt (rata-agent-worktree--at dir))
                ((not (file-equal-p (car wt) main-root)))
                (branch (cdr wt))
                ((rata-agent-worktree--base main-root branch)))
      (format "%s ⎇ %s" (abbreviate-file-name (directory-file-name main-root)) branch))))

(add-hook 'rata-agent-center-project-label-functions #'rata-agent-worktree-project-label)

(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-agent-center-mode-map
    (kbd "C") #'rata-agent-worktree-new
    (kbd "X") #'rata-agent-worktree-finish))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aicw" '(rata-agent-worktree-new :which-key "agent in new worktree")
    "aicW" '(rata-agent-worktree-finish :which-key "finish agent worktree")))

(provide 'init-agent-worktree)
;;; init-agent-worktree.el ends here
