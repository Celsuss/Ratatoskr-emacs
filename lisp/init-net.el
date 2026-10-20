;;; -*- lexical-binding: t; -*-
;;; init-net.el --- Fetching a URL with curl, and shr's images through it

;; One retrieve function for every module in this config that has to pull
;; something off the web itself, and the glue that makes `shr' use it for the
;; images in a page it renders.  It owns no package: `make-process',
;; `url-retrieve' and `shr' are built in.
;;
;; It exists because url.el does not race IPv6 against IPv4 the way curl does
;; (happy eyeballs).  On a network that hands out an IPv6 address and a default
;; route but carries no IPv6 traffic -- an ordinary RA from a router with no
;; working upstream, which is also what a VPN here produces -- every host that
;; publishes an AAAA record is unreachable from url.el while curl fetches it in
;; under a second.  Measured on 21 image hosts taken out of the elfeed db: the
;; eight with a real AAAA record (Cloudflare, Fastly, Substack, xkcd,
;; Wikimedia) never answered at all, the rest took 1-9 seconds (FAIL-0024,
;; FAIL-0027).
;;
;; That is fatal for images in particular, because shr fetches them with
;; `url-queue-retrieve', whose `url-queue-timeout' is five seconds: the job is
;; killed and shr's grey `shr-make-placeholder-image' rectangle stays where the
;; picture should be, for good.  `rata-net-with-shr-images' records the
;; requests shr makes instead of sending them, fetches them here, and hands
;; each arrival back to shr's own `shr-replace-image', so placeholders, sizing
;; and image keys stay shr's.
;;
;; Two rules hold the async part together, the same ones the claude-loop and
;; the HN reader follow:
;;
;; - `rata-net-retrieve' is the only function here that touches the network, so
;;   a test replaces exactly one function.
;; - Every reply is delivered from a zero-delay timer, never from inside url.el's
;;   or a process's own callback, and an error in it becomes a result, not a
;;   signal.

(require 'cl-lib)
(require 'subr-x)

(declare-function shr-replace-image "shr" (data start end &optional flags))

(defgroup rata-net nil
  "Fetching URLs with curl, for shr images and for modules that need bytes."
  :group 'rata)

(eval-when-compile
  ;; Set by url.el in its response buffer; declared so that compiling this
  ;; file without url-http loaded is quiet.
  (defvar url-http-response-status)
  (defvar url-http-content-type)
  (defvar url-http-end-of-headers))

(defcustom rata-net-timeout 20
  "Seconds before a request is abandoned and reported as timed out."
  :type 'number)

(defun rata-net--read-response (status max-bytes)
  "Turn the current url.el response buffer into a result plist.
STATUS is url.el's status list.  Returns (:ok t :type TYPE :body STRING)
or (:error REASON).  A body over MAX-BYTES is an error, not a truncation;
MAX-BYTES nil means no cap."
  (condition-case err
      (cond
       ((plist-get status :error)
        (list :error (rata-net--error-reason (plist-get status :error))))
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
            (rata-net--ok-result
             ctype (buffer-substring-no-properties
                    (1+ url-http-end-of-headers) (point-max))))))))
    (error (list :error (error-message-string err)))))

(defun rata-net--text-type-p (type)
  "Non-nil when the MIME TYPE is text to decode, not bytes to keep."
  (string-match-p "\\`text/\\|json\\|xml\\|javascript" type))

(defun rata-net--ok-result (ctype bytes)
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
          :body (if (and (rata-net--text-type-p type)
                         (not (string-prefix-p "image/" type)))
                    (decode-coding-string bytes coding)
                  bytes))))

(defun rata-net--error-reason (err)
  "Return a short reason string for url.el error ERR."
  (pcase err
    (`(error http ,code) (format "HTTP %s" code))
    (`(,_ . ,data) (format "%s" (if (consp data) (car (last data)) data)))
    (_ (format "%s" err))))

