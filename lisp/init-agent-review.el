;;; -*- lexical-binding: t; -*-
;;; init-agent-review.el --- Interactive diff & review hub for agent worktrees

;; Multi-file diff review and directive staging cockpit for agent worktrees
;; (Pillar I §1 in plans/ai-agent-pillars.md).
;;
;; Derives from `magit-diff-mode' to inherit full Magit diff navigation,
;; hunk syntax highlighting, folding (TAB), and side-by-side comparison (e via
;; `magit-ediff-dwim'), while displaying custom sections for agent task metadata
;; and pending review directives.
;;
;; Directives are stored in-memory (buffer-local), never touching git state or
;; disk files until explicitly dispatched to the live agent shell via `s' or
;; `C-c C-c'.

(require 'cl-lib)
(require 'subr-x)
(require 'magit nil t)
(require 'magit-diff nil t)
(require 'init-agent-worktree)
(require 'init-agent-center)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-status "agent-shell")
(declare-function agent-shell-prompt-queue "agent-shell-prompt-queue")
(declare-function agent-shell--prompt-queue-read "agent-shell-prompt-queue")
(declare-function shell-maker-busy "shell-maker")
(declare-function safe-persp-name "persp-mode")
(declare-function get-current-persp "persp-mode")
(declare-function persp-switch "persp-mode")
(declare-function evil-define-key* "evil-core")
(declare-function rata-leader "init-evil")

(defgroup rata-agent-review nil
  "Interactive diff & review hub for agent worktrees."
  :group 'tools
  :prefix "rata-agent-review-")

(defvar-local rata-agent-review--worktree nil
  "Directory path of the agent worktree being reviewed.")

(defvar-local rata-agent-review--branch nil
  "Branch name of the agent worktree being reviewed.")

(defvar-local rata-agent-review--base nil
  "Base branch that the agent branch was cut from.")

(defvar-local rata-agent-review--shell-buffer nil
  "The agent-shell buffer associated with this worktree, or nil.")

(defvar-local rata-agent-review--directives nil
  "In-memory list of pending review directives.
Each element is a plist:
  (:id INT :file STR :line INT-OR-NIL :hunk STR-OR-NIL :comment STR :created-at FLOAT)")

(defvar-local rata-agent-review--next-id 1
  "Next unique integer ID to assign to a review directive.")

(defvar-local rata-agent-review--origin-buffer nil
  "The buffer that was active before opening this review buffer.")

;;; ------------------------------------------------------------
;;; Pure functions
;;; ------------------------------------------------------------

(defun rata-agent-review-format-prompt (branch base directives)
  "Format review DIRECTIVES for BRANCH (against BASE) into a Markdown prompt.
DIRECTIVES is a list of plists with keys `:id', `:file', `:line',
`:hunk', and `:comment'.  Returns a non-empty Markdown string formatted
for consumption by an agent shell."
  (unless directives
    (error "No directives to format"))
  (let ((lines (list (format "## Code Review Feedback for `%s` (against `%s`)\n"
                             branch base)
                     "Please address the following review directives in your next changes:\n")))
    (dolist (d directives)
      (let* ((id (or (plist-get d :id) 1))
             (file (or (plist-get d :file) "unknown"))
             (line (plist-get d :line))
             (comment (or (plist-get d :comment) ""))
             (hunk (plist-get d :hunk)))
        (push (format "### Directive %d: `%s`%s\n"
                      id file
                      (if line (format " (Line %d)" line) ""))
              lines)
        (push (format "**Feedback**: %s\n" comment) lines)
        (when (and hunk (not (string-empty-p hunk)))
          (push (format "```diff\n%s\n```\n" (string-trim hunk)) lines))))
    (push "Please update the code accordingly and verify your changes." lines)
    (string-join (nreverse lines) "\n")))

;;; ------------------------------------------------------------
;;; Directive CRUD (buffer-local)
;;; ------------------------------------------------------------

(defun rata-agent-review--add-directive (file line hunk comment)
  "Add a new directive for FILE, LINE, HUNK with COMMENT to buffer-local list.
Returns the newly created directive plist."
  (let ((directive (list :id rata-agent-review--next-id
                         :file file
                         :line line
                         :hunk (and hunk (not (string-empty-p hunk)) hunk)
                         :comment comment
                         :created-at (float-time))))
    (setq rata-agent-review--next-id (1+ rata-agent-review--next-id))
    (setq rata-agent-review--directives
          (append rata-agent-review--directives (list directive)))
    directive))

(defun rata-agent-review--delete-directive-by-id (id)
  "Delete the directive with ID from `rata-agent-review--directives'.
Returns non-nil if a directive was removed."
  (let ((orig-len (length rata-agent-review--directives)))
    (setq rata-agent-review--directives
          (seq-remove (lambda (d) (equal (plist-get d :id) id))
                      rata-agent-review--directives))
    (/= orig-len (length rata-agent-review--directives))))

(defun rata-agent-review--clear-directives ()
  "Remove all pending directives from `rata-agent-review--directives'."
  (setq rata-agent-review--directives nil))

;;; ------------------------------------------------------------
;;; Context extraction at point
;;; ------------------------------------------------------------

(defun rata-agent-review--context-at-point ()
  "Extract `(:file STR :line INT-OR-NIL :hunk STR-OR-NIL)' at point."
  (let* ((section (and (fboundp 'magit-current-section) (magit-current-section)))
         (file-sec (and (fboundp 'magit-diff--file-section) (magit-diff--file-section)))
         (file (when file-sec (oref file-sec value)))
         (is-hunk (and section (fboundp 'magit-section-match) (magit-section-match 'hunk section)))
         (line (when is-hunk
                 (ignore-errors (magit-diff-hunk-line section nil))))
         (hunk (when (and is-hunk (slot-boundp section 'start) (slot-boundp section 'end))
                 (buffer-substring-no-properties (oref section start) (oref section end)))))
    (list :file file :line line :hunk hunk)))

;;; ------------------------------------------------------------
;;; Custom Magit sections
;;; ------------------------------------------------------------

(defun rata-agent-review-insert-header ()
  "Insert the Agent Review header section."
  (magit-insert-section (agent-review-header)
    (magit-insert-heading
      (format "Agent Review: %s" (or rata-agent-review--branch "unknown")))
    (when rata-agent-review--worktree
      (insert (format "  Worktree:  %s\n" (abbreviate-file-name rata-agent-review--worktree))))
    (when rata-agent-review--base
      (insert (format "  Base:      %s (Range: %s...HEAD)\n"
                      rata-agent-review--base rata-agent-review--base)))
    (let ((shell-name (and rata-agent-review--shell-buffer
                           (buffer-live-p rata-agent-review--shell-buffer)
                           (buffer-name rata-agent-review--shell-buffer)))
          (status (if (and rata-agent-review--shell-buffer
                           (buffer-live-p rata-agent-review--shell-buffer))
                      (or (and (fboundp 'rata-agent-center--state)
                               (rata-agent-center--state rata-agent-review--shell-buffer))
                          (and (fboundp 'agent-shell-status)
                               (agent-shell-status :shell-buffer rata-agent-review--shell-buffer))
                          "live")
                    "no shell")))
      (insert (format "  Agent:     [%s]%s\n"
                      status (if shell-name (format " (%s)" shell-name) ""))))
    (insert "\n")))

(defun rata-agent-review-insert-directives ()
  "Insert the Pending Review Directives section."
  (magit-insert-section (agent-review-directives)
    (let ((count (length rata-agent-review--directives)))
      (magit-insert-heading
        (format "Pending Directives (%d):" count))
      (if (null rata-agent-review--directives)
          (insert "  (none — press `c' on a file or hunk to add a review directive)\n\n")
        (dolist (d rata-agent-review--directives)
          (let* ((id (plist-get d :id))
                 (file (or (plist-get d :file) "general"))
                 (line (plist-get d :line))
                 (loc (if line (format "%s:%d" file line) file))
                 (comment (plist-get d :comment)))
            (magit-insert-section (agent-review-directive id)
              (insert (format "  #%d [%s] %s\n" id loc comment)))))
        (insert "\n  Actions: [s/C-c C-c] Send to agent  [d] Delete directive  [c] Add directive\n\n")))))

;;; ------------------------------------------------------------
;;; Major mode
;;; ------------------------------------------------------------

(defvar-keymap rata-agent-review-mode-map
  :doc "Keymap for `rata-agent-review-mode'."
  "c"       #'rata-agent-review-comment
  "d"       #'rata-agent-review-delete-directive
  "s"       #'rata-agent-review-send
  "C-c C-c" #'rata-agent-review-send
  "a"       #'rata-agent-review-jump-to-shell
  "f"       #'rata-agent-review-finish-worktree
  "q"       #'rata-agent-review-quit)

(with-eval-after-load 'magit-diff
  (when (boundp 'magit-diff-mode-map)
    (set-keymap-parent rata-agent-review-mode-map magit-diff-mode-map)))

(define-derived-mode rata-agent-review-mode magit-diff-mode "Agent-Review"
  "Major mode for reviewing agent worktree diffs against their base branch.

\\{rata-agent-review-mode-map}"
  :interactive nil
  :group 'rata-agent-review
  (setq-local magit-bury-buffer-function #'rata-agent-review-quit)
  (setq-local magit-section-initial-visibility-alist
              (append '((untracked . show) (unstaged . show) (staged . show))
                      (and (boundp 'magit-section-initial-visibility-alist)
                           magit-section-initial-visibility-alist)))
  (setq-local magit-diff-sections-hook
              '(rata-agent-review-insert-header
                rata-agent-review-insert-directives
                magit-insert-untracked-files
                magit-insert-unstaged-changes
                magit-insert-staged-changes
                magit-insert-diff)))

(defun rata-agent-review-refresh-buffer ()
  "Refresh the current `rata-agent-review-mode' buffer."
  (magit-diff-refresh-buffer))

;;; ------------------------------------------------------------
;;; Shell resolution
;;; ------------------------------------------------------------

(defun rata-agent-review--find-shell (path branch)
  "Find an agent-shell buffer for worktree PATH on BRANCH."
  (let ((root (file-name-as-directory (file-truename path))))
    (or (cl-find-if (lambda (buf)
                      (and (buffer-live-p buf)
                           (with-current-buffer buf
                             (or (and (derived-mode-p 'agent-shell-mode)
                                      (string-prefix-p root (file-name-as-directory (file-truename default-directory))))
                                 (and (bound-and-true-p persp-mode)
                                      (fboundp 'persp--buffer-in-persps)
                                      (equal (safe-persp-name (get-current-persp)) branch))))))
                    (buffer-list))
        (and (fboundp 'agent-shell-buffers)
             (car (agent-shell-buffers))))))

;;; ------------------------------------------------------------
;;; Buffer setup & opening
;;; ------------------------------------------------------------

(defun rata-agent-review-open (dir &optional origin-buffer)
  "Open Agent Review hub for the worktree at DIR.
ORIGIN-BUFFER is the buffer to return to on `rata-agent-review-quit'."
  (require 'magit)
  (require 'magit-diff)
  (require 'magit-status)
  (when (boundp 'magit-diff-mode-map)
    (set-keymap-parent rata-agent-review-mode-map magit-diff-mode-map))
  (let* ((orig (or origin-buffer
                   (let ((cur (current-buffer)))
                     (unless (string-prefix-p "*Agent Review:" (buffer-name cur))
                       cur))))
         (wt (or (rata-agent-worktree--at dir)
                 (user-error "Not in an agent worktree: %s" dir)))
         (path (car wt))
         (branch (cdr wt))
         (main-root (car (car (rata-agent-worktree--list dir))))
         (base (or (rata-agent-worktree--base main-root branch)
                   (user-error "No recorded base branch for %s" branch)))
         (shell (rata-agent-review--find-shell path branch))
         (range (format "%s...HEAD" base))
         (buf-name (format "*Agent Review: %s*" branch))
         (existing (get-buffer buf-name))
         (directives (and existing (buffer-local-value 'rata-agent-review--directives existing)))
         (next-id (and existing (buffer-local-value 'rata-agent-review--next-id existing)))
         (saved-orig (or orig (and existing (buffer-local-value 'rata-agent-review--origin-buffer existing)))))
    (magit-setup-buffer-internal
     'rata-agent-review-mode nil
     `((magit-buffer-diff-range ,range)
       (magit-buffer-diff-typearg nil)
       (magit-buffer-diff-type committed)
       (magit-buffer-diff-args nil)
       (magit-buffer-diff-files nil)
       (magit-buffer-diff-files-suspended nil)
       (rata-agent-review--worktree ,path)
       (rata-agent-review--branch ,branch)
       (rata-agent-review--base ,base)
       (rata-agent-review--shell-buffer ,shell)
       (rata-agent-review--directives ,directives)
       (rata-agent-review--next-id ,(or next-id 1))
       (rata-agent-review--origin-buffer ,saved-orig))
     :buffer buf-name
     :directory path)))

;;; ------------------------------------------------------------
;;; Commands
;;; ------------------------------------------------------------

(defun rata-agent-review-comment ()
  "Add a review directive/comment on the hunk or file at point."
  (interactive)
  (let* ((ctx (rata-agent-review--context-at-point))
         (file (or (plist-get ctx :file)
                   (read-string "File to review: ")))
         (line (plist-get ctx :line))
         (hunk (plist-get ctx :hunk))
         (prompt (if line
                     (format "Directive for %s:%d: " (file-name-nondirectory file) line)
                   (format "Directive for %s: " (file-name-nondirectory file))))
         (comment (read-string prompt)))
    (when (string-empty-p (string-trim comment))
      (user-error "Comment cannot be empty"))
    (rata-agent-review--add-directive file line hunk comment)
    (magit-refresh)
    (message "Added directive for %s%s"
             (file-name-nondirectory file)
             (if line (format ":%d" line) ""))))

(defun rata-agent-review-delete-directive (&optional id)
  "Delete a pending review directive.
If on a directive in the review buffer, deletes it.  Otherwise prompts."
  (interactive)
  (unless rata-agent-review--directives
    (user-error "No pending review directives to delete"))
  (let* ((sec (and (fboundp 'magit-current-section) (magit-current-section)))
         (sec-id (and sec (eq (oref sec type) 'agent-review-directive) (oref sec value)))
         (target-id (or id sec-id
                        (if (= (length rata-agent-review--directives) 1)
                            (plist-get (car rata-agent-review--directives) :id)
                          (let* ((choices (mapcar (lambda (d)
                                                    (cons (format "#%d [%s%s] %s"
                                                                  (plist-get d :id)
                                                                  (plist-get d :file)
                                                                  (if (plist-get d :line)
                                                                      (format ":%d" (plist-get d :line))
                                                                    "")
                                                                  (plist-get d :comment))
                                                          (plist-get d :id)))
                                                  rata-agent-review--directives))
                                 (choice (completing-read "Delete directive: " (mapcar #'car choices) nil t)))
                            (cdr (assoc choice choices)))))))
    (when (rata-agent-review--delete-directive-by-id target-id)
      (magit-refresh)
      (message "Deleted directive #%d" target-id))))

(defun rata-agent-review-send ()
  "Send all pending review directives as a formatted prompt to the agent shell."
  (interactive)
  (unless rata-agent-review--directives
    (user-error "No pending review directives to send"))
  (let* ((shell (or (and rata-agent-review--shell-buffer
                         (buffer-live-p rata-agent-review--shell-buffer)
                         rata-agent-review--shell-buffer)
                    (rata-agent-review--find-shell rata-agent-review--worktree rata-agent-review--branch)
                    (user-error "No live agent shell found for worktree %s" rata-agent-review--worktree)))
         (count (length rata-agent-review--directives))
         (text (rata-agent-review-format-prompt
                rata-agent-review--branch
                rata-agent-review--base
                rata-agent-review--directives)))
    (if (with-current-buffer shell (and (fboundp 'shell-maker-busy) (ignore-errors (shell-maker-busy))))
        (if (fboundp 'agent-shell-prompt-queue)
            (with-current-buffer shell
              (agent-shell-prompt-queue
               (if (fboundp 'agent-shell--prompt-queue-read)
                   (agent-shell--prompt-queue-read :initial text)
                 text)))
          (user-error "Agent shell is busy and prompt queue is unavailable"))
      (if (fboundp 'agent-shell-insert)
          (agent-shell-insert :text text :shell-buffer shell)
        (user-error "agent-shell-insert not available")))
    (rata-agent-review--clear-directives)
    (magit-refresh)
    (message "Dispatched %d review directive(s) to agent shell (%s)" count (buffer-name shell))))

(defun rata-agent-review-jump-to-shell ()
  "Switch to the agent shell window/buffer associated with this review."
  (interactive)
  (let ((shell (or (and rata-agent-review--shell-buffer
                        (buffer-live-p rata-agent-review--shell-buffer)
                        rata-agent-review--shell-buffer)
                   (rata-agent-review--find-shell rata-agent-review--worktree rata-agent-review--branch))))
    (unless shell
      (user-error "No live agent shell found for %s" rata-agent-review--branch))
    (pop-to-buffer shell)))

(defun rata-agent-review-finish-worktree ()
  "Finish the agent worktree under review via `rata-agent-worktree-finish-at'."
  (interactive)
  (unless rata-agent-review--worktree
    (user-error "Not in an agent review buffer"))
  (let ((wt rata-agent-review--worktree)
        (review-buf (current-buffer)))
    (rata-agent-worktree-finish-at wt)
    (unless (file-exists-p wt)
      (kill-buffer review-buf))))

(defun rata-agent-review-quit (&optional kill-buffer)
  "Quit the review buffer and return to previous buffer without closing window.
With prefix KILL-BUFFER, kill the review buffer; otherwise bury it."
  (interactive "P")
  (let ((rev-buf (current-buffer))
        (prev (and rata-agent-review--origin-buffer
                   (buffer-live-p rata-agent-review--origin-buffer)
                   (not (eq rata-agent-review--origin-buffer (current-buffer)))
                   rata-agent-review--origin-buffer)))
    (if prev
        (switch-to-buffer prev)
      (switch-to-prev-buffer (selected-window) 'bury))
    (if (or (equal kill-buffer '(4)) (eq kill-buffer t) (eq kill-buffer 'kill))
        (kill-buffer rev-buf)
      (bury-buffer rev-buf))))

(defun rata-agent-review (&optional dir)
  "Open Agent Review hub for the worktree at DIR (or current directory).
If not in an agent worktree, prompt to pick one."
  (interactive)
  (let* ((orig (current-buffer))
         (context-dir (or dir (rata-agent-worktree--context-dir)))
         (wt (rata-agent-worktree--at context-dir))
         (main-root (and wt (car (car (rata-agent-worktree--list context-dir))))))
    (if (and wt (not (file-equal-p (car wt) main-root)))
        (rata-agent-review-open (car wt) orig)
      (rata-agent-review-open (rata-agent-worktree--read context-dir) orig))))

(defun rata-agent-review-from-panel ()
  "Open Agent Review hub for the row at point in *Agents* panel."
  (interactive)
  (let ((orig (current-buffer))
        (dir (rata-agent-worktree--context-dir)))
    (rata-agent-review-open dir orig)))

;;; ------------------------------------------------------------
;;; Keymaps & hooks
;;; ------------------------------------------------------------

(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-agent-review-mode-map
    "c"       #'rata-agent-review-comment
    "d"       #'rata-agent-review-delete-directive
    "s"       #'rata-agent-review-send
    "C-c C-c" #'rata-agent-review-send
    "a"       #'rata-agent-review-jump-to-shell
    "f"       #'rata-agent-review-finish-worktree
    "q"       #'rata-agent-review-quit))

(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-agent-center-mode-map
    (kbd "r") #'rata-agent-review-from-panel))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "air" '(rata-agent-review :which-key "review agent worktree diff")))

(provide 'init-agent-review)
;;; init-agent-review.el ends here
