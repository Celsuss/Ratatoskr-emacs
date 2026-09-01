;;; -*- lexical-binding: t; -*-
;;; init-blog.el --- org-roam to Hugo blog export

;; Exports org-roam notes to the Hugo site at `rata-hugo-dir' via ox-hugo, and
;; gives the blog the two things it lacked: a way to *find* every post, and a
;; way to see which of them the site actually has.
;;
;; The roam tree is flat — posts live among ~1600 other notes — so a post is
;; identified by the `rata-blog-tag' filetag, not by its location.  That is the
;; design `init-present.el' uses for reveal.js decks, and the functions below
;; deliberately mirror it (`rata-blog-files' <- `rata-reveal-deck-files',
;; `rata-blog-add-header' <- `rata-reveal-add-header', `rata-blog-export-all'
;; <- `rata-reveal-export-all') rather than inventing a second idiom.
;;
;; The tag is also what the org-super-agenda "Blog Posts" group in init-org.el
;; selects on.  Before this module the `blog-post' capture template applied no
;; filetag at all, so that group could never match and there was no set of
;; posts to query: 8 notes carried Hugo export properties while only 3 had ever
;; reached content/posts/.  `rata-test-blog-tag-matches-agenda-group' locks the
;; two ends together, because nothing about that failure is visible — the group
;; renders as an empty section, exactly like a leader key bound in a deferred
;; `:config' resolves to nothing.
;;
;; Export path resolution: ox-hugo prefers a per-file `#+hugo_base_dir:'
;; keyword and falls back to `org-hugo-base-dir', which this module sets from
;; `rata-hugo-dir'.  So a post that forgets the keyword still exports to the
;; right place, and a post that sets one still wins.

;; NB: no `require' of org, ox or org-roam here — not even inside
;; `eval-when-compile'.  `eval-when-compile' is plain `progn' when a file is
;; *interpreted*, and the modules in lisp/ are loaded as source, so a
;; "compile-time" require runs on every startup and pulls Emacs's built-in Org
;; ahead of the newer one elpaca activates.  See FAIL-0012 / L-028;
;; `init-present.el' and `init-dialogic.el' are the models.
(eval-when-compile
  (defvar rata-org-roam-dir)
  (defvar org-hugo-base-dir))

(declare-function org-roam-db-query "org-roam-db")
(declare-function org-hugo-export-wim-to-md "ox-hugo")
(declare-function org-entry-get "org")
(declare-function org-entry-put "org")
(declare-function org-before-first-heading-p "org")
(declare-function org-back-to-heading "org")

;;; ============================================================
;;; Customization
;;; ============================================================

