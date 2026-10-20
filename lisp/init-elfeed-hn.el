;;; -*- lexical-binding: t; -*-
;;; init-elfeed-hn.el --- Aggregator stories and comments inside elfeed

;; An entry from an aggregator carries no article: Hacker News writes the
;; single word "Comments" (hnrss a list of URLs), Lobsters writes the same one
;; link.  This module teaches elfeed's own entry buffer to show what the entry
;; is about -- the story, a readable copy of the linked article, and the whole
;; comment thread -- through `elfeed-show-update-hook'.  It owns no package:
;; `rata-net-retrieve', `json-parse-string' and `shr' do the work.  Plan and
;; design: plans/hackernews-reader.md.
;;
;; Two sites, one renderer.  Everything site-specific -- how an entry is
;; recognised, where the thread comes from, how that reply becomes the thread
;; plist, what a permalink looks like -- is a row of `rata-elfeed-hn--sources',
;; and nothing after that table mentions either site.  The file and its symbols
;; keep the `hn' name they were born with; Lobsters came second (2026-10-20).
;;
;; Three rules hold the async part together, the same ones the claude-loop
;; follows at a larger size:
;;
;; - `rata-net-retrieve' (init-net.el) is the only function that touches the
;;   network, so the tests replace exactly one function.  It fetches with curl,
;;   and that is not a detail: url.el cannot reach a host that publishes an
;;   AAAA record from a network with no IPv6 route (FAIL-0024).
;; - Every reply is delivered from a zero-delay timer, never from inside
;;   url.el's process callback, and an error in it becomes a result, not a
;;   signal: a signal there is demoted to a *Messages* line nobody reads.
;; - A reply is drawn only if its buffer is live and still shows the entry it
;;   was fetched for under the same generation (`rata-elfeed-hn--generation',
;;   bumped on every redraw), so `n'/`p' or `g' before it arrives make it a
;;   no-op rather than comments drawn under the wrong story.

(require 'cl-lib)
(require 'subr-x)
(require 'init-net)

(declare-function elfeed-deref "elfeed-db" (ref))
(declare-function elfeed-entry-content "elfeed-db" (entry))
(declare-function elfeed-entry-link "elfeed-db" (entry))
(declare-function elfeed-show-refresh "elfeed-show" (&rest _))
(declare-function elfeed-entry-title "elfeed-db" (entry))
(declare-function shr-insert-document "shr" (dom))
(declare-function shr-replace-image "shr" (data start end &optional flags))
(declare-function eww-readable-dom "eww" (dom))
(declare-function dom-texts "dom" (node &optional separator))
(declare-function url-host "url-parse" (cl-x))
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function rata-leader "init-evil" (&rest args))

(defgroup rata-elfeed-hn nil
  "Aggregator stories and comments in elfeed's entry buffer."
  :group 'rata)

(defcustom rata-elfeed-hn-api-url "https://hn.algolia.com/api/v1/items/"
  "Algolia HN item endpoint; the item id is appended.
One request returns the story and its whole comment tree, however big."
  :type 'string)

(defcustom rata-elfeed-hn-lobsters-url "https://lobste.rs/"
  "Base URL of the Lobsters instance.
One request to s/ID.json returns the story and every comment, flat,
each carrying its own depth."
  :type 'string)

;; Fetching moved to init-net.el when plain elfeed entries turned out to need
;; the same curl path (FAIL-0027); the old names still work from custom.el.
(define-obsolete-variable-alias 'rata-elfeed-hn-timeout 'rata-net-timeout "2026-10-20")
(define-obsolete-variable-alias 'rata-elfeed-hn-curl-program 'rata-net-curl-program "2026-10-20")
(define-obsolete-variable-alias 'rata-elfeed-hn-max-images 'rata-net-max-images "2026-10-20")
(define-obsolete-variable-alias 'rata-elfeed-hn-image-max-bytes 'rata-net-image-max-bytes "2026-10-20")

(defconst rata-elfeed-hn--sources
  '((hn
     :name "HN"
     :label "Hacker News"
     :numeric-id t
     :item-url-regexp
     "\\`https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)\\'"
     :content-regexps
     (;; news.ycombinator.com/rss: the whole content is this one link.
      "href=\"https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)\"[^>]*>Comments</a>"
      ;; hnrss.org: "Comments URL: <a href=...>", plain text in older entries.
      "Comments URL:[ \t]*\\(?:<a href=\"\\)?https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)")
     :api rata-elfeed-hn--hn-api-url
     :thread rata-elfeed-hn--thread-from-algolia
     :item-url rata-elfeed-hn--hn-item-url
     :comment-url rata-elfeed-hn--hn-item-url)
    (lobsters
     :name "Lobsters"
     :label "Lobsters"
     :numeric-id nil
     ;; A story URL is /s/ID or /s/ID/slug; the slug is decoration.
     :item-url-regexp "\\`https?://lobste\\.rs/s/\\([A-Za-z0-9]+\\)\\(?:/[^ \t\n]*\\)?\\'"
     :content-regexps
     (;; lobste.rs/rss on a link story: the whole content is this one link.
      "href=\"https?://lobste\\.rs/s/\\([A-Za-z0-9]+\\)[^\"]*\"[^>]*>Comments</a>")
     :api rata-elfeed-hn--lobsters-api-url
     :thread rata-elfeed-hn--thread-from-lobsters
     :item-url rata-elfeed-hn--lobsters-item-url
     :comment-url rata-elfeed-hn--lobsters-comment-url))
  "The aggregators this module reads, as (SOURCE . PLIST).

Everything that differs between Hacker News and Lobsters is here:
how an entry is recognised, where the thread is fetched, how that
reply becomes the thread plist both are drawn from, and what a
permalink looks like.  Nothing below this table mentions either site.

`:content-regexps' are anchored on the shape each feed writes rather
than on any item URL, so a blog post that merely links to a discussion
is not taken for one.  Group 1 is the id in every regexp, including
`:item-url-regexp'.  `:numeric-id' says whether that id is a number
\(HN) or a string (Lobsters' base-36 short id).

The `hn' in this file's symbols is where it started, not what it
covers; renaming 900 lines and their tests would be churn.")

(defun rata-elfeed-hn--spec (source &optional prop)
  "Return SOURCE's entry in `rata-elfeed-hn--sources', or its PROP."
  (let ((spec (alist-get source rata-elfeed-hn--sources)))
    (if prop (plist-get spec prop) spec)))

(defun rata-elfeed-hn--prop (item prop)
  "Return PROP of the source of ITEM, a (SOURCE . ID) cons."
  (rata-elfeed-hn--spec (car-safe item) prop))

(defun rata-elfeed-hn--make-item (source id-string)
  "Return the (SOURCE . ID) cons for the matched ID-STRING."
  (cons source (if (rata-elfeed-hn--spec source :numeric-id)
                   (string-to-number id-string)
                 id-string)))

