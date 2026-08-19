;;; -*- lexical-binding: t; -*-
;;; init-present.el --- Reveal.js presentation export

;; Exports org files to reveal.js slide decks via org-re-reveal (the maintained
;; fork of ox-reveal).  reveal.js itself is loaded from a CDN by default; use
;; `rata-reveal-install-local' + `rata-reveal-toggle-root' to present offline.

(eval-when-compile
  (require 'cl-lib)
  ;; Silence byte-compiler warnings for symbols owned by org-re-reveal,
  ;; simple-httpd and init-org, all of which load later or elsewhere.
  (defvar org-re-reveal-root)
  (defvar httpd-root)
  (defvar httpd-port)
  (defvar treesit-auto-install)
  (defvar rata-org-roam-dir))

(declare-function httpd-start "simple-httpd")
(declare-function httpd-running-p "simple-httpd")
(declare-function org-roam-db-query "org-roam-db")
(declare-function org-roam-capture "org-roam-capture")

;; org-re-reveal only ships ;;;###autoload cookies for its publish functions,
;; not for the three interactive exporters, so declare them here.  Doing it at
;; top level (rather than via :commands) keeps them callable before `ox' loads.
(autoload 'org-re-reveal-export-to-html "org-re-reveal" nil t)
(autoload 'org-re-reveal-export-to-html-and-browse "org-re-reveal" nil t)
(autoload 'org-re-reveal-export-current-subtree "org-re-reveal" nil t)

(defcustom rata-reveal-cdn-root "https://cdn.jsdelivr.net/npm/reveal.js@4.6.1"
  "CDN base URL for reveal.js assets.
Must be a prefix such that <root>/dist/reveal.css resolves."
  :type 'string
  :group 'rata)

(defcustom rata-reveal-local-root (expand-file-name "~/.local/share/reveal.js")
  "Local reveal.js checkout, used when presenting without a network."
  :type 'directory
  :group 'rata)

(defcustom rata-reveal-version "4.6.1"
  "Git tag of reveal.js to clone into `rata-reveal-local-root'."
  :type 'string
  :group 'rata)

(defcustom rata-reveal-deck-dir
  (or (bound-and-true-p rata-org-roam-dir)
      "~/workspace/second-brain/org-roam/")
  "Directory new decks are created in.
Defaults to the org-roam root: the roam tree is flat, so decks sit
alongside every other note rather than in a subdirectory.  They are
first-class roam nodes — IDs, `org-roam-node-find', backlinks — and are
identified as decks by `rata-reveal-deck-tag', not by their location."
  :type 'directory
  :group 'rata)

(defcustom rata-reveal-deck-tag "presentation"
  "Filetag marking an org-roam node as a reveal.js deck.
`rata-reveal-new-deck' applies it and `rata-reveal-export-all' selects on
it.  Since the roam tree is flat, this tag is the only thing distinguishing
a deck from any other note."
  :type 'string
  :group 'rata)

(defcustom rata-reveal-export-dir
  (expand-file-name "~/workspace/second-brain/presentations/")
  "Directory receiving exported HTML decks.
Deliberately *outside* `org-roam-directory' so generated .html never
lands in the note tree.  Mirrors how hugo/public/ sits beside org-roam/."
  :type 'directory
  :group 'rata)

(defvar rata-reveal--local-p nil
  "Non-nil when exports point at `rata-reveal-local-root' instead of the CDN.")

(defun rata-reveal-toggle-root ()
  "Toggle reveal.js asset source between the CDN and the local checkout."
  (interactive)
  (setq rata-reveal--local-p (not rata-reveal--local-p))
  (setq org-re-reveal-root (if rata-reveal--local-p
                               rata-reveal-local-root
                             rata-reveal-cdn-root))
  (when (and rata-reveal--local-p
             (not (file-directory-p rata-reveal-local-root)))
    (message "reveal.js not found at %s — run `rata-reveal-install-local'"
             rata-reveal-local-root))
  (message "reveal.js root: %s (%s)"
           org-re-reveal-root
           (if rata-reveal--local-p "local" "CDN")))

(defun rata-reveal-install-local ()
  "Clone or update the local reveal.js checkout at `rata-reveal-local-root'.
Runs git asynchronously; progress lands in the *reveal-install* buffer."
  (interactive)
  (unless (executable-find "git")
    (user-error "git not found in PATH"))
  (let* ((buf (get-buffer-create "*reveal-install*"))
         (args (if (file-directory-p (expand-file-name ".git" rata-reveal-local-root))
                   (list "-C" rata-reveal-local-root
                         "fetch" "--depth" "1" "origin"
                         (format "refs/tags/%s:refs/tags/%s"
                                 rata-reveal-version rata-reveal-version))
                 (list "clone" "--depth" "1"
                       "--branch" rata-reveal-version
                       "https://github.com/hakimel/reveal.js.git"
                       rata-reveal-local-root))))
    (with-current-buffer buf (erase-buffer))
    (make-process
     :name "reveal-install"
     :buffer buf
     :command (cons "git" args)
     :sentinel
     (lambda (_proc event)
       (when (string-prefix-p "finished" event)
         ;; A fetch only updates refs; check the tag out so dist/ is on disk.
         (when (file-directory-p (expand-file-name ".git" rata-reveal-local-root))
           (call-process "git" nil buf nil
                         "-C" rata-reveal-local-root
                         "checkout" "--quiet" rata-reveal-version))
         (message "reveal.js %s ready at %s"
                  rata-reveal-version rata-reveal-local-root))))
    (message "Installing reveal.js %s..." rata-reveal-version)))

(defun rata-reveal--inhibit-auto-mode (fn &rest args)
  "Run FN with automatic major-mode selection disabled.
`org-html-final-function' calls `set-auto-mode' on the exported HTML.  In
this config that activates `mhtml-mode', whose css/html submodes make
treesit-auto offer to install grammars that are not in
`treesit-language-source-alist' — a prompt in the middle of every export
\(and an outright hang in batch\).  The major mode is only used for optional
indentation via `org-html-indent', which is nil by default, so skipping mode
selection costs nothing."
  (let ((auto-mode-alist nil)
        (magic-mode-alist nil)
        (magic-fallback-mode-alist nil))
    (apply fn args)))

(defun rata-reveal--inhibit-grammar-prompt (fn &rest args)
  "Run FN without treesit-auto's missing-grammar prompt.
`org-html-fontify-code' activates a language major mode in a temp buffer to
colourise src blocks.  With `treesit-auto-install' set to `prompt' that asks
whether to install a grammar in the middle of every export, for each language
whose grammar is absent.  Font-locking falls back to the non-tree-sitter mode,
which htmlize renders fine, so suppressing the prompt only loses the offer."
  (let ((treesit-auto-install nil))
    (apply fn args)))

(with-eval-after-load 'ox-html
  (advice-add 'org-html-final-function :around #'rata-reveal--inhibit-auto-mode)
  (advice-add 'org-html-fontify-code :around #'rata-reveal--inhibit-grammar-prompt))

(defun rata-reveal--export (fn)
  "Call export command FN with output redirected to `rata-reveal-export-dir'.
`org-export-output-file-name' documents its PUB-DIR argument as taking
precedence over any other path, so shadowing it is enough to relocate the
output without touching the deck source."
  (let ((dir (file-name-as-directory (expand-file-name rata-reveal-export-dir))))
    (make-directory dir t)
    (cl-letf* ((orig (symbol-function 'org-export-output-file-name))
               ((symbol-function 'org-export-output-file-name)
                (lambda (extension &optional subtreep pub-dir)
                  (funcall orig extension subtreep (or pub-dir dir)))))
      (funcall fn))
    dir))

(defun rata-reveal-export-deck ()
  "Export the current deck to `rata-reveal-export-dir'."
  (interactive)
  (let ((dir (rata-reveal--export #'org-re-reveal-export-to-html)))
    (message "Exported to %s" dir)))

(defun rata-reveal-export-deck-and-browse ()
  "Export the current deck to `rata-reveal-export-dir' and open it."
  (interactive)
  (rata-reveal--export #'org-re-reveal-export-to-html)
  (browse-url (expand-file-name (concat (file-name-base (buffer-file-name)) ".html")
                                rata-reveal-export-dir)))

(defun rata-reveal-export-subtree ()
  "Export the subtree at point to `rata-reveal-export-dir'.
Useful for turning one section of a roam note into a deck without
copying it out first."
  (interactive)
  (rata-reveal--export #'org-re-reveal-export-current-subtree))

(defconst rata-reveal-header-lines
  '("#+OPTIONS: toc:nil num:nil timestamp:nil"
    "#+REVEAL_THEME: night"
    "#+REVEAL_TRANS: slide"
    "#+REVEAL_INIT_OPTIONS: width:1280, height:800, hash:true, slideNumber:\"c/t\""
    "#+REVEAL_PLUGINS: (notes)")
  "Keyword lines `rata-reveal-add-header' adds to make a note a deck.")

(defun rata-reveal--goto-header-end ()
  "Move point past the note's leading property drawer and #+keyword: block."
  (goto-char (point-min))
  (when (looking-at "^:PROPERTIES:")
    (re-search-forward "^:END:" nil t)
    (forward-line 1))
  (while (looking-at "^#\\+[A-Za-z_]+:")
    (forward-line 1))
  (point))

(defun rata-reveal-add-header ()
  "Turn the current org note into a reveal.js deck, in place.
Adds `rata-reveal-deck-tag' to #+filetags: and inserts any missing #+REVEAL_*
keywords, leaving the note's own content untouched.  Safe to run twice.  This
is the counterpart to the \"presentation\" org-roam capture template: use the
template for a new deck, this for a note that already exists.  Mirrors
`rata-toggle-hastodo-filetag' in init-org.el."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not an org buffer"))
  (save-excursion
    ;; 1. the deck tag, appended to #+filetags: or added as a new line
    (goto-char (point-min))
    (if (re-search-forward "^#\\+filetags:.*$" nil t)
        (unless (string-match-p (concat ":" (regexp-quote rata-reveal-deck-tag) ":")
                                (match-string 0))
          (goto-char (match-end 0))
          (unless (eq (char-before) ?:) (insert ":"))
          (insert rata-reveal-deck-tag ":"))
      (rata-reveal--goto-header-end)
      (insert "#+filetags: :" rata-reveal-deck-tag ":\n"))
    ;; 2. the reveal keywords, skipping any the note already sets
    (dolist (line rata-reveal-header-lines)
      (let ((keyword (car (split-string line ":"))))
        (goto-char (point-min))
        (unless (re-search-forward (concat "^" (regexp-quote keyword) ":") nil t)
          (rata-reveal--goto-header-end)
          (insert line "\n")))))
  (message "Deck header added — save, then export with SPC o p p"))

(defun rata-reveal-capture-deck ()
  "Create a new deck through the org-roam \"presentation\" capture template.
Thin wrapper so the deck template has a leader key of its own; it is the same
template reachable via `org-roam-capture' (SPC o r c) with key \"r\"."
  (interactive)
  (require 'org-roam)
  (org-roam-capture nil "r"))

(defun rata-reveal-deck-files ()
  "Return org-roam files tagged with `rata-reveal-deck-tag'.
Mirrors `rata-org-roam-agenda-files' in init-org.el.  A directory-based
lookup is not an option here: the roam tree is flat, so decks live among
~1600 other notes and only the tag tells them apart."
  (when (fboundp 'org-roam-db-query)
    (mapcar #'car
            (org-roam-db-query
             [:select [nodes:file]
                      :from tags
                      :left-join nodes
                      :on (= tags:node-id nodes:id)
                      :where (= tags:tag $s1)
                      :group-by nodes:file]
             rata-reveal-deck-tag))))

(defun rata-reveal-export-all ()
  "Export every note tagged `rata-reveal-deck-tag' to `rata-reveal-export-dir'."
  (interactive)
  (require 'org-re-reveal)
  (let ((files (rata-reveal-deck-files))
        (count 0))
    (unless files
      (user-error "No notes tagged :%s: — tag a deck or create one with `rata-reveal-new-deck'"
                  rata-reveal-deck-tag))
    (dolist (file files)
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (rata-reveal--export #'org-re-reveal-export-to-html)
          (setq count (1+ count)))))
    (message "Exported %d deck(s) to %s" count rata-reveal-export-dir)))

(defun rata-reveal-serve ()
  "Serve `rata-reveal-export-dir' over HTTP and open the current deck.
Speaker notes and plugin loading misbehave over `file://', so present from here."
  (interactive)
  (require 'simple-httpd)
  (let* ((dir (file-name-as-directory (expand-file-name rata-reveal-export-dir)))
         (html (and buffer-file-name
                    (concat (file-name-base buffer-file-name) ".html"))))
    (setq httpd-root dir)
    (unless (httpd-running-p) (httpd-start))
    (unless (and html (file-exists-p (expand-file-name html dir)))
      (message "No exported deck yet — export with SPC o p e first"))
    (browse-url (format "http://localhost:%d/%s" httpd-port (or html "")))))

(use-package org-re-reveal
  :after (ox general)
  :custom
  ;; org-re-reveal understands "3.8", "4" and "6"; "4" is the right layout for
  ;; reveal.js 4.x and 5.x (dist/ + plugin/).  Keep in sync with the pinned
  ;; `rata-reveal-version' if you bump it.
  (org-re-reveal-revealjs-version "4")
  (org-re-reveal-root rata-reveal-cdn-root)
  (org-re-reveal-theme "night")
  (org-re-reveal-transition "slide")
  (org-re-reveal-title-slide 'auto)
  (org-re-reveal-plugins '(notes))
  (org-re-reveal-klipsify-src nil))

;; Keybindings deliberately live OUTSIDE the use-package above: that block is
;; `:after (ox general)', and `ox' does not load until something exports, so a
;; `:config' binding here would stay dead until the first manual `C-c C-e'.
;; general is already loaded (init-evil calls `elpaca-wait'), and every command
;; below is either defined in this file or autoloaded at its top, so binding
;; them eagerly is safe.
(rata-leader
  :states '(normal visual)
  "op"  '(:ignore t :which-key "presentation")
  "opn" '(rata-reveal-capture-deck            :which-key "new deck (roam capture)")
  "opa" '(rata-reveal-add-header              :which-key "add deck header to this note")
  "opp" '(rata-reveal-export-deck-and-browse :which-key "export + browse")
  "ope" '(rata-reveal-export-deck            :which-key "export to html")
  "ops" '(rata-reveal-export-subtree         :which-key "export subtree")
  "opP" '(rata-reveal-export-all             :which-key "export all tagged decks")
  "oph" '(org-re-reveal-export-to-html       :which-key "export here (beside source)")
  "opv" '(rata-reveal-serve                  :which-key "serve decks locally")
  "opr" '(rata-reveal-toggle-root            :which-key "toggle CDN/local root")
  "opi" '(rata-reveal-install-local          :which-key "install local reveal.js"))

;; Syntax highlighting for src blocks in HTML/reveal output.
(use-package htmlize
  :after ox
  :defer t)

(provide 'init-present)