(defcustom rata-hugo-dir (expand-file-name "~/workspace/second-brain/hugo/")
  "Hugo blog directory.
The site root: `content/', `config.toml' and `static/' sit directly under
it.  Used both as the ox-hugo base directory and as the working directory
for the preview server."
  :type 'directory
  :group 'rata)

(defcustom rata-blog-tag "blog"
  "Filetag marking an org-roam node as a blog post.
`rata-blog-add-header' and the \"blog-post\" capture template apply it,
`rata-blog-files' selects on it, and the org-super-agenda \"Blog Posts\"
group in init-org.el groups on it.  The roam tree is flat, so this tag is
the only thing distinguishing a post from any other note.  Changing it
here without changing that agenda group silently empties the group;
`rata-test-blog-tag-matches-agenda-group' fails when the two drift."
  :type 'string
  :group 'rata)

(defcustom rata-blog-section "/posts/"
  "Hugo section a post lands in when it names no EXPORT_HUGO_SECTION.
Written the way the capture template writes it, leading and trailing
slashes included; `rata-blog--md-path' trims them."
  :type 'string
  :group 'rata)

;;; ============================================================
;;; Finding posts
;;; ============================================================

(defun rata-blog-files ()
  "Return org-roam files tagged with `rata-blog-tag'.
Mirrors `rata-reveal-deck-files' in init-present.el and, through it,
`rata-org-roam-agenda-files' in init-org.el.  A directory-based lookup is
not an option: the roam tree is flat, so posts sit among every other note
and only the tag tells them apart.

The `require' is deliberate and must not become an `fboundp' guard.  This
is a user-facing entry point — `rata-blog-status' is often the first thing
touched in a session — so org-roam may genuinely not be loaded yet, and a
guard that returns nil makes \"org-roam is not loaded\" indistinguishable
from \"you have no posts\".  That is the L-029 failure shape again, this
time inside the fix for it.  Requiring at *call* time is safe: the
load-time prohibition in the header is about init, and by the time a
command runs elpaca has activated everything (`rata-reveal-export-all'
requires org-re-reveal the same way)."
  (require 'org-roam)
  (mapcar #'car
          (org-roam-db-query
           [:select [nodes:file]
                    :from tags
                    :left-join nodes
                    :on (= tags:node-id nodes:id)
                    :where (= tags:tag $s1)
                    :group-by nodes:file]
           rata-blog-tag)))

;;; ============================================================
;;; Where a post exports to
;;; ============================================================

(defun rata-blog--md-path (content section name)
  "Return the .md path for post NAME in SECTION under the CONTENT directory.
SECTION is trimmed of surrounding slashes, so the \"/posts/\" the capture
template writes and the \"posts\" ox-hugo defaults to mean the same thing."
  (expand-file-name
   (concat name ".md")
   (expand-file-name (replace-regexp-in-string "\\`/+\\|/+\\'" "" (or section ""))
                     content)))

(defun rata-blog--parse-targets (text dir &optional slug)
  "Return the .md files the org source TEXT would export to.

TEXT is the contents of a post, DIR the directory it lives in (a
`#+hugo_base_dir:' keyword is relative to that), and SLUG the fallback
export file name for a post that names none.  Returns a list of
\(NAME PATH NAMED-P), one per exportable subtree, or a single file-level
entry when no subtree carries an EXPORT_FILE_NAME.  NAMED-P is nil when the
post named no export file and PATH was guessed from SLUG — ox-hugo exports
a subtree only when the property has a value, so that post cannot reach the
site however many times it is exported, and a caller that presents PATH as
though it were pending would be lying.

Pure: parses a string and computes paths, touching no filesystem, so the
whole path convention is testable in batch without reaching into the
operator's notes."
  (with-temp-buffer
    (insert text)
    (let* ((case-fold-search t)
           (base (progn
                   (goto-char (point-min))
                   (if (re-search-forward
                        "^#\\+hugo_base_dir:[ \t]*\\(.+?\\)[ \t]*$" nil t)
                       (expand-file-name (match-string 1) dir)
                     rata-hugo-dir)))
           (content (expand-file-name "content" base))
           ;; A file-level section keyword, for a subtree that names none.
           (file-section (progn
                           (goto-char (point-min))
                           (when (re-search-forward
                                  "^#\\+hugo_section:[ \t]*\\(.+?\\)[ \t]*$" nil t)
                             (match-string 1))))
           targets)
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*:export_file_name:[ \t]*\\(.*?\\)[ \t]*$" nil t)
        (let* ((name (match-string 1))
               (named t)
               ;; The section may sit either side of the file name in the same
               ;; drawer, so search the drawer around it rather than forward.
               (drawer-end (save-excursion
                             (if (re-search-forward "^[ \t]*:end:[ \t]*$" nil t)
                                 (point)
                               (point-max))))
               (drawer-start (save-excursion
                               (if (re-search-backward
                                    "^[ \t]*:properties:[ \t]*$" nil t)
                                   (point)
                                 (point-min))))
               (section (save-excursion
                          (goto-char drawer-start)
                          (when (re-search-forward
                                 "^[ \t]*:export_hugo_section:[ \t]*\\(.+?\\)[ \t]*$"
                                 drawer-end t)
                            (match-string 1)))))
          ;; The capture template used to leave :export_file_name: empty; treat
          ;; that as "not named yet" and fall back to the note's slug so the
          ;; post is still listed — flagged, not silently dropped.
          (when (string-empty-p name)
            (setq named nil)
            (setq name slug))
          (when (and name (not (string-empty-p name)))
            (push (list name
                        (rata-blog--md-path
                         content (or section file-section rata-blog-section) name)
                        named)
                  targets))))
      ;; No subtree names a file: the whole note is one post, if we have a slug.
      (when (and (null targets) slug)
        (goto-char (point-min))
        (let ((section (when (re-search-forward
                              "^[ \t]*:export_hugo_section:[ \t]*\\(.+?\\)[ \t]*$" nil t)
                         (match-string 1))))
          (push (list slug
                      (rata-blog--md-path
                       content (or section file-section rata-blog-section) slug)
                      nil)
                targets)))
      (nreverse targets))))

(defun rata-blog--targets (file)
  "Return the (NAME . PATH) export targets of post FILE."
  (when (file-readable-p file)
    (rata-blog--parse-targets
     (with-temp-buffer
       (insert-file-contents file)
       (buffer-string))
     (file-name-directory file)
     (file-name-base file))))

(defun rata-blog--target-file (file)
  "Return the first .md path post FILE exports to, or nil."
  (nth 1 (car (rata-blog--targets file))))

(defun rata-blog--state (file target)
  "Return the export state of post FILE relative to its TARGET .md.
One of `never' (no markdown yet), `stale' (the note is newer) or
`exported'."
  (cond ((not (file-exists-p target)) 'never)
        ((file-newer-than-file-p file target) 'stale)
        (t 'exported)))

(defun rata-blog--target-state (file target)
  "Return the state of TARGET, a (NAME PATH NAMED-P) entry of post FILE.
`unnamed' outranks the file comparison: a post with an empty
:EXPORT_FILE_NAME: is not pending export, it is unable to export, and
reporting it as `never' would send the reader to re-run a command that
cannot help."
  (if (nth 2 target)
      (rata-blog--state file (nth 1 target))
    'unnamed))

;;; ============================================================
;;; Status report
;;; ============================================================

(defun rata-blog-status-data ()
  "Return one plist per export target: :file, :name, :target, :state."
  (let (rows)
    (dolist (file (rata-blog-files))
      (dolist (target (rata-blog--targets file))
        (push (list :file file
                    :name (car target)
                    :target (nth 1 target)
                    :state (rata-blog--target-state file target))
              rows)))
    (sort (nreverse rows)
          (lambda (a b) (string< (plist-get a :name) (plist-get b :name))))))

;;;###autoload
(defun rata-blog-status ()
  "Report every `rata-blog-tag' post and whether the site has it.
Answers what the config could not answer before: which notes are marked as
posts, where each exports to, and which of them the site is missing or
serving from a stale export."
  (interactive)
  (let* ((rows (rata-blog-status-data))
         (tally (lambda (state)
                  (seq-count (lambda (r) (eq (plist-get r :state) state)) rows))))
    (with-current-buffer (get-buffer-create "*blog-status*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Blog status — :%s: posts to %s\n\n"
                        rata-blog-tag (abbreviate-file-name rata-hugo-dir))
                (format "%-10s %-46s %s\n" "state" "post" "target")
                (make-string 100 ?-) "\n")
        (if (null rows)
            (insert (format "No notes tagged :%s:.\n\n" rata-blog-tag)
                    "Tag an existing note with SPC o b h, or capture a new post\n"
                    "with SPC o r c and template \"b\".\n")
          (dolist (row rows)
            (insert (format "%-10s %-46s %s\n"
                            (symbol-name (plist-get row :state))
                            (truncate-string-to-width (plist-get row :name) 46)
                            (abbreviate-file-name (plist-get row :target)))))
          (insert "\n"
                  (format "%d post(s): %d exported, %d stale, %d never exported\n"
                          (length rows)
                          (funcall tally 'exported)
                          (funcall tally 'stale)
                          (funcall tally 'never))
                  "SPC o b E exports all; C-u SPC o b E only the stale and missing.\n")
          (let ((unnamed (funcall tally 'unnamed)))
            (when (> unnamed 0)
              (insert (format "\n%d post(s) marked `unnamed' have an empty :EXPORT_FILE_NAME:.\n"
                              unnamed)
                      "ox-hugo skips those, so exporting will not publish them —\n"
                      "give each one a slug (it becomes the URL) first.\n"))))
        (goto-char (point-min)))
      (special-mode)
      ;; `special-mode' is in none of evil's state lists, so a plain
      ;; `define-key' here would be shadowed.  Same reason init-dialogic.el and
      ;; init-claude-loop.el use the function form — `evil-define-key' is a
      ;; macro and would compile to a broken function call.
      (when (fboundp 'evil-define-key*)
        (evil-define-key* 'normal (current-local-map) (kbd "q") #'quit-window)))
    (display-buffer "*blog-status*")))

;;; ============================================================
;;; Export
;;; ============================================================

;;;###autoload
(defun rata-blog-export-all (&optional stale-only)
  "Export every note tagged `rata-blog-tag' to `rata-hugo-dir'.
With a prefix argument STALE-ONLY, skip posts whose markdown is already
newer than the note.  Mirrors `rata-reveal-export-all' in init-present.el."
  (interactive "P")
  (require 'ox-hugo)
  (let ((files (rata-blog-files))
        (exported 0)
        (skipped 0))
    (unless files
      (user-error "No notes tagged :%s: — tag one with `rata-blog-add-header'"
                  rata-blog-tag))
    (dolist (file files)
      (let ((targets (rata-blog--targets file)))
        ;; A note with no computable target is never skipped: not knowing where
        ;; it goes is not evidence that it is current.
        (if (and stale-only
                 targets
                 (not (seq-find (lambda (tg)
                                  (memq (rata-blog--target-state file tg)
                                        '(never stale)))
                                targets)))
            (setq skipped (1+ skipped))
          (when (file-readable-p file)
            (with-current-buffer (find-file-noselect file)
              (save-excursion
                ;; t = all subtrees: one note may hold more than one post.
                (org-hugo-export-wim-to-md t))
              (setq exported (1+ exported)))))))
    (message "Exported %d post(s) to %s%s"
             exported (abbreviate-file-name rata-hugo-dir)
             (if (> skipped 0) (format " (%d already current)" skipped) ""))))

;;; ============================================================
;;; Turning a note into a post
;;; ============================================================

(defun rata-blog--goto-header-end ()
  "Move point past the note's leading property drawer and #+keyword: block."
  (goto-char (point-min))
  (when (looking-at "^:PROPERTIES:")
    (re-search-forward "^:END:" nil t)
    (forward-line 1))
  (while (looking-at "^#\\+[A-Za-z_]+:")
    (forward-line 1))
  (point))

;;;###autoload
(defun rata-blog-add-header ()
  "Turn the current org note into a blog post, in place.
Adds `rata-blog-tag' to #+filetags: and a `#+hugo_base_dir:' keyword when
the note has none, leaving its content untouched.  Safe to run twice.
This is the counterpart to the \"blog-post\" org-roam capture template:
the template for a new post, this for a note that already exists.
Mirrors `rata-reveal-add-header' in init-present.el."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org buffer"))
  (let ((case-fold-search t))
    (save-excursion
      ;; 1. the blog tag, appended to #+filetags: or added as a new line
      (goto-char (point-min))
      (if (re-search-forward "^#\\+filetags:.*$" nil t)
          (unless (string-match-p (concat ":" (regexp-quote rata-blog-tag) ":")
                                  (match-string 0))
            (goto-char (match-end 0))
            (unless (eq (char-before) ?:) (insert ":"))
            (insert rata-blog-tag ":"))
        (rata-blog--goto-header-end)
        (insert "#+filetags: :" rata-blog-tag ":\n"))
      ;; 2. the base dir, only when the note names none.  Relative, so it keeps
      ;; working if the second brain moves.
      (goto-char (point-min))
      (unless (re-search-forward "^#\\+hugo_base_dir:" nil t)
        (rata-blog--goto-header-end)
        (insert "#+hugo_base_dir: ../hugo/\n"))))
  (message "Post header added — set :EXPORT_FILE_NAME: on the heading, then SPC o b e"))

;;;###autoload
(defun rata-blog-toggle-draft ()
  "Toggle EXPORT_HUGO_DRAFT on the post subtree at point.
A draft is written to the site but served only by `hugo server -D', which
is what `rata-hugo-preview' runs — so a post can be previewed in place
before it goes live."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org buffer"))
  (when (org-before-first-heading-p)
    (user-error "Point is above the first heading — the draft flag is a post property"))
  (save-excursion
    (org-back-to-heading t)
    (if (equal (org-entry-get (point) "EXPORT_HUGO_DRAFT") "true")
        (progn (org-entry-put (point) "EXPORT_HUGO_DRAFT" "false")
               (message "Draft off — the next export publishes this post"))
      (org-entry-put (point) "EXPORT_HUGO_DRAFT" "true")
      (message "Draft on — visible under SPC o b p only"))))

;;; ============================================================
;;; Preview server
;;; ============================================================

(defconst rata-hugo--server-buffer "*hugo-server*")
(defconst rata-hugo--server-process "hugo-server")
(defconst rata-hugo--server-url "http://localhost:1313")

(defun rata-hugo--server-live-p ()
  "Return non-nil when the preview server is actually running.
The buffer outliving the process is the normal case — hugo exits on a
config error and leaves its output behind — so the buffer is not evidence
that anything is listening."
  (process-live-p (get-process rata-hugo--server-process)))

(defun rata-hugo--browse-when-ready (proc output)
  "Process filter: log OUTPUT from PROC, then browse once hugo is listening.
Hugo prints \"Web Server is available at ...\" only after binding the port.
Waiting a fixed two seconds instead raced the first build and could open
the browser on a port nothing was serving yet."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert output)))))
  (when (string-match-p "Web Server is available" output)
    (set-process-filter proc nil)
    (browse-url rata-hugo--server-url)))

;;;###autoload
(defun rata-hugo-preview ()
  "Start `hugo server -D' in `rata-hugo-dir' and open the site.
When the server is already running, just open the browser.  Drafts are
included (-D), so a post marked by `rata-blog-toggle-draft' is visible
here and nowhere else."
  (interactive)
  (unless (executable-find "hugo")
    (user-error "hugo not found on PATH — install it (see the justfile deps target)"))
  (unless (file-directory-p rata-hugo-dir)
    (user-error "No Hugo site at %s — check `rata-hugo-dir'" rata-hugo-dir))
  (if (rata-hugo--server-live-p)
      (browse-url rata-hugo--server-url)
    ;; A dead process may have left its buffer behind; start clean so the log
    ;; in it belongs to this run.
    (when (get-buffer rata-hugo--server-buffer)
      (kill-buffer rata-hugo--server-buffer))
    (let* ((default-directory (file-name-as-directory rata-hugo-dir))
           (proc (start-process rata-hugo--server-process
                                (get-buffer-create rata-hugo--server-buffer)
                                "hugo" "server" "-D")))
      (set-process-filter proc #'rata-hugo--browse-when-ready)
      (set-process-query-on-exit-flag proc nil)
      (message "hugo server starting in %s — the browser opens when it is listening"
               (abbreviate-file-name rata-hugo-dir)))))

;;;###autoload
(defun rata-hugo-preview-stop ()
  "Stop the Hugo preview server and drop its buffer."
  (interactive)
  (if (rata-hugo--server-live-p)
      (progn (delete-process (get-process rata-hugo--server-process))
             (when (get-buffer rata-hugo--server-buffer)
               (kill-buffer rata-hugo--server-buffer))
             (message "hugo server stopped"))
    (message "hugo server is not running")))

;;; ============================================================
;;; Package
;;; ============================================================

(use-package ox-hugo
  :after (ox general)
  :commands (org-hugo-export-wim-to-md)
  :custom
  ;; No post has to remember #+hugo_base_dir any more; one that sets it still
  ;; wins, because ox-hugo prefers the keyword.  `org-hugo-section' ("posts")
  ;; and `org-hugo-front-matter-format' ("toml") are already the ox-hugo
  ;; defaults and match the posts already on the site, so they are left alone.
  (org-hugo-base-dir rata-hugo-dir)
  (org-hugo-auto-set-lastmod t))

;;; ============================================================
;;; Keys
;;; ============================================================

;; Leader keys at top level, not in the deferred `:config' — a key written
;; there does not exist until the package loads, and for a package reached only
;; through its own binding that is never.  See FAIL-0009 / L-011.
;; `obd' is init-dialogic.el's prefix; do not collide with it.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "ob"  '(:ignore t :which-key "blog/hugo")
    "obe" '(org-hugo-export-wim-to-md :which-key "export this post")
    "obE" '(rata-blog-export-all      :which-key "export all posts")
    "obs" '(rata-blog-status          :which-key "post status")
    "obp" '(rata-hugo-preview         :which-key "preview (hugo server)")
    "obP" '(rata-hugo-preview-stop    :which-key "stop hugo server")
    "obh" '(rata-blog-add-header      :which-key "make this note a post")
    "obr" '(rata-blog-toggle-draft    :which-key "toggle draft")))

(provide 'init-blog)