(defun rata-elfeed-hn-item (content link)
  "Return (SOURCE . ID) for an entry with CONTENT and LINK, or nil.
Pure.  LINK wins when it is itself an item URL (an Ask HN entry, a
Lobsters text post); otherwise CONTENT is searched for the shape each
feed writes."
  (or (and (stringp link)
           (cl-loop for (source . spec) in rata-elfeed-hn--sources
                    when (string-match (plist-get spec :item-url-regexp) link)
                    return (rata-elfeed-hn--make-item source (match-string 1 link))))
      (and (stringp content)
           (cl-loop for (source . spec) in rata-elfeed-hn--sources
                    thereis (cl-loop for re in (plist-get spec :content-regexps)
                                     when (string-match re content)
                                     return (rata-elfeed-hn--make-item
                                             source (match-string 1 content)))))))

(defun rata-elfeed-hn--hn-api-url (id)
  "Return the Algolia URL for HN item ID."
  (concat rata-elfeed-hn-api-url (number-to-string id)))

(defun rata-elfeed-hn--hn-item-url (id)
  "Return the HN permalink of item or comment ID."
  (format "https://news.ycombinator.com/item?id=%s" id))

(defun rata-elfeed-hn--lobsters-api-url (id)
  "Return the Lobsters JSON URL for story ID."
  (concat rata-elfeed-hn-lobsters-url "s/" id ".json"))

(defun rata-elfeed-hn--lobsters-item-url (id)
  "Return the Lobsters permalink of story ID."
  (concat rata-elfeed-hn-lobsters-url "s/" id))

(defun rata-elfeed-hn--lobsters-comment-url (id)
  "Return the Lobsters permalink of comment ID.
A comment has its own short id, on /c/ rather than /s/."
  (concat rata-elfeed-hn-lobsters-url "c/" id))

(defun rata-elfeed-hn--item-url-p (url)
  "Non-nil when URL is some source's item URL."
  (and (stringp url)
       (cl-loop for (_source . spec) in rata-elfeed-hn--sources
                thereis (string-match-p (plist-get spec :item-url-regexp) url))))

;;; ------------------------------------------------------------
;;; Network -- one function, results not signals
;;; ------------------------------------------------------------

(eval-when-compile
  ;; Let-bound below; declared special so that binding them before shr or
  ;; browse-url has loaded is still a dynamic binding, not a lexical one.
  (defvar shr-width)
  (defvar shr-max-width)
  (defvar shr-base)
  (defvar browse-url-handlers))

(defun rata-elfeed-hn--fetch-json (item callback)
  "Fetch ITEM's thread; call CALLBACK with (:ok JSON) or (:error REASON).
ITEM is a (SOURCE . ID) cons; its source says which endpoint to ask.
JSON is parsed with objects as alists and null as nil."
  (rata-net-retrieve
   (funcall (rata-elfeed-hn--prop item :api) (cdr item))
   ;; No cap: a few thousand comments is legitimately several megabytes.
   nil
   (lambda (result)
     (funcall callback
              (if (plist-get result :error)
                  result
                (condition-case err
                    (list :ok (json-parse-string (plist-get result :body)
                                                 :object-type 'alist
                                                 :array-type 'list
                                                 :null-object nil
                                                 :false-object nil))
                  (error (list :error (format "bad reply: %s"
                                              (error-message-string err))))))))))

;;; ------------------------------------------------------------
;;; Parsing -- pure
;;; ------------------------------------------------------------