(defcustom rata-net-curl-program "curl"
  "The curl executable, or nil to fetch with Emacs's own url.el.
curl is the default because it races IPv6 against IPv4 (happy eyeballs)
and url.el does not: on a network that hands out an IPv6 address but
does not route it, url.el waits out a connect timeout on every site that
publishes an AAAA record -- most of Cloudflare -- and the article reads
\"timed out\".  url.el is used when curl is not on PATH."
  :type '(choice (string :tag "Program") (const :tag "url.el" nil)))

(defconst rata-net--curl-status-format "\n%{http_code} %{content_type}"
  "curl --write-out format: a last line with the status and content type.")

(defun rata-net--curl-args (url max-bytes timeout)
  "Return curl's arguments for fetching URL.  Pure.
MAX-BYTES (nil: no cap) stops a download the server declares too big;
TIMEOUT is in seconds."
  `("--silent" "--show-error" "--location" "--compressed"
    "--max-time" ,(number-to-string timeout)
    ,@(when max-bytes (list "--max-filesize" (number-to-string max-bytes)))
    "--write-out" ,rata-net--curl-status-format
    "--" ,url))

(defun rata-net--curl-result (output exit stderr max-bytes)
  "Turn a finished curl run into a result plist.  Pure.
OUTPUT is its raw stdout -- the body, then the status line that
`rata-net--curl-status-format' appends; EXIT its exit code; STDERR
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
     (t (rata-net--ok-result ctype body)))))

