;;; -*- lexical-binding: t; -*-
;;; init-elfeed-hn.el --- Hacker News stories and comments inside elfeed

;; An HN entry in elfeed carries no article: the news.ycombinator.com feed's
;; content is the single word "Comments", hnrss's a list of URLs.  This module
;; teaches elfeed's own entry buffer to show what the entry is about -- the
;; story, a readable copy of the linked article, and the whole comment thread
;; -- through `elfeed-show-update-hook'.  It owns no package: `url-retrieve',
;; `json-parse-string' and `shr' are built in.  Plan and design:
;; plans/hackernews-reader.md.
;;
;; Three rules hold the async part together, the same ones the claude-loop
;; follows at a larger size:
;;
;; - `rata-elfeed-hn--retrieve' is the only function that touches the network,
;;   so the tests replace exactly one function.
;; - Every reply is delivered from a zero-delay timer, never from inside
;;   url.el's process callback, and an error in it becomes a result, not a
;;   signal: a signal there is demoted to a *Messages* line nobody reads.
;; - A reply is drawn only if its buffer is live and still shows the entry it
;;   was fetched for under the same generation (`rata-elfeed-hn--generation',
;;   bumped on every redraw), so `n'/`p' or `g' before it arrives make it a
;;   no-op rather than comments drawn under the wrong story.