(defun rata-elfeed-hn--comment-from-algolia (node depth)
  "Return the comment plist for Algolia NODE at DEPTH, or nil to drop it.
A comment with no author or no text is deleted or dead.  It is dropped,
unless it has live replies: then it stays as a `:deleted' placeholder so
the replies keep their parent."
  (when (equal (alist-get 'type node) "comment")
    (let* ((children (delq nil (mapcar (lambda (c)
                                         (rata-elfeed-hn--comment-from-algolia c (1+ depth)))
                                       (alist-get 'children node))))
           (deleted (not (and (alist-get 'author node) (alist-get 'text node)))))
      (unless (and deleted (null children))
        (list :id (alist-get 'id node)
              :author (alist-get 'author node)
              :time (alist-get 'created_at_i node)
              :text (alist-get 'text node)
              :depth depth
              :deleted deleted
              :children children
              :replies (cl-loop for c in children
                                sum (+ (if (plist-get c :deleted) 0 1)
                                       (plist-get c :replies))))))))

(defun rata-elfeed-hn--thread-from-algolia (json)
  "Return the story plist for the Algolia item JSON.
This and `rata-elfeed-hn--thread-from-lobsters' are the two shapes the
rest of the module never sees: everything below draws the plist.
Keys: :id :title :url :author :points :time :text, :comments (the
top-level comment plists, in order) and :count (live comments in the
whole tree; deleted placeholders are not counted)."
  (let ((comments (delq nil (mapcar (lambda (c) (rata-elfeed-hn--comment-from-algolia c 0))
                                    (alist-get 'children json)))))
    (list :id (alist-get 'id json)
          :title (alist-get 'title json)
          :url (alist-get 'url json)
          :author (alist-get 'author json)
          :points (alist-get 'points json)
          :time (alist-get 'created_at_i json)
          :text (alist-get 'text json)
          :comments comments
          :count (cl-loop for c in comments
                          sum (+ (if (plist-get c :deleted) 0 1)
                                 (plist-get c :replies))))))

(defun rata-elfeed-hn--lobsters-time (string)
  "Return the epoch seconds of Lobsters timestamp STRING, or nil.
Pure.  Lobsters writes RFC 3339 with an offset; a reply that does not
parse costs an age, not the comment."
  (when (stringp string)
    (ignore-errors (float-time (date-to-time string)))))

(defun rata-elfeed-hn--lobsters-comment (node depth)
  "Return the comment plist for Lobsters NODE at DEPTH, with no children yet.
Pure.  A deleted or moderated comment keeps its place -- its replies
hang off it -- but carries no author and no text."
  (let ((deleted (or (eq t (alist-get 'is_deleted node))
                     (eq t (alist-get 'is_moderated node))
                     (null (alist-get 'commenting_user node)))))
    (list :id (alist-get 'short_id node)
          :author (unless deleted (alist-get 'commenting_user node))
          :time (rata-elfeed-hn--lobsters-time (alist-get 'created_at node))
          :text (unless deleted (alist-get 'comment node))
          :depth depth
          :deleted deleted
          :children nil
          :replies 0)))

(defun rata-elfeed-hn--lobsters-tree (comments)
  "Return Lobsters COMMENTS, a flat depth-ordered list, as a comment tree.
Pure.  Lobsters sends the thread in reading order with a `depth' on
each comment instead of nesting, so the nesting is rebuilt from the
depth sequence: a comment deeper than the one before it is its reply.
A depth that jumps by more than one is clamped to one level deeper,
because a gap would otherwise silently drop the comment and its
replies.  Returns the top-level comments, each with `:children' and
the `:replies' count the renderer folds on."
  (let ((roots nil)
        (stack nil))                    ; innermost first: (DEPTH . COMMENT)
    (dolist (node comments)
      (let* ((raw (or (alist-get 'depth node) 0))
             (want (if (numberp raw) raw (string-to-number (format "%s" raw))))
             ;; Clamp against the comment before it, which is the head of the
             ;; stack until the loop below pops back to this one's parent.
             (depth (min (max want 0) (if stack (1+ (caar stack)) 0))))
        (while (and stack (>= (caar stack) depth))
          (pop stack))
        (let ((comment (rata-elfeed-hn--lobsters-comment node depth)))
          (if-let* ((parent (cdar stack)))
              ;; `:children' is in every comment from the start, so this
              ;; `plist-put' writes through the parent the tree already holds.
              (plist-put parent :children
                         (append (plist-get parent :children) (list comment)))
            (push comment roots))
          (push (cons depth comment) stack))))
    (let ((tops (nreverse roots)))
      (mapc #'rata-elfeed-hn--count-replies tops)
      tops)))

(defun rata-elfeed-hn--count-replies (comment)
  "Set COMMENT's `:replies' from its children, depth first.  Returns it."
  (let ((children (plist-get comment :children)))
    (mapc #'rata-elfeed-hn--count-replies children)
    (plist-put comment :replies
               (cl-loop for c in children
                        sum (+ (if (plist-get c :deleted) 0 1)
                               (plist-get c :replies))))))

(defun rata-elfeed-hn--thread-from-lobsters (json)
  "Return the story plist for a Lobsters s/ID.json reply JSON.
The same keys `rata-elfeed-hn--thread-from-algolia' returns, so nothing
downstream knows which site it is looking at.  A Lobsters text post has
`url' as the empty string rather than absent; that is a text post, not
an article at \"\"."
  (let* ((comments (rata-elfeed-hn--lobsters-tree (alist-get 'comments json)))
         (url (alist-get 'url json)))
    (list :id (alist-get 'short_id json)
          :title (alist-get 'title json)
          :url (unless (or (null url) (string-empty-p url)) url)
          :author (alist-get 'submitter_user json)
          :points (alist-get 'score json)
          :time (rata-elfeed-hn--lobsters-time (alist-get 'created_at json))
          :text (alist-get 'description json)
          :comments comments
          :count (cl-loop for c in comments
                          sum (+ (if (plist-get c :deleted) 0 1)
                                 (plist-get c :replies))))))

;;; ------------------------------------------------------------
;;; Fetching a thread
;;; ------------------------------------------------------------

(defvar rata-elfeed-hn--cache (make-hash-table :test 'equal)
  "Parsed threads by (SOURCE . ID), for this session.")

(defun rata-elfeed-hn--fetch-thread (item force callback)
  "Call CALLBACK with (:ok THREAD) or (:error REASON) for ITEM.
ITEM is a (SOURCE . ID) cons.  A cached thread is answered from a timer
too, so callers never see a synchronous reply; FORCE skips the cache."
  (let ((cached (and (not force) (gethash item rata-elfeed-hn--cache))))
    (if cached
        (run-at-time 0 nil callback (list :ok cached))
      (rata-elfeed-hn--fetch-json
       item
       (lambda (result)
         (funcall callback
                  (if (plist-get result :error)
                      result
                    (condition-case err
                        (let ((thread (funcall (rata-elfeed-hn--prop item :thread)
                                               (plist-get result :ok))))
                          (puthash item thread rata-elfeed-hn--cache)
                          (list :ok thread))
                      (error (list :error (format "bad thread: %s"
                                                  (error-message-string err))))))))))))

;;; ------------------------------------------------------------
;;; The generation guard
;;; ------------------------------------------------------------

(defvar-local rata-elfeed-hn--generation 0
  "Bumped on every redraw of the buffer; a reply from an older one is stale.")

(defvar-local rata-elfeed-hn--key nil
  "What the buffer shows: the elfeed entry, or the item id in an *HN* buffer.")

(defun rata-elfeed-hn--guard (buffer fn)
  "Return a callback that runs FN in BUFFER only while it is current.
Current means BUFFER is live, still shows what it showed when the guard
was made (`rata-elfeed-hn--key'), and has not been redrawn since
\=(`rata-elfeed-hn--generation').  Otherwise the callback is a no-op.
An error in FN is reported with `message' and never signalled."
  (let ((generation (buffer-local-value 'rata-elfeed-hn--generation buffer))
        (key (buffer-local-value 'rata-elfeed-hn--key buffer)))
    (lambda (&rest args)
      (when (and (buffer-live-p buffer)
                 (eq (buffer-local-value 'rata-elfeed-hn--key buffer) key)
                 (= (buffer-local-value 'rata-elfeed-hn--generation buffer)
                    generation))
        (with-current-buffer buffer
          (condition-case err
              (apply fn args)
            (error (message "elfeed-hn: %s" (error-message-string err)))))))))

;;; ------------------------------------------------------------
;;; Rendering into elfeed's entry buffer
;;; ------------------------------------------------------------

(defcustom rata-elfeed-hn-auto t
  "Non-nil: fetch the thread when an aggregator entry is opened.
Nil: only on \\`, c' (`rata-elfeed-hn-refetch')."
  :type 'boolean)

(defcustom rata-elfeed-hn-fold-threshold 300
  "Threads with more comments than this open with every reply folded.
Top-level comments stay visible, so a huge thread draws as a table of
contents."
  :type 'integer)

(defface rata-elfeed-hn-author '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a comment's author.")

(defface rata-elfeed-hn-op '((t :inherit font-lock-string-face :weight bold))
  "Face for a comment by the story's own author.")

(defface rata-elfeed-hn-meta '((t :inherit shadow))
  "Face for ages, counts and status lines.")

(defface rata-elfeed-hn-heading '((t :inherit bold :height 1.1))
  "Face for the thread heading.")

(defconst rata-elfeed-hn--gutter-faces
  '(font-lock-keyword-face font-lock-string-face font-lock-type-face
    font-lock-constant-face font-lock-function-name-face font-lock-variable-name-face)
  "Faces cycled through for the gutter bar of each depth.")

(defvar-local rata-elfeed-hn--item nil
  "The (SOURCE . ID) the buffer shows, or nil when it shows no thread.")

(defvar rata-elfeed-hn--force nil
  "Non-nil while a redraw should bypass the session cache.")

(defun rata-elfeed-hn--entry-item (entry)
  "Return the (SOURCE . ID) of elfeed ENTRY, or nil."
  (when entry
    (let ((content (elfeed-deref (elfeed-entry-content entry))))
      (rata-elfeed-hn-item (and (stringp content) content)
                           (elfeed-entry-link entry)))))

(defun rata-elfeed-hn--age (time now)
  "Return how long before NOW the epoch second TIME was, as \"3h ago\"."
  (if (not (numberp time))
      "?"
    (let ((s (max 0 (- now time))))
      (cond ((< s 3600) (format "%dm ago" (/ s 60)))
            ((< s 86400) (format "%dh ago" (/ s 3600)))
            ((< s (* 86400 30)) (format "%dd ago" (/ s 86400)))
            ((< s (* 86400 365)) (format "%dmo ago" (/ s (* 86400 30))))
            (t (format "%dy ago" (/ s (* 86400 365))))))))

(defun rata-elfeed-hn--plural (n word)
  "Return \"N WORD\" with WORD pluralised by an s unless N is 1."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun rata-elfeed-hn--width ()
  "Return the text width to render at in the current buffer."
  (let ((win (get-buffer-window (current-buffer))))
    (max 40 (min 100 (- (if win (window-body-width win) 80) 2)))))

(defun rata-elfeed-hn--gutter (depth)
  "Return the gutter string for a comment at DEPTH: one coloured bar per level."
  (mapconcat (lambda (d)
               (propertize "│ " 'face (nth (mod d (length rata-elfeed-hn--gutter-faces))
                                           rata-elfeed-hn--gutter-faces)))
             (number-sequence 0 (1- depth))
             ""))

(defun rata-elfeed-hn--parse-html (html)
  "Return the libxml DOM for the string HTML."
  (with-temp-buffer
    (insert html)
    (libxml-parse-html-region (point-min) (point-max))))

(defun rata-elfeed-hn--image-guard ()
  "Return the image guard for the current buffer, for `init-net'.
The same staleness rule as every other reply here: an image drawn into
the entry buffer after it has moved on to another story is worse than
no image at all."
  (let ((buffer (current-buffer)))
    (lambda (fn) (rata-elfeed-hn--guard buffer fn))))

(defun rata-elfeed-hn--insert-dom (dom width &optional base)
  "Insert DOM at point, rendered by `shr' to WIDTH columns.
BASE is the URL relative links and images resolve against.

The images go through `rata-net-with-shr-images' rather than shr's own
`url-queue-retrieve': url.el stalls on an unrouted IPv6 address exactly
as articles did (FAIL-0024), and gives up after `url-queue-timeout'."
  (require 'shr)
  (let ((shr-width width)
        (shr-max-width nil))
    (rata-net-with-shr-images (rata-elfeed-hn--image-guard)
      ;; `shr-insert-document' binds `shr-base' to nil and takes the base
      ;; only from a <base> element, so binding it around the call does
      ;; nothing: relative images and links stayed relative.
      (shr-insert-document (if base `(base ((href . ,base)) ,dom) dom))
      (unless (bolp) (insert "\n")))))

(defun rata-elfeed-hn--insert-html (html width)
  "Insert HTML at point, rendered by `shr' to WIDTH columns.
Comment and post text only ever goes through here: it is parsed as HTML
and drawn as text, so nothing in it is evaluated or read as Org or Lisp."
  (rata-elfeed-hn--insert-dom (rata-elfeed-hn--parse-html html) width))

(defun rata-elfeed-hn--section-bounds (name)
  "Return (START . END) of section NAME in the current buffer, or nil."
  (when-let* ((start (text-property-any (point-min) (point-max)
                                        'rata-elfeed-hn-section name)))
    (cons start (or (next-single-property-change start 'rata-elfeed-hn-section)
                    (point-max)))))

(defun rata-elfeed-hn--draw-section (name inserter)
  "Replace section NAME with what INSERTER inserts at point.
A section not yet in the buffer is appended.  A section is never left
empty -- an empty one could not be found again to replace."
  (let ((inhibit-read-only t)
        (bounds (rata-elfeed-hn--section-bounds name)))
    (save-excursion
      (if bounds
          (progn (delete-region (car bounds) (cdr bounds))
                 (goto-char (car bounds)))
        (goto-char (point-max)))
      (let ((start (point)))
        (funcall inserter)
        (when (= (point) start) (insert "\n"))
        (put-text-property start (point) 'rata-elfeed-hn-section name)))))

(defun rata-elfeed-hn--insert-rule ()
  "Insert a blank line and a horizontal rule."
  (insert "\n" (propertize (make-string (rata-elfeed-hn--width) ?─)
                           'face 'rata-elfeed-hn-meta)
          "\n"))

(defun rata-elfeed-hn--insert-status (text)
  "Insert the comments section as a single status line saying TEXT."
  (rata-elfeed-hn--insert-rule)
  (insert (propertize (concat "Comments: " text) 'face 'rata-elfeed-hn-meta) "\n"))

(defun rata-elfeed-hn--insert-comment (comment width now op)
  "Insert COMMENT and its replies, at most WIDTH columns wide.
NOW is the current epoch second; OP is the story's author.  The block
carries `rata-elfeed-hn-depth' and `rata-elfeed-hn-id', which folding and
navigation read, and a `line-prefix' gutter so copied text stays clean."
  (let* ((depth (plist-get comment :depth))
         (author (plist-get comment :author))
         (replies (plist-get comment :replies))
         (gutter (rata-elfeed-hn--gutter depth))
         (start (point)))
    (insert (if (plist-get comment :deleted)
                (propertize "[deleted]" 'face 'rata-elfeed-hn-meta)
              (propertize author 'face (if (equal author op)
                                           'rata-elfeed-hn-op
                                         'rata-elfeed-hn-author)))
            (propertize (concat " · " (rata-elfeed-hn--age (plist-get comment :time) now)
                                (if (> replies 0)
                                    (concat " · " (if (= replies 1)
                                                      "1 reply"
                                                    (format "%d replies" replies)))
                                  ""))
                        'face 'rata-elfeed-hn-meta)
            "\n")
    (unless (plist-get comment :deleted)
      (rata-elfeed-hn--insert-html (plist-get comment :text)
                                   (max 20 (- width (* 2 depth)))))
    (insert "\n")
    (add-text-properties start (point)
                         (list 'rata-elfeed-hn-depth depth
                               'rata-elfeed-hn-id (plist-get comment :id)
                               'line-prefix gutter
                               'wrap-prefix gutter))
    (dolist (child (plist-get comment :children))
      (rata-elfeed-hn--insert-comment child width now op))))

(defun rata-elfeed-hn--insert-thread (thread)
  "Insert the comments section for THREAD: a heading, then every comment."
  (rata-elfeed-hn--insert-rule)
  (insert (propertize (format "%s · %s"
                              (rata-elfeed-hn--plural (plist-get thread :count) "comment")
                              (rata-elfeed-hn--plural (or (plist-get thread :points) 0) "point"))
                      'face 'rata-elfeed-hn-heading)
          "\n\n")
  (if (null (plist-get thread :comments))
      (insert (propertize "No comments yet.\n" 'face 'rata-elfeed-hn-meta))
    (let ((width (rata-elfeed-hn--width))
          (now (float-time)))
      (dolist (comment (plist-get thread :comments))
        (rata-elfeed-hn--insert-comment comment width now (plist-get thread :author))))))

;;; ------------------------------------------------------------
;;; The story and the article
;;; ------------------------------------------------------------

(defcustom rata-elfeed-hn-fetch-article t
  "Non-nil: fetch the linked article and show a readable copy above the thread.
This contacts the article's own site, as opening it in a browser would."
  :type 'boolean)

(defcustom rata-elfeed-hn-article-max-bytes (* 2 1024 1024)
  "Largest article page fetched, in bytes; a bigger one is not shown."
  :type 'integer)

(defcustom rata-elfeed-hn-readable-min-chars 200
  "Shortest readable text that counts as an article.
A cookie wall or a JavaScript-only page \"succeeds\" with one sentence."
  :type 'integer)

(defface rata-elfeed-hn-title '((t :inherit elfeed-show-title-face :weight bold :height 1.2))
  "Face for the story title.")

(defvar rata-elfeed-hn--article-cache (make-hash-table :test 'equal)
  "Readable article DOMs by URL, for this session.  Failures are not cached.")

(defvar-local rata-elfeed-hn--title nil
  "The story title known before the thread arrives (the elfeed entry's).")

(defvar-local rata-elfeed-hn--article-url nil
  "The URL of the article the story links to, or nil for a text post.")

(defvar-local rata-elfeed-hn--article-started nil
  "Non-nil once the article section has been decided for this drawing.")

(defun rata-elfeed-hn--domain (url)
  "Return URL's host without a leading www., or nil."
  (when (stringp url)
    (require 'url-parse)
    (when-let* ((host (url-host (url-generic-parse-url url))))
      (string-remove-prefix "www." host))))

(defun rata-elfeed-hn--readable-text (html)
  "Return the readable main-text DOM of the page HTML, or nil.
Pure.  This is eww's reader view (`eww-readable-dom', what \\`R' does in
eww); a result shorter than `rata-elfeed-hn-readable-min-chars' is nil."
  (require 'eww)
  (require 'dom)
  (condition-case nil
      (when-let* ((dom (eww-readable-dom (rata-elfeed-hn--parse-html html))))
        (when (>= (length (string-trim (replace-regexp-in-string
                                        "[ \t\n\r]+" " " (dom-texts dom))))
                  rata-elfeed-hn-readable-min-chars)
          dom))
    (error nil)))

(defun rata-elfeed-hn--fetch-article (url force callback)
  "Call CALLBACK with (:ok DOM) or (:error REASON) for the article at URL.
Only an HTML reply under `rata-elfeed-hn-article-max-bytes' with enough
readable text succeeds.  FORCE skips the cache."
  (let ((cached (and (not force) (gethash url rata-elfeed-hn--article-cache))))
    (if cached
        (run-at-time 0 nil callback (list :ok cached))
      (rata-net-retrieve
       url rata-elfeed-hn-article-max-bytes
       (lambda (result)
         (funcall callback
                  (let ((type (plist-get result :type)))
                    (cond
                     ((plist-get result :error) result)
                     ((not (member type '("text/html" "application/xhtml+xml")))
                      (list :error (if (string-empty-p (or type "")) "no content type" type)))
                     ((when-let* ((dom (rata-elfeed-hn--readable-text (plist-get result :body))))
                        (puthash url dom rata-elfeed-hn--article-cache)
                        (list :ok dom)))
                     (t (list :error "no readable text"))))))))))

(defun rata-elfeed-hn--insert-story (thread)
  "Insert the story section: title and one line of facts.
Before THREAD arrives only what the entry knew is shown."
  (let* ((title (or (plist-get thread :title) rata-elfeed-hn--title "(untitled)"))
         (url (or rata-elfeed-hn--article-url (plist-get thread :url)))
         (facts (delq nil
                      (list (rata-elfeed-hn--domain url)
                            (when thread
                              (rata-elfeed-hn--plural (or (plist-get thread :points) 0) "point"))
                            (when-let* ((by (plist-get thread :author))) (concat "by " by))
                            (when thread
                              (rata-elfeed-hn--age (plist-get thread :time) (float-time)))
                            (if thread
                                (rata-elfeed-hn--plural (plist-get thread :count) "comment")
                              "loading…")))))
    (insert "\n" (propertize title 'face 'rata-elfeed-hn-title) "\n"
            (propertize (string-join facts " · ") 'face 'rata-elfeed-hn-meta) "\n")))

(defun rata-elfeed-hn--insert-article (state)
  "Insert the article section for STATE.
STATE is (:loading), (:waiting), (:dom DOM URL), (:html HTML),
\(:failed REASON) or (:empty)."
  (insert "\n")
  (pcase state
    (`(:dom ,dom ,url) (rata-elfeed-hn--insert-dom dom (rata-elfeed-hn--width) url))
    (`(:html ,html) (rata-elfeed-hn--insert-html html (rata-elfeed-hn--width)))
    (`(:failed ,reason)
     (insert (propertize (format "article not fetched (%s) — , o to open" reason)
                         'face 'rata-elfeed-hn-meta)
             "\n"))
    (`(:loading) (insert (propertize "Article: loading…" 'face 'rata-elfeed-hn-meta) "\n"))
    (`(:waiting) (insert (propertize "Article: , c to load" 'face 'rata-elfeed-hn-meta) "\n"))
    (_ (insert (propertize "(no text)" 'face 'rata-elfeed-hn-meta) "\n"))))

(defun rata-elfeed-hn--start-article (url force)
  "Decide the article section: fetch URL's article, or say why not.
FORCE bypasses the article cache."
  (setq rata-elfeed-hn--article-started t)
  (if (not rata-elfeed-hn-fetch-article)
      (rata-elfeed-hn--draw-section
       'article (lambda () (rata-elfeed-hn--insert-article '(:failed "turned off"))))
    (rata-elfeed-hn--draw-section
     'article (lambda () (rata-elfeed-hn--insert-article '(:loading))))
    (rata-elfeed-hn--fetch-article
     url force
     (rata-elfeed-hn--guard
      (current-buffer)
      (lambda (result)
        (let ((state (if-let* ((dom (plist-get result :ok)))
                         (list :dom dom url)
                       (list :failed (plist-get result :error)))))
          (rata-elfeed-hn--draw-section
           'article (lambda () (rata-elfeed-hn--insert-article state)))))))))

;;; ------------------------------------------------------------
;;; Drawing an item
;;; ------------------------------------------------------------

(defun rata-elfeed-hn--on-thread (thread force)
  "Draw THREAD's story, comments and, for a text post, its text.
FORCE is passed on to an article fetch this starts."
  (rata-elfeed-hn--draw-section 'story (lambda () (rata-elfeed-hn--insert-story thread)))
  (rata-elfeed-hn--draw-section 'comments (lambda () (rata-elfeed-hn--insert-thread thread)))
  (when (> (plist-get thread :count) rata-elfeed-hn-fold-threshold)
    (rata-elfeed-hn-fold-all))
  (unless rata-elfeed-hn--article-started
    (if-let* ((url (plist-get thread :url)))
        (progn (setq rata-elfeed-hn--article-url url)
               (rata-elfeed-hn--start-article url force))
      (setq rata-elfeed-hn--article-started t)
      (let ((text (plist-get thread :text)))
        (rata-elfeed-hn--draw-section
         'article (lambda () (rata-elfeed-hn--insert-article
                              (if (and text (not (string-empty-p text)))
                                  (list :html text)
                                '(:empty)))))))))

(defun rata-elfeed-hn--load (item force)
  "Fetch ITEM's thread, and the article when its URL is already known.
Each is drawn when it arrives, whichever is first.  FORCE bypasses the
session caches."
  (rata-elfeed-hn--draw-section
   'comments (lambda () (rata-elfeed-hn--insert-status "loading…")))
  (when rata-elfeed-hn--article-url
    (rata-elfeed-hn--start-article rata-elfeed-hn--article-url force))
  (rata-elfeed-hn--fetch-thread
   item force
   (rata-elfeed-hn--guard
    (current-buffer)
    (lambda (result)
      (if-let* ((thread (plist-get result :ok)))
          (rata-elfeed-hn--on-thread thread force)
        (rata-elfeed-hn--draw-section
         'comments
         (lambda ()
           (rata-elfeed-hn--insert-status
            (format "fetch failed (%s) — , c to retry" (plist-get result :error)))))
        (unless rata-elfeed-hn--article-started
          (rata-elfeed-hn--draw-section
           'article (lambda () (rata-elfeed-hn--insert-article
                                (list :failed (plist-get result :error)))))))))))

(defun rata-elfeed-hn--draw (item &optional title article-url)
  "Draw ITEM's story, article and thread at the end of the buffer.
ITEM is a (SOURCE . ID) cons, or nil for an entry from neither site.
TITLE and ARTICLE-URL are what is known before the thread arrives.
Bumps the generation, so a reply still in flight for the previous
drawing is dropped when it arrives."
  (cl-incf rata-elfeed-hn--generation)
  (setq rata-elfeed-hn--item item
        rata-elfeed-hn--title title
        rata-elfeed-hn--article-url article-url
        rata-elfeed-hn--article-started nil)
  ;; The keys exist only where there is a thread: elfeed's entry buffer is
  ;; reused for every entry, aggregator or not.
  (rata-elfeed-hn-thread-mode (if item 1 -1))
  (when item
    (let ((force (or rata-elfeed-hn--force
                     (memq this-command '(elfeed-show-refresh revert-buffer)))))
      (rata-elfeed-hn--draw-section 'story (lambda () (rata-elfeed-hn--insert-story nil)))
      (rata-elfeed-hn--draw-section 'article (lambda () (rata-elfeed-hn--insert-article '(:waiting))))
      (if (or rata-elfeed-hn-auto force)
          (rata-elfeed-hn--load item force)
        (rata-elfeed-hn--draw-section
         'comments (lambda () (rata-elfeed-hn--insert-status ", c to load")))))))

(eval-when-compile
  (defvar elfeed-show-entry))

(defun rata-elfeed-hn--delete-feed-content ()
  "Delete the entry content elfeed drew, keeping its header.
For such an entry that content is the word \"Comments\" or a list of URLs.
The mail-style renderer marks where it starts; elfeed-goodies' plain one
draws a newline and then the content."
  (let ((inhibit-read-only t)
        (marker (text-property-any (point-min) (point-max) 'elfeed-entry-content t)))
    (delete-region (if marker (1+ marker) (min (1+ (point-min)) (point-max)))
                   (point-max))))

(defun rata-elfeed-hn-show-update ()
  "Draw the story, article and thread for the entry just drawn.
On `elfeed-show-update-hook', which `elfeed-show-refresh' runs after every
redraw: opening an entry, `n'/`p', `g', tagging.  Any other entry is left
exactly as elfeed drew it."
  (setq rata-elfeed-hn--key elfeed-show-entry)
  (let* ((item (rata-elfeed-hn--entry-item elfeed-show-entry))
         (link (and item (elfeed-entry-link elfeed-show-entry))))
    (when item
      (rata-elfeed-hn--delete-feed-content))
    (rata-elfeed-hn--draw item
                          (and item (elfeed-entry-title elfeed-show-entry))
                          ;; An Ask HN entry, or a Lobsters text post, links to
                          ;; the item itself: there is no article to fetch.
                          (and (not (rata-elfeed-hn--item-url-p link))
                               link))))

(defun rata-elfeed-hn-refetch ()
  "Fetch the current thread and article again, bypassing the session cache."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No comment thread here"))
  (let ((rata-elfeed-hn--force t))
    (if (derived-mode-p 'elfeed-show-mode)
        (elfeed-show-refresh)
      (rata-elfeed-hn--redraw))))

;;; ------------------------------------------------------------
;;; Folding and navigation
;;; ------------------------------------------------------------

(defun rata-elfeed-hn--blocks ()
  "Return every comment block in the buffer, in order, as (START END DEPTH ID)."
  (let (out (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'rata-elfeed-hn-id nil))
      (let ((end (next-single-property-change pos 'rata-elfeed-hn-id nil (point-max))))
        (push (list pos end (get-text-property pos 'rata-elfeed-hn-depth)
                    (get-text-property pos 'rata-elfeed-hn-id))
              out)
        (setq pos end)))
    (nreverse out)))

(defun rata-elfeed-hn--block-at (&optional pos)
  "Return the tail of `rata-elfeed-hn--blocks' starting at the block around POS.
Nil when POS (default point) is not in a comment."
  (let ((pos (or pos (point))))
    (cl-loop for tail on (rata-elfeed-hn--blocks)
             when (and (<= (nth 0 (car tail)) pos) (< pos (nth 1 (car tail))))
             return tail)))

(defun rata-elfeed-hn--comment-at-point ()
  "Return the tail of blocks starting at the comment at point, or signal."
  (or (rata-elfeed-hn--block-at)
      (user-error "Not on a comment")))

(defun rata-elfeed-hn--replies-end (tail)
  "Return where the replies of the first block in TAIL end.
That is the start of the next block at the same depth or shallower, or
the end of the last block."
  (let ((depth (nth 2 (car tail)))
        (end (nth 1 (car tail))))
    (cl-loop for b in (cdr tail)
             while (> (nth 2 b) depth)
             do (setq end (nth 1 b)))
    end))

(defun rata-elfeed-hn--fold-overlay (tail)
  "Return the fold overlay over the replies of TAIL's first block, or nil."
  (cl-find-if (lambda (o) (overlay-get o 'rata-elfeed-hn-fold))
              (overlays-at (nth 1 (car tail)))))

(defun rata-elfeed-hn--fold (tail)
  "Hide the replies of TAIL's first block.  No-op when it has none."
  (let ((start (nth 1 (car tail)))
        (end (rata-elfeed-hn--replies-end tail)))
    (when (and (< start end) (not (rata-elfeed-hn--fold-overlay tail)))
      (let ((o (make-overlay start end)))
        (overlay-put o 'rata-elfeed-hn-fold t)
        (overlay-put o 'invisible 'rata-elfeed-hn)
        (overlay-put o 'evaporate t)))))

(defun rata-elfeed-hn--unfold (tail)
  "Show the replies of TAIL's first block."
  (when-let* ((o (rata-elfeed-hn--fold-overlay tail)))
    (delete-overlay o)))

(defun rata-elfeed-hn-toggle-fold ()
  "Fold or unfold the replies of the comment at point."
  (interactive)
  (let ((tail (rata-elfeed-hn--comment-at-point)))
    (if (rata-elfeed-hn--fold-overlay tail)
        (rata-elfeed-hn--unfold tail)
      (rata-elfeed-hn--fold tail))))

(defun rata-elfeed-hn-fold ()
  "Fold the replies of the comment at point."
  (interactive)
  (rata-elfeed-hn--fold (rata-elfeed-hn--comment-at-point)))

(defun rata-elfeed-hn-unfold ()
  "Unfold the replies of the comment at point."
  (interactive)
  (rata-elfeed-hn--unfold (rata-elfeed-hn--comment-at-point)))

(defun rata-elfeed-hn-unfold-all ()
  "Show every comment."
  (interactive)
  (remove-overlays (point-min) (point-max) 'rata-elfeed-hn-fold t))

(defun rata-elfeed-hn-fold-all ()
  "Fold every reply, leaving the top-level comments visible."
  (interactive)
  (rata-elfeed-hn-unfold-all)
  (cl-loop for tail on (rata-elfeed-hn--blocks)
           when (= (nth 2 (car tail)) 0)
           do (rata-elfeed-hn--fold tail)))

(defun rata-elfeed-hn--goto (block)
  "Move point to the start of BLOCK."
  (goto-char (nth 0 block)))

(defun rata-elfeed-hn-next-sibling ()
  "Move to the next comment at the same depth, skipping replies.
Before the first comment, move to the first comment."
  (interactive)
  (let ((tail (rata-elfeed-hn--block-at)))
    (if (null tail)
        (let ((next (cl-find-if (lambda (b) (> (nth 0 b) (point)))
                                (rata-elfeed-hn--blocks))))
          (if next (rata-elfeed-hn--goto next) (user-error "No comment below")))
      (let ((depth (nth 2 (car tail))))
        (rata-elfeed-hn--goto
         (or (cl-loop for b in (cdr tail)
                      if (= (nth 2 b) depth) return b
                      if (< (nth 2 b) depth) return nil)
             (user-error "No later comment at this depth")))))))

(defun rata-elfeed-hn-previous-sibling ()
  "Move to the previous comment at the same depth, skipping replies."
  (interactive)
  (let* ((tail (rata-elfeed-hn--comment-at-point))
         (depth (nth 2 (car tail)))
         (before (reverse (cl-loop for b in (rata-elfeed-hn--blocks)
                                   while (< (nth 0 b) (nth 0 (car tail)))
                                   collect b))))
    (rata-elfeed-hn--goto
     (or (cl-loop for b in before
                  if (= (nth 2 b) depth) return b
                  if (< (nth 2 b) depth) return nil)
         (user-error "No earlier comment at this depth")))))

(defun rata-elfeed-hn-parent ()
  "Move to the comment the one at point replies to."
  (interactive)
  (let* ((tail (rata-elfeed-hn--comment-at-point))
         (depth (nth 2 (car tail))))
    (when (= depth 0)
      (user-error "A top-level comment has no parent"))
    (rata-elfeed-hn--goto
     (cl-loop for b in (reverse (rata-elfeed-hn--blocks))
              when (and (< (nth 0 b) (nth 0 (car tail))) (< (nth 2 b) depth))
              return b))))

;;; ------------------------------------------------------------
;;; Links in and out
;;; ------------------------------------------------------------

(defcustom rata-elfeed-hn-route-item-links t
  "Non-nil: open an HN or Lobsters item link in a thread buffer of its own.
Applies to every `browse-url' call -- a link in a comment, in an Org note."
  :type 'boolean)

(defun rata-elfeed-hn--item-url (item)
  "Return the permalink of ITEM, a (SOURCE . ID) cons."
  (funcall (rata-elfeed-hn--prop item :item-url) (cdr item)))

(defun rata-elfeed-hn--comment-url (item comment-id)
  "Return the permalink of COMMENT-ID in ITEM's thread.
On HN a comment is an item like any other; on Lobsters it has a short
id of its own, on a different path."
  (funcall (rata-elfeed-hn--prop item :comment-url) comment-id))

(defun rata-elfeed-hn--route-p (url &rest _)
  "Non-nil when `browse-url' should send URL here."
  (and rata-elfeed-hn-route-item-links
       (rata-elfeed-hn--item-url-p url)))

(defun rata-elfeed-hn--browse-external (url)
  "Open URL with `browse-url', but never route it back here."
  (require 'browse-url)
  (let ((browse-url-handlers
         (cl-remove 'rata-elfeed-hn-browse-url browse-url-handlers :key #'cdr)))
    (browse-url url)))

(defun rata-elfeed-hn-browse-url (url &rest _)
  "`browse-url' handler: show the item URL in its own buffer."
  (rata-elfeed-hn-open-item url))

(defun rata-elfeed-hn-open-article ()
  "Open the story's article in the browser; a text post opens the thread."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No comment thread here"))
  (rata-elfeed-hn--browse-external
   (or rata-elfeed-hn--article-url
       (plist-get (gethash rata-elfeed-hn--item rata-elfeed-hn--cache) :url)
       (rata-elfeed-hn--item-url rata-elfeed-hn--item))))

(defun rata-elfeed-hn-open-thread-in-browser ()
  "Open the thread on its own site, in the browser."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No comment thread here"))
  (rata-elfeed-hn--browse-external (rata-elfeed-hn--item-url rata-elfeed-hn--item)))

(defun rata-elfeed-hn-copy-permalink ()
  "Copy the permalink of the comment at point, or of the story."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No comment thread here"))
  (let* ((comment (get-text-property (point) 'rata-elfeed-hn-id))
         (url (if comment
                  (rata-elfeed-hn--comment-url rata-elfeed-hn--item comment)
                (rata-elfeed-hn--item-url rata-elfeed-hn--item))))
    (kill-new url)
    (message "Copied %s" url)))

(defun rata-elfeed-hn--parse-item (input)
  "Return the (SOURCE . ID) in INPUT, or nil.
INPUT is an item URL from any source, an HN id as an integer or as
digits, or a (SOURCE . ID) cons already.  Bare digits are HN: a bare
Lobsters short id is just a word, and guessing would turn every typo
into a request."
  (cond ((and (consp input) (rata-elfeed-hn--spec (car input))) input)
        ((natnump input) (cons 'hn input))
        ((not (stringp input)) nil)
        ((string-match "\\`[ \t]*\\([0-9]+\\)[ \t]*\\'" input)
         (cons 'hn (string-to-number (match-string 1 input))))
        (t (let ((url (string-trim input)))
             (cl-loop for (source . spec) in rata-elfeed-hn--sources
                      when (string-match (plist-get spec :item-url-regexp) url)
                      return (rata-elfeed-hn--make-item source (match-string 1 url)))))))

(define-derived-mode rata-elfeed-hn-item-mode special-mode "Thread"
  "Mode for an HN or Lobsters item opened outside elfeed."
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (let ((rata-elfeed-hn--force t))
                  (rata-elfeed-hn--redraw)))))

(defun rata-elfeed-hn--redraw ()
  "Draw the item in the current thread buffer from scratch."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (rata-elfeed-hn--draw rata-elfeed-hn--item)
  (goto-char (point-min)))

(defun rata-elfeed-hn-open-item (item)
  "Show ITEM -- an HN id, or an HN or Lobsters item URL -- in its own buffer.
The story, the article and the thread, with the same keys as in elfeed.
The buffer is named for the source, so `*HN 8863*' and
`*Lobsters h0eate*' are different buffers and never collide."
  (interactive
   (list (read-string "HN/Lobsters item URL or HN id: "
                      (when-let* ((url (thing-at-point 'url)))
                        (and (rata-elfeed-hn--parse-item url) url)))))
  (let* ((parsed (or (rata-elfeed-hn--parse-item item)
                     (user-error "Not an HN or Lobsters item: %s" item)))
         (name (rata-elfeed-hn--prop parsed :name)))
    (with-current-buffer (get-buffer-create (format "*%s %s*" name (cdr parsed)))
      (unless (derived-mode-p 'rata-elfeed-hn-item-mode)
        (rata-elfeed-hn-item-mode))
      (setq mode-name name
            rata-elfeed-hn--key parsed
            rata-elfeed-hn--item parsed)
      (rata-elfeed-hn--redraw)
      (pop-to-buffer (current-buffer)))))

;;; ------------------------------------------------------------
;;; Keys
;;; ------------------------------------------------------------

(defvar-keymap rata-elfeed-hn-thread-mode-map
  :doc "Keymap for `rata-elfeed-hn-thread-mode'; the evil keys live in its
normal-state auxiliary map.")

(define-minor-mode rata-elfeed-hn-thread-mode
  "Comment folding, navigation and thread commands, in a buffer showing one.
Turned on and off by the drawing itself, so the keys exist exactly where
there is a thread.  `]]', `[[' and `TAB' are left to elfeed."
  :lighter nil
  (if rata-elfeed-hn-thread-mode
      (add-to-invisibility-spec '(rata-elfeed-hn . t))
    (remove-from-invisibility-spec '(rata-elfeed-hn . t))
    (rata-elfeed-hn-unfold-all))
  ;; Evil caches which auxiliary keymaps are active; a minor mode switched on
  ;; from code, not a key, is otherwise not seen until the next state change.
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))

(defconst rata-elfeed-hn--keys
  '(("za" rata-elfeed-hn-toggle-fold "toggle replies")
    ("zc" rata-elfeed-hn-fold "fold replies")
    ("zo" rata-elfeed-hn-unfold "unfold replies")
    ("zM" rata-elfeed-hn-fold-all "fold to top level")
    ("zR" rata-elfeed-hn-unfold-all "unfold all")
    ("zj" rata-elfeed-hn-next-sibling "next comment, same depth")
    ("zk" rata-elfeed-hn-previous-sibling "previous comment, same depth")
    ("zu" rata-elfeed-hn-parent "parent comment")
    (",c" rata-elfeed-hn-refetch "refetch thread")
    (",o" rata-elfeed-hn-open-article "open article in browser")
    (",O" rata-elfeed-hn-open-thread-in-browser "open thread in browser")
    (",y" rata-elfeed-hn-copy-permalink "copy permalink"))
  "Normal-state keys of `rata-elfeed-hn-thread-mode', as (KEY COMMAND LABEL).")

(declare-function general-define-key "general" (&rest args))
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))

;; Top level, not in a deferred block: the keymap is this file's own, and the
;; leader key must exist from startup (FAIL-0009).
(with-eval-after-load 'general
  (apply #'general-define-key
         :states 'normal
         :keymaps 'rata-elfeed-hn-thread-mode-map
         ","  '(:ignore t :which-key "comments")
         (cl-loop for (key command label) in rata-elfeed-hn--keys
                  append (list key (list command :which-key label))))
  (rata-leader
    :states '(normal visual)
    "arh" '(rata-elfeed-hn-open-item :which-key "HN/Lobsters thread by URL/id")))

(with-eval-after-load 'evil
  (evil-set-initial-state 'rata-elfeed-hn-item-mode 'normal)
  (evil-define-key* 'normal rata-elfeed-hn-item-mode-map "q" #'quit-window))

(with-eval-after-load 'browse-url
  (add-to-list 'browse-url-handlers
               (cons #'rata-elfeed-hn--route-p #'rata-elfeed-hn-browse-url)))

;; After elfeed-show, never before: its `defvar' of the hook carries elfeed's
;; own two functions, and an `add-hook' that ran first would bind the variable
;; and so silently drop them.  An elfeed without the hook (the frozen `master'
;; branch, FAIL-0026) would never call ours either, so say so instead.
(with-eval-after-load 'elfeed-show
  (if (boundp 'elfeed-show-update-hook)
      (add-hook 'elfeed-show-update-hook #'rata-elfeed-hn-show-update t)
    (display-warning
     'rata-elfeed-hn
     (concat "This elfeed has no `elfeed-show-update-hook', so Hacker News "
             "and Lobsters entries will not be drawn.  It is upstream's frozen `master' "
             "branch; switch the clone to `main' and run `elpaca-rebuild' "
             "on elfeed (FAIL-0026).")
     :error)))

(provide 'init-elfeed-hn)