(defun rata-net--curl-retrieve (program url max-bytes finish)
  "Fetch URL with curl PROGRAM; call FINISH with the result plist.
Return the process."
  (let* ((out (generate-new-buffer " *rata-net-curl*"))
         (err (generate-new-buffer " *rata-net-curl-err*"))
         ;; An explicit pipe, so its own "Process ... finished" line is not
         ;; written into the error text.
         (err-pipe (make-pipe-process :name "rata-net-curl-err" :buffer err
                                      :noquery t :sentinel #'ignore)))
    (with-current-buffer out (set-buffer-multibyte nil))
    (make-process
     :name "rata-net-curl"
     :buffer out
     :stderr err-pipe
     :coding 'binary
     :connection-type 'pipe
     :noquery t
     :command (cons program (rata-net--curl-args url max-bytes rata-net-timeout))
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (unwind-protect
             (funcall finish
                      (condition-case e
                          (rata-net--curl-result
                           (with-current-buffer out (buffer-string))
                           (process-exit-status proc)
                           (with-current-buffer err (buffer-string))
                           max-bytes)
                        (error (list :error (error-message-string e)))))
           (kill-buffer out)
           ;; The stderr pipe has a process of its own; let it go with the buffer.
           (when-let* ((ep (get-buffer-process err))) (delete-process ep))
           (kill-buffer err)))))))

(defun rata-net--url-retrieve (url max-bytes finish)
  "Fetch URL with url.el; call FINISH with the result plist.
Return the response buffer."
  (url-retrieve url
                (lambda (status)
                  (funcall finish (rata-net--read-response status max-bytes))
                  (kill-buffer (current-buffer)))
                nil t t))

(defun rata-net-retrieve (url max-bytes callback)
  "Fetch URL and call CALLBACK with a result plist, from a timer.
The only function in this module that touches the network: through curl
when `rata-net-curl-program' is on PATH, else url.el.  The result
is (:ok t :type CONTENT-TYPE :body STRING) or (:error REASON); CALLBACK
is called exactly once, even when the request times out or never starts.
A body over MAX-BYTES (nil: no cap) is an error."
  (let* ((done nil)
         (finish (lambda (result)
                   (unless done
                     (setq done t)
                     (run-at-time 0 nil callback result)))))
    (condition-case err
        (let* ((curl (and rata-net-curl-program
                          (executable-find rata-net-curl-program)))
               (handle (if curl
                           (rata-net--curl-retrieve curl url max-bytes finish)
                         (rata-net--url-retrieve url max-bytes finish))))
          ;; curl enforces --max-time itself; this is the backstop for both,
          ;; a little later so that curl's own verdict normally wins.
          (run-at-time (+ rata-net-timeout 2) nil
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

;;; ------------------------------------------------------------
;;; Guards: a reply is drawn only into the buffer it was fetched for
;;; ------------------------------------------------------------

(defun rata-net-make-guard (buffer &optional validp)
  "Return a guard for BUFFER: a function of FN returning a callback.
The callback runs FN in BUFFER only while BUFFER is live and VALIDP --
called with no arguments, in BUFFER -- returns non-nil; otherwise it is
a no-op, so a reply that arrives after the buffer has moved on is
dropped rather than drawn into whatever is there now.  An error in FN is
reported with `message' and never signalled: these callbacks run from a
timer, where a signal is a line in *Messages* nobody reads.

VALIDP must capture what it compares against when the guard is made --
that is the whole point of making one before the request goes out."
  (lambda (fn)
    (lambda (&rest args)
      (when (and (buffer-live-p buffer)
                 (or (null validp)
                     (with-current-buffer buffer (funcall validp))))
        (with-current-buffer buffer
          (condition-case err
              (apply fn args)
            (error (message "rata-net: %s" (error-message-string err)))))))))

;;; ------------------------------------------------------------
;;; shr's images, fetched here instead of by url.el
;;; ------------------------------------------------------------

(defcustom rata-net-max-images 40
  "Most images fetched for one article; the rest keep their placeholder."
  :type 'integer)

(defcustom rata-net-image-max-bytes (* 5 1024 1024)
  "Largest image fetched, in bytes."
  :type 'integer)

(defconst rata-net--image-parallel 6
  "Images fetched at once.")

(defun rata-net--place-image (result buffer start end flags)
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

(defun rata-net-fetch-images (requests &optional guard)
  "Fetch shr's image REQUESTS, a few at a time, into the current buffer.
REQUESTS are (URL BUFFER START END FLAGS), as shr handed them to
`url-queue-retrieve'.  At most `rata-net-max-images' are fetched.
GUARD is what `rata-net-make-guard' returns, and defaults to one that
only requires the buffer to be live.  Each arrival is guarded, and a
rejected one stops the queue rather than going on filling a buffer that
has moved on."
  (let* ((queue (seq-take requests rata-net-max-images))
         (buffer (current-buffer))
         (guard (or guard (rata-net-make-guard buffer)))
         next)
    (setq next
          (lambda ()
            (when-let* ((request (pop queue)))
              (rata-net-retrieve
               (car request) rata-net-image-max-bytes
               (funcall
                guard
                (lambda (result)
                  (unwind-protect
                      (pcase-let ((`(,_ ,start ,end ,flags) (cdr request)))
                        (rata-net--place-image result buffer start end flags))
                    (funcall next))))))))
    (dotimes (_ rata-net--image-parallel)
      (funcall next))))

(defmacro rata-net-with-shr-images (guard &rest body)
  "Run BODY, fetching the images `shr' asks for through `rata-net-retrieve'.
While BODY runs, `url-queue-retrieve' records its arguments instead of
sending anything, so shr renders exactly as it always does -- grey
placeholder, markers, image keys -- and nothing is fetched by url.el.
The recorded requests are then fetched here, into the buffer that is
current when BODY returns.  GUARD is evaluated after BODY, only when
there is something to fetch, and must return what `rata-net-make-guard'
returns.  BODY's value is returned.

Nesting is harmless: the inner form takes the requests and the outer one
finds none."
  (declare (indent 1) (debug (form body)))
  (let ((requests (gensym "rata-net-requests")))
    `(let ((,requests nil))
       (prog1 (cl-letf (((symbol-function 'url-queue-retrieve)
                         (lambda (url _callback cbargs &rest _)
                           (push (cons url cbargs) ,requests))))
                ,@body)
         (when ,requests
           (rata-net-fetch-images (nreverse ,requests) ,guard))))))

(provide 'init-net)