(require 'cl-lib)
(require 'subr-x)

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
  "Hacker News story and comments in elfeed's entry buffer."
  :group 'rata)

(defcustom rata-elfeed-hn-api-url "https://hn.algolia.com/api/v1/items/"
  "Algolia HN item endpoint; the item id is appended.
One request returns the story and its whole comment tree, however big."
  :type 'string)

(defcustom rata-elfeed-hn-timeout 20
  "Seconds before a request is abandoned and reported as timed out."
  :type 'number)

(defconst rata-elfeed-hn--item-url-regexp
  "\\`https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)\\'"
  "Matches a whole HN item URL; group 1 is the id.")

(defconst rata-elfeed-hn--content-id-regexps
  '(;; news.ycombinator.com/rss: the whole content is this one link.
    "href=\"https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)\"[^>]*>Comments</a>"
    ;; hnrss.org: "Comments URL: <a href=...>", plain text in older entries.
    "Comments URL:[ \t]*\\(?:<a href=\"\\)?https?://\\(?:www\\.\\)?news\\.ycombinator\\.com/item\\?id=\\([0-9]+\\)")
  "Regexps finding the HN item id in an HN feed's entry content.
Anchored on the shape each feed writes rather than on any item URL, so
a blog post that merely links to an HN discussion is not taken for one.")

(defun rata-elfeed-hn-item-id (content link)
  "Return the HN item id for an entry with CONTENT and LINK, or nil.
Pure.  LINK wins when it is itself an item URL (an Ask HN entry);
otherwise CONTENT is searched for the shape an HN feed writes."
  (cond
   ((and (stringp link) (string-match rata-elfeed-hn--item-url-regexp link))
    (string-to-number (match-string 1 link)))
   ((stringp content)
    (cl-loop for re in rata-elfeed-hn--content-id-regexps
             when (string-match re content)
             return (string-to-number (match-string 1 content))))))

;;; ------------------------------------------------------------
;;; Network -- one function, results not signals
;;; ------------------------------------------------------------

(eval-when-compile
  ;; Let-bound below; declared special so that binding them before shr or
  ;; browse-url has loaded is still a dynamic binding, not a lexical one.
  (defvar shr-width)
  (defvar shr-max-width)
  (defvar shr-base)
  (defvar browse-url-handlers)
  (defvar url-http-response-status)
  (defvar url-http-content-type)
  (defvar url-http-end-of-headers))

(defun rata-elfeed-hn--read-response (status max-bytes)
  "Turn the current url.el response buffer into a result plist.
STATUS is url.el's status list.  Returns (:ok t :type TYPE :body STRING)
or (:error REASON).  A body over MAX-BYTES is an error, not a truncation;
MAX-BYTES nil means no cap."
  (condition-case err
      (cond
       ((plist-get status :error)
        (list :error (rata-elfeed-hn--error-reason (plist-get status :error))))
       (t
        (let ((code (bound-and-true-p url-http-response-status))
              (ctype (or (bound-and-true-p url-http-content-type) "")))
          (cond
           ((and code (not (<= 200 code 299))) (list :error (format "HTTP %s" code)))
           ((not (bound-and-true-p url-http-end-of-headers))
            (list :error "no response"))
           ((and max-bytes (> (- (point-max) url-http-end-of-headers) max-bytes))
            (list :error (format "over %d KB" (/ max-bytes 1024))))
           (t
            (rata-elfeed-hn--ok-result
             ctype (buffer-substring-no-properties
                    (1+ url-http-end-of-headers) (point-max))))))))
    (error (list :error (error-message-string err)))))

(defun rata-elfeed-hn--text-type-p (type)
  "Non-nil when the MIME TYPE is text to decode, not bytes to keep."
  (string-match-p "\\`text/\\|json\\|xml\\|javascript" type))

(defun rata-elfeed-hn--ok-result (ctype bytes)
  "Return the success plist for raw BYTES of Content-Type CTYPE.
Text is decoded with the charset CTYPE names, UTF-8 when it names none
Emacs knows.  Anything else -- an image -- is kept as the bytes it is,
except an SVG, which is XML but must reach `create-image' undecoded."
  (let* ((type (downcase (string-trim (car (split-string ctype ";")))))
         (charset (and (string-match "charset=\\([^; ]+\\)" ctype)
                       (intern-soft (downcase (match-string 1 ctype)))))
         (coding (if (and charset (coding-system-p charset)) charset 'utf-8)))
    (list :ok t
          :type type
          :body (if (and (rata-elfeed-hn--text-type-p type)
                         (not (string-prefix-p "image/" type)))
                    (decode-coding-string bytes coding)
                  bytes))))

(defun rata-elfeed-hn--error-reason (err)
  "Return a short reason string for url.el error ERR."
  (pcase err
    (`(error http ,code) (format "HTTP %s" code))
    (`(,_ . ,data) (format "%s" (if (consp data) (car (last data)) data)))
    (_ (format "%s" err))))

(defcustom rata-elfeed-hn-curl-program "curl"
  "The curl executable, or nil to fetch with Emacs's own url.el.
curl is the default because it races IPv6 against IPv4 (happy eyeballs)
and url.el does not: on a network that hands out an IPv6 address but
does not route it, url.el waits out a connect timeout on every site that
publishes an AAAA record -- most of Cloudflare -- and the article reads
\"timed out\".  url.el is used when curl is not on PATH."
  :type '(choice (string :tag "Program") (const :tag "url.el" nil)))

(defconst rata-elfeed-hn--curl-status-format "\n%{http_code} %{content_type}"
  "curl --write-out format: a last line with the status and content type.")

(defun rata-elfeed-hn--curl-args (url max-bytes timeout)
  "Return curl's arguments for fetching URL.  Pure.
MAX-BYTES (nil: no cap) stops a download the server declares too big;
TIMEOUT is in seconds."
  `("--silent" "--show-error" "--location" "--compressed"
    "--max-time" ,(number-to-string timeout)
    ,@(when max-bytes (list "--max-filesize" (number-to-string max-bytes)))
    "--write-out" ,rata-elfeed-hn--curl-status-format
    "--" ,url))

(defun rata-elfeed-hn--curl-result (output exit stderr max-bytes)
  "Turn a finished curl run into a result plist.  Pure.
OUTPUT is its raw stdout -- the body, then the status line that
`rata-elfeed-hn--curl-status-format' appends; EXIT its exit code; STDERR
its error text.  A body over MAX-BYTES (nil: no cap) is an error."
  (let* ((cut (string-match "\n\\([0-9]+\\) \\([^\n]*\\)\\'" output))
         (code (and cut (string-to-number (match-string 1 output))))
         (ctype (and cut (match-string 2 output)))
         (body (and cut (substring output 0 cut))))
    (cond
     ((eql exit 28) (list :error "timed out"))
     ((eql exit 63) (list :error (format "over %d KB" (/ (or max-bytes 0) 1024))))
     ((not (eql exit 0))
      (list :error (let ((msg (string-trim (or stderr ""))))
                     (if (string-empty-p msg)
                         (format "curl exited %s" exit)
                       (replace-regexp-in-string "\\`curl: ([0-9]+) " "" msg)))))
     ((not cut) (list :error "no response"))
     ((not (<= 200 code 299)) (list :error (format "HTTP %d" code)))
     ((and max-bytes (> (string-bytes body) max-bytes))
      (list :error (format "over %d KB" (/ max-bytes 1024))))
     (t (rata-elfeed-hn--ok-result ctype body)))))

(defun rata-elfeed-hn--curl-retrieve (program url max-bytes finish)
  "Fetch URL with curl PROGRAM; call FINISH with the result plist.
Return the process."
  (let* ((out (generate-new-buffer " *rata-elfeed-hn-curl*"))
         (err (generate-new-buffer " *rata-elfeed-hn-curl-err*"))
         ;; An explicit pipe, so its own "Process ... finished" line is not
         ;; written into the error text.
         (err-pipe (make-pipe-process :name "rata-elfeed-hn-curl-err" :buffer err
                                      :noquery t :sentinel #'ignore)))
    (with-current-buffer out (set-buffer-multibyte nil))
    (make-process
     :name "rata-elfeed-hn-curl"
     :buffer out
     :stderr err-pipe
     :coding 'binary
     :connection-type 'pipe
     :noquery t
     :command (cons program (rata-elfeed-hn--curl-args url max-bytes rata-elfeed-hn-timeout))
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (unwind-protect
             (funcall finish
                      (condition-case e
                          (rata-elfeed-hn--curl-result
                           (with-current-buffer out (buffer-string))
                           (process-exit-status proc)
                           (with-current-buffer err (buffer-string))
                           max-bytes)
                        (error (list :error (error-message-string e)))))
           (kill-buffer out)
           ;; The stderr pipe has a process of its own; let it go with the buffer.
           (when-let* ((ep (get-buffer-process err))) (delete-process ep))
           (kill-buffer err)))))))

(defun rata-elfeed-hn--url-retrieve (url max-bytes finish)
  "Fetch URL with url.el; call FINISH with the result plist.
Return the response buffer."
  (url-retrieve url
                (lambda (status)
                  (funcall finish (rata-elfeed-hn--read-response status max-bytes))
                  (kill-buffer (current-buffer)))
                nil t t))

(defun rata-elfeed-hn--retrieve (url max-bytes callback)
  "Fetch URL and call CALLBACK with a result plist, from a timer.
The only function in this module that touches the network: through curl
when `rata-elfeed-hn-curl-program' is on PATH, else url.el.  The result
is (:ok t :type CONTENT-TYPE :body STRING) or (:error REASON); CALLBACK
is called exactly once, even when the request times out or never starts.
A body over MAX-BYTES (nil: no cap) is an error."
  (let* ((done nil)
         (finish (lambda (result)
                   (unless done
                     (setq done t)
                     (run-at-time 0 nil callback result)))))
    (condition-case err
        (let* ((curl (and rata-elfeed-hn-curl-program
                          (executable-find rata-elfeed-hn-curl-program)))
               (handle (if curl
                           (rata-elfeed-hn--curl-retrieve curl url max-bytes finish)
                         (rata-elfeed-hn--url-retrieve url max-bytes finish))))
          ;; curl enforces --max-time itself; this is the backstop for both,
          ;; a little later so that curl's own verdict normally wins.
          (run-at-time (+ rata-elfeed-hn-timeout 2) nil
                       (lambda ()
                         (unless done
                           (funcall finish (list :error "timed out"))
                           (let ((proc (if (processp handle)
                                           handle
                                         (and (buffer-live-p handle)
                                              (get-buffer-process handle)))))
                             (when (process-live-p proc) (delete-process proc)))
                           (when (and (bufferp handle) (buffer-live-p handle))
                             (kill-buffer handle))))))
      (error (funcall finish (list :error (error-message-string err)))))))

(defun rata-elfeed-hn--fetch-json (id callback)
  "Fetch HN item ID from Algolia; call CALLBACK with (:ok JSON) or (:error REASON).
JSON is parsed with objects as alists and null as nil."
  (rata-elfeed-hn--retrieve
   (concat rata-elfeed-hn-api-url (number-to-string id))
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

(defun rata-elfeed-hn--comment-from-json (node depth)
  "Return the comment plist for Algolia NODE at DEPTH, or nil to drop it.
A comment with no author or no text is deleted or dead.  It is dropped,
unless it has live replies: then it stays as a `:deleted' placeholder so
the replies keep their parent."
  (when (equal (alist-get 'type node) "comment")
    (let* ((children (delq nil (mapcar (lambda (c)
                                         (rata-elfeed-hn--comment-from-json c (1+ depth)))
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

(defun rata-elfeed-hn--thread-from-json (json)
  "Return the story plist for the Algolia item JSON.
Keys: :id :title :url :author :points :time :text, :comments (the
top-level comment plists, in order) and :count (live comments in the
whole tree; deleted placeholders are not counted)."
  (let ((comments (delq nil (mapcar (lambda (c) (rata-elfeed-hn--comment-from-json c 0))
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

(defvar rata-elfeed-hn--cache (make-hash-table)
  "Parsed threads by item id, for this session.")

(defun rata-elfeed-hn--fetch-thread (id force callback)
  "Call CALLBACK with (:ok THREAD) or (:error REASON) for HN item ID.
A cached thread is answered from a timer too, so callers never see a
synchronous reply; FORCE skips the cache."
  (let ((cached (and (not force) (gethash id rata-elfeed-hn--cache))))
    (if cached
        (run-at-time 0 nil callback (list :ok cached))
      (rata-elfeed-hn--fetch-json
       id
       (lambda (result)
         (funcall callback
                  (if (plist-get result :error)
                      result
                    (condition-case err
                        (let ((thread (rata-elfeed-hn--thread-from-json
                                       (plist-get result :ok))))
                          (puthash id thread rata-elfeed-hn--cache)
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
  "Non-nil: fetch the thread when an HN entry is opened.
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
  "The HN item id the buffer shows, or nil when it shows no HN item.")

(defvar rata-elfeed-hn--force nil
  "Non-nil while a redraw should bypass the session cache.")

(defun rata-elfeed-hn--entry-item-id (entry)
  "Return the HN item id of elfeed ENTRY, or nil."
  (when entry
    (let ((content (elfeed-deref (elfeed-entry-content entry))))
      (rata-elfeed-hn-item-id (and (stringp content) content)
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

(defcustom rata-elfeed-hn-max-images 40
  "Most images fetched for one article; the rest keep their placeholder."
  :type 'integer)

(defcustom rata-elfeed-hn-image-max-bytes (* 5 1024 1024)
  "Largest image fetched, in bytes."
  :type 'integer)

(defconst rata-elfeed-hn--image-parallel 6
  "Images fetched at once.")

(defun rata-elfeed-hn--insert-dom (dom width &optional base)
  "Insert DOM at point, rendered by `shr' to WIDTH columns.
BASE is the URL relative links and images resolve against.

shr fetches images itself, with `url-queue-retrieve' -- url.el, which
stalls on an unrouted IPv6 address exactly as articles did (FAIL-0024),
and gives up after `url-queue-timeout'.  So while shr renders, its
requests are recorded instead of sent, and fetched afterwards through
`rata-elfeed-hn--retrieve'; each arrival goes back to shr's own
`shr-replace-image', so placeholders, sizing and image keys stay shr's."
  (require 'shr)
  (let ((shr-width width)
        (shr-max-width nil)
        (requests nil))
    (cl-letf (((symbol-function 'url-queue-retrieve)
               (lambda (url _callback cbargs &rest _)
                 (push (cons url cbargs) requests))))
      ;; `shr-insert-document' binds `shr-base' to nil and takes the base
      ;; only from a <base> element, so binding it around the call does
      ;; nothing: relative images and links stayed relative.
      (shr-insert-document (if base `(base ((href . ,base)) ,dom) dom)))
    (unless (bolp) (insert "\n"))
    (when requests
      (rata-elfeed-hn--fetch-images (nreverse requests)))))

(defun rata-elfeed-hn--place-image (result buffer start end flags)
  "Put the image in RESULT between START and END of BUFFER, shr's placeholder.
A failed fetch leaves the placeholder; so does a placeholder whose text
has since been deleted."
  (when (and (plist-get result :ok)
             (markerp start) (markerp end)
             (eq (marker-buffer start) buffer)
             (< start end))
    (let ((type (plist-get result :type)))
      (shr-replace-image (if (string-prefix-p "image/" type)
                             (list (plist-get result :body) (intern type))
                           (plist-get result :body))
                         start end flags))))

(defun rata-elfeed-hn--fetch-images (requests)
  "Fetch shr's image REQUESTS, a few at a time, into the current buffer.
REQUESTS are (URL BUFFER START END FLAGS), as shr handed them to
`url-queue-retrieve'.  At most `rata-elfeed-hn-max-images' are fetched.
Each arrival is guarded like any other reply, so leaving the entry
stops the queue rather than filling a buffer that has moved on."
  (let* ((queue (seq-take requests rata-elfeed-hn-max-images))
         (buffer (current-buffer))
         next)
    (setq next
          (lambda ()
            (when-let* ((request (pop queue)))
              (rata-elfeed-hn--retrieve
               (car request) rata-elfeed-hn-image-max-bytes
               (rata-elfeed-hn--guard
                buffer
                (lambda (result)
                  (unwind-protect
                      (pcase-let ((`(,_ ,start ,end ,flags) (cdr request)))
                        (rata-elfeed-hn--place-image result buffer start end flags))
                    (funcall next))))))))
    (dotimes (_ rata-elfeed-hn--image-parallel)
      (funcall next))))

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
      (rata-elfeed-hn--retrieve
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

(defun rata-elfeed-hn--load (id force)
  "Fetch thread ID, and the article when its URL is already known.
Each is drawn when it arrives, whichever is first.  FORCE bypasses the
session caches."
  (rata-elfeed-hn--draw-section
   'comments (lambda () (rata-elfeed-hn--insert-status "loading…")))
  (when rata-elfeed-hn--article-url
    (rata-elfeed-hn--start-article rata-elfeed-hn--article-url force))
  (rata-elfeed-hn--fetch-thread
   id force
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

(defun rata-elfeed-hn--draw (id &optional title article-url)
  "Draw HN item ID's story, article and thread at the end of the buffer.
TITLE and ARTICLE-URL are what is known before the thread arrives.
Bumps the generation, so a reply still in flight for the previous
drawing is dropped when it arrives."
  (cl-incf rata-elfeed-hn--generation)
  (setq rata-elfeed-hn--item id
        rata-elfeed-hn--title title
        rata-elfeed-hn--article-url article-url
        rata-elfeed-hn--article-started nil)
  ;; The keys exist only where there is a thread: elfeed's entry buffer is
  ;; reused for every entry, HN or not.
  (rata-elfeed-hn-thread-mode (if id 1 -1))
  (when id
    (let ((force (or rata-elfeed-hn--force
                     (memq this-command '(elfeed-show-refresh revert-buffer)))))
      (rata-elfeed-hn--draw-section 'story (lambda () (rata-elfeed-hn--insert-story nil)))
      (rata-elfeed-hn--draw-section 'article (lambda () (rata-elfeed-hn--insert-article '(:waiting))))
      (if (or rata-elfeed-hn-auto force)
          (rata-elfeed-hn--load id force)
        (rata-elfeed-hn--draw-section
         'comments (lambda () (rata-elfeed-hn--insert-status ", c to load")))))))

(eval-when-compile
  (defvar elfeed-show-entry))

(defun rata-elfeed-hn--delete-feed-content ()
  "Delete the entry content elfeed drew, keeping its header.
For an HN entry that content is the word \"Comments\" or a list of URLs.
The mail-style renderer marks where it starts; elfeed-goodies' plain one
draws a newline and then the content."
  (let ((inhibit-read-only t)
        (marker (text-property-any (point-min) (point-max) 'elfeed-entry-content t)))
    (delete-region (if marker (1+ marker) (min (1+ (point-min)) (point-max)))
                   (point-max))))

(defun rata-elfeed-hn-show-update ()
  "Draw the HN story, article and thread for the entry just drawn.
On `elfeed-show-update-hook', which `elfeed-show-refresh' runs after every
redraw: opening an entry, `n'/`p', `g', tagging.  Any other entry is left
exactly as elfeed drew it."
  (setq rata-elfeed-hn--key elfeed-show-entry)
  (let* ((id (rata-elfeed-hn--entry-item-id elfeed-show-entry))
         (link (and id (elfeed-entry-link elfeed-show-entry))))
    (when id
      (rata-elfeed-hn--delete-feed-content))
    (rata-elfeed-hn--draw id
                          (and id (elfeed-entry-title elfeed-show-entry))
                          ;; An Ask HN entry links to the item itself: no article.
                          (and (stringp link)
                               (not (string-match-p rata-elfeed-hn--item-url-regexp link))
                               link))))

(defun rata-elfeed-hn-refetch ()
  "Fetch the current HN thread and article again, bypassing the session cache."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No Hacker News thread here"))
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
  "Non-nil: open news.ycombinator.com item links in a `*HN <id>*' buffer.
Applies to every `browse-url' call -- a link in a comment, in an Org note."
  :type 'boolean)

(defun rata-elfeed-hn--item-url (id)
  "Return the HN permalink of item ID."
  (format "https://news.ycombinator.com/item?id=%s" id))

(defun rata-elfeed-hn--route-p (url &rest _)
  "Non-nil when `browse-url' should send URL here."
  (and rata-elfeed-hn-route-item-links
       (stringp url)
       (string-match-p rata-elfeed-hn--item-url-regexp url)))

(defun rata-elfeed-hn--browse-external (url)
  "Open URL with `browse-url', but never route it back here."
  (require 'browse-url)
  (let ((browse-url-handlers
         (cl-remove 'rata-elfeed-hn-browse-url browse-url-handlers :key #'cdr)))
    (browse-url url)))

(defun rata-elfeed-hn-browse-url (url &rest _)
  "`browse-url' handler: show HN item URL in its own buffer."
  (rata-elfeed-hn-open-item url))

(defun rata-elfeed-hn-open-article ()
  "Open the story's article in the browser; a text post opens the HN thread."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No Hacker News thread here"))
  (rata-elfeed-hn--browse-external
   (or rata-elfeed-hn--article-url
       (plist-get (gethash rata-elfeed-hn--item rata-elfeed-hn--cache) :url)
       (rata-elfeed-hn--item-url rata-elfeed-hn--item))))

(defun rata-elfeed-hn-open-thread-in-browser ()
  "Open the HN thread in the browser."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No Hacker News thread here"))
  (rata-elfeed-hn--browse-external (rata-elfeed-hn--item-url rata-elfeed-hn--item)))

(defun rata-elfeed-hn-copy-permalink ()
  "Copy the permalink of the comment at point, or of the story."
  (interactive)
  (unless rata-elfeed-hn--item
    (user-error "No Hacker News thread here"))
  (let ((url (rata-elfeed-hn--item-url
              (or (get-text-property (point) 'rata-elfeed-hn-id) rata-elfeed-hn--item))))
    (kill-new url)
    (message "Copied %s" url)))

(defun rata-elfeed-hn--parse-item (input)
  "Return the item id in INPUT -- an integer, digits or an item URL -- or nil."
  (cond ((natnump input) input)
        ((not (stringp input)) nil)
        ((string-match "\\`[ \t]*\\([0-9]+\\)[ \t]*\\'" input)
         (string-to-number (match-string 1 input)))
        ((string-match rata-elfeed-hn--item-url-regexp (string-trim input))
         (string-to-number (match-string 1 (string-trim input))))))

(define-derived-mode rata-elfeed-hn-item-mode special-mode "HN"
  "Mode for a Hacker News item opened outside elfeed."
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (let ((rata-elfeed-hn--force t))
                  (rata-elfeed-hn--redraw)))))

(defun rata-elfeed-hn--redraw ()
  "Draw the item in the current `*HN <id>*' buffer from scratch."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (rata-elfeed-hn--draw rata-elfeed-hn--item)
  (goto-char (point-min)))

(defun rata-elfeed-hn-open-item (item)
  "Show HN ITEM -- an id or an item URL -- in a `*HN <id>*' buffer.
The story, the article and the thread, with the same keys as in elfeed."
  (interactive
   (list (read-string "HN item URL or id: "
                      (when-let* ((url (thing-at-point 'url)))
                        (and (rata-elfeed-hn--parse-item url) url)))))
  (let ((id (or (rata-elfeed-hn--parse-item item)
                (user-error "Not a Hacker News item: %s" item))))
    (with-current-buffer (get-buffer-create (format "*HN %d*" id))
      (unless (derived-mode-p 'rata-elfeed-hn-item-mode)
        (rata-elfeed-hn-item-mode))
      (setq rata-elfeed-hn--key id
            rata-elfeed-hn--item id)
      (rata-elfeed-hn--redraw)
      (pop-to-buffer (current-buffer)))))

;;; ------------------------------------------------------------
;;; Keys
;;; ------------------------------------------------------------

(defvar-keymap rata-elfeed-hn-thread-mode-map
  :doc "Keymap for `rata-elfeed-hn-thread-mode'; the evil keys live in its
normal-state auxiliary map.")

(define-minor-mode rata-elfeed-hn-thread-mode
  "Comment folding, navigation and HN commands, in a buffer showing a thread.
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
         ","  '(:ignore t :which-key "hacker news")
         (cl-loop for (key command label) in rata-elfeed-hn--keys
                  append (list key (list command :which-key label))))
  (rata-leader
    :states '(normal visual)
    "arh" '(rata-elfeed-hn-open-item :which-key "HN thread by URL/id")))

(with-eval-after-load 'evil
  (evil-set-initial-state 'rata-elfeed-hn-item-mode 'normal)
  (evil-define-key* 'normal rata-elfeed-hn-item-mode-map "q" #'quit-window))

(with-eval-after-load 'browse-url
  (add-to-list 'browse-url-handlers
               (cons #'rata-elfeed-hn--route-p #'rata-elfeed-hn-browse-url)))

;; After elfeed-show, never before: its `defvar' of the hook carries elfeed's
;; own two functions, and an `add-hook' that ran first would bind the variable
;; and so silently drop them.
(with-eval-after-load 'elfeed-show
  (add-hook 'elfeed-show-update-hook #'rata-elfeed-hn-show-update t))

(provide 'init-elfeed-hn)
