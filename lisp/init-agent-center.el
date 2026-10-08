;;; -*- lexical-binding: t; -*-
;;; init-agent-center.el --- Overview of every live agent-shell session

;; One place that knows, for every agent-shell buffer in every persp layout,
;; which layout and project it belongs to and whether it is working, waiting
;; for you, or finished.  Plan: plans/ai-control-center.md.
;;
;; This file owns no package (like init-claude-loop.el), so there is no
;; `use-package' here.  agent-shell is reached only through its mode hook and
;; runtime `fboundp' checks: requiring it at load would defeat its `:commands'
;; deferral in init-llm.el (L-028).
;;
;; Discipline, borrowed from claude-loop's trampoline: an agent-shell event
;; callback only updates the registry entry and asks for a render.  It never
;; renders, saves or runs hooks itself, and its own errors land on the entry
;; as `error' -- agent-shell would otherwise demote them to a `message'.

(require 'cl-lib)
(require 'map)
(require 'subr-x)

(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-status "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function agent-shell-interrupt "agent-shell")
(declare-function agent-shell-new-shell "agent-shell")
(declare-function get-current-persp "persp-mode")
(declare-function safe-persp-name "persp-mode")
(declare-function persp--buffer-in-persps "persp-mode")
(declare-function persp-name "persp-mode")
(declare-function persp-names "persp-mode")
(declare-function persp-switch "persp-mode")
(declare-function evil-define-key* "evil-core")
(declare-function rata-leader "init-evil")
(declare-function project-root "project")
(eval-when-compile
  (defvar persp-before-deactivate-functions)
  (defvar persp-activated-functions)
  (defvar persp-filter-save-buffers-functions)
  (defvar agent-shell--state)
  (defvar agent-shell-mode-hook))

(defgroup rata-agent-center nil
  "Overview of live agent-shell sessions across persp layouts."
  :group 'tools
  :prefix "rata-agent-center-")

;;; ============================================================
;;; State model (pure)
;;; ============================================================

(defconst rata-agent-center-states
  '(needs-input error done working starting ready)
  "Every shell state, most urgent first.  The order is the sort order.
needs-input  a permission question is open
error        the last request failed
done         a turn finished while you were not looking at the shell
working      the agent is busy
starting     ACP handshake, before the first prompt
ready        idle, and nothing unread")

(defun rata-agent-center--state-rank (state)
  "Return STATE's 1-based position in `rata-agent-center-states'.
An unknown state sorts after every known one."
  (let ((pos (cl-position state rata-agent-center-states)))
    (if pos (1+ pos) (1+ (length rata-agent-center-states)))))

(defun rata-agent-center--next-state (state event visible-p)
  "Return the state that follows STATE on EVENT.
EVENT is an agent-shell event alist (`:event' is the symbol).  The
synthetic event `visited' means the shell became the selected buffer.
VISIBLE-P is non-nil when the shell is the selected window's buffer, which
is what makes a finished turn `ready' rather than `done'.  Events not
named here, including the per-chunk `agent-message-chunk', leave STATE
unchanged."
  (pcase (map-elt event :event)
    ('permission-request 'needs-input)
    ('error 'error)
    ('turn-complete (if visible-p 'ready 'done))
    ((or 'input-submitted 'permission-response) 'working)
    ;; Only the answer closes a permission question: a tool call updating
    ;; alongside it must not hide it.
    ('tool-call-update (if (eq state 'needs-input) state 'working))
    ('init-started 'starting)
    ('prompt-ready 'ready)
    ('visited (if (eq state 'done) 'ready state))
    (_ state)))

(defun rata-agent-center--reconcile (state status visible-p)
  "Return STATE corrected by STATUS, the result of `agent-shell-status'.
Events are the fast path and `agent-shell-status' is the truth: where
the two disagree in a way no event explains, trust the status.  A shell
recorded busy that is now idle finished a turn unseen, so it becomes
`done' -- or `ready' when VISIBLE-P.  `done', `error' and `starting' are
invisible to the status (it only knows busy / blocked / ready), so an
idle status leaves them alone.  A nil STATUS changes nothing."
  (pcase status
    ('blocked 'needs-input)
    ('busy (if (memq state '(working needs-input)) state 'working))
    ('ready (if (memq state '(working needs-input))
                (if visible-p 'ready 'done)
              state))
    (_ state)))

;;; ============================================================
;;; Registry
;;; ============================================================

(defvar rata-agent-center--registry (make-hash-table :test #'eq)
  "Shell buffer -> entry plist.
Keys: :buffer :layout :project :agent :title :state :since
:last-stop-reason :cost :error :token :activity :activity-source
:activity-tool.  :since is the `float-time' the current state was
entered; :token is the agent-shell subscription.  :activity is what the
shell is doing now (see `rata-agent-center--next-activity').")

(defun rata-agent-center--entry (buffer)
  "Return BUFFER's registry entry, or nil."
  (gethash buffer rata-agent-center--registry))

(defun rata-agent-center--put (buffer &rest props)
  "Set PROPS (a plist) on BUFFER's entry.
A change of :state restarts the :since clock; the same state again
does not."
  (when-let* ((entry (rata-agent-center--entry buffer)))
    (while props
      (let ((key (pop props)) (val (pop props)))
        (when (and (eq key :state) (not (eq val (plist-get entry :state))))
          (setq entry (plist-put entry :since (float-time))))
        (setq entry (plist-put entry key val))))
    (puthash buffer entry rata-agent-center--registry)))

(cl-defun rata-agent-center--add-entry
    (buffer &key layout project agent title (state 'starting) token)
  "Create BUFFER's registry entry and return it.  Nothing is subscribed."
  (puthash buffer
           (list :buffer buffer :layout layout :project project :agent agent
                 :title title :state state :since (float-time)
                 :last-stop-reason nil :cost nil :error nil :token token
                 :activity nil :activity-source nil :activity-tool nil)
           rata-agent-center--registry))

(defun rata-agent-center--sweep ()
  "Drop entries whose buffer is dead.
`clean-up' is the normal way out; this catches a buffer killed while
the module was not listening."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             rata-agent-center--registry)
    (dolist (buf dead) (remhash buf rata-agent-center--registry))))

(defun rata-agent-center--visible-p (buffer)
  "Non-nil when BUFFER is the selected window's buffer."
  (eq (window-buffer (selected-window)) buffer))

;;; ------------------------------------------------------------
;;; What an entry is about: layout, project, agent
;;; ------------------------------------------------------------

(defun rata-agent-center--current-layout ()
  "Name of the current persp layout, or nil without persp-mode."
  (when (and (bound-and-true-p persp-mode) (fboundp 'get-current-persp))
    (safe-persp-name (get-current-persp))))

(defun rata-agent-center--layout-for (buffer how)
  "Return the layout name to record for BUFFER.
HOW is `current' for a shell opening now: the layout you are in is the
one it belongs to, since persp does not add a buffer to a layout on a
major-mode change (`persp-add-buffer-on-after-change-major-mode' is nil).
HOW is `adopted' for a shell found already open: the first layout that
holds it, else the current one."
  (or (and (eq how 'adopted)
           (fboundp 'persp--buffer-in-persps)
           (when-let* ((persp (car (persp--buffer-in-persps buffer))))
             (persp-name persp)))
      (rata-agent-center--current-layout)))

(defun rata-agent-center--project (dir)
  "Abbreviated project root of DIR, or DIR itself outside a project."
  (when dir
    (abbreviate-file-name
     (if-let* ((pr (ignore-errors (project-current nil dir))))
         (project-root pr)
       dir))))

(defun rata-agent-center--shell-p (buffer)
  "Non-nil when BUFFER is a live agent-shell buffer."
  (and (buffer-live-p buffer)
       (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                'agent-shell-mode)))

(defun rata-agent-center--shell-state (buffer)
  "BUFFER's `agent-shell--state', or nil."
  (and (boundp 'agent-shell--state)
       (buffer-local-value 'agent-shell--state buffer)))

(defun rata-agent-center--status (buffer)
  "`agent-shell-status' of BUFFER, or nil when it cannot be asked."
  (and (fboundp 'agent-shell-status)
       (rata-agent-center--shell-p buffer)
       (ignore-errors (agent-shell-status :shell-buffer buffer))))

;;; ------------------------------------------------------------
;;; Activity: what a shell is doing right now (pure)
;;; ------------------------------------------------------------

(defconst rata-agent-center--activity-max 240
  "Most characters of streamed message text kept as an entry's :activity.
Only the first line is ever shown, so the rest of a long reply is dropped.")

(defconst rata-agent-center--tool-kind-labels
  '(("execute" . "Bash") ("edit" . "Edit") ("read" . "Read") ("search" . "Search")
    ("fetch" . "Fetch") ("delete" . "Delete") ("move" . "Move") ("think" . "Think"))
  "ACP tool-call kind -> label, for a title that does not start with a verb.
`execute' is `Bash' after Claude's tool name, as in init-claude-loop-acp.el.")

(defun rata-agent-center--tool-activity (tool-call)
  "TOOL-CALL, an agent-shell tool-call alist, as `Label: detail', or nil.
Claude's ACP adapter titles most calls `Verb target' (`Read /x', `Edit
`/x`') and a Bash call as the command in backticks, so a leading
capitalised word is the label, and otherwise the kind is."
  (let* ((kind (map-elt tool-call :kind))
         (command (map-elt tool-call :command))
         (title (string-trim (string-replace "`" "" (or (map-elt tool-call :title) ""))))
         (kind-label (or (cdr (assoc kind rata-agent-center--tool-kind-labels))
                         (and (stringp kind) (not (string-empty-p kind))
                              (capitalize kind)))))
    (cond
     ((and (equal kind "execute") (stringp command) (not (string-empty-p command)))
      (format "%s: %s" kind-label command))
     ((string-empty-p title) nil)
     ((let ((case-fold-search nil))
        (string-match "\\`\\([A-Z][A-Za-z]*\\) +\\(.+\\)" title))
      (format "%s: %s" (match-string 1 title) (match-string 2 title)))
     (kind-label (format "%s: %s" kind-label title))
     (t title))))

(defun rata-agent-center--next-activity (entry event)
  "Activity properties for ENTRY after EVENT, as a plist to `--put', or nil.
A tool call names the activity, and is in flight until it reports
`completed' or `failed'.  Streamed message text replaces it only while no
tool is in flight: the start of a message replaces what was there, later
chunks of the same message append, up to `rata-agent-center--activity-max'.
A new prompt clears it.  Every other event leaves it alone."
  (let ((data (map-elt event :data)))
    (pcase (map-elt event :event)
      ('input-submitted '(:activity nil :activity-source nil :activity-tool nil))
      ('tool-call-update
       (let* ((call (map-elt data :tool-call))
              (id (map-elt data :tool-call-id))
              (finished (member (map-elt call :status) '("completed" "failed")))
              (text (rata-agent-center--tool-activity call)))
         (list :activity (or text (plist-get entry :activity))
               :activity-source 'tool
               :activity-tool (cond ((not finished) id)
                                    ((equal id (plist-get entry :activity-tool)) nil)
                                    (t (plist-get entry :activity-tool))))))
      ('agent-message-chunk
       (let ((chunk (map-elt data :text-chunk)))
         (when (and (stringp chunk) (not (plist-get entry :activity-tool)))
           (let ((text (if (eq (plist-get entry :activity-source) 'message)
                           (concat (plist-get entry :activity) chunk)
                         chunk)))
             (list :activity (if (> (length text) rata-agent-center--activity-max)
                                 (substring text 0 rata-agent-center--activity-max)
                               text)
                   :activity-source 'message))))))))

(defun rata-agent-center--activity-line (entry width)
  "The dim line shown under ENTRY's row, at most WIDTH columns, or nil.
The first non-blank line of its :activity, whitespace squeezed, with the
shell's project root cut from paths.  nil for a `ready' shell (idle and
seen, so last turn's activity is old news), and when there is nothing to
say or no room to say it."
  (let ((activity (plist-get entry :activity))
        (project (plist-get entry :project)))
    (when (and (stringp activity)
               (not (eq (plist-get entry :state) 'ready))
               (> width 3))
      (let ((line (seq-find (lambda (l) (not (string-blank-p l)))
                            (split-string activity "\n"))))
        (when line
          (setq line (string-trim (replace-regexp-in-string "[ \t]+" " " line)))
          (when project
            (dolist (root (list (file-name-as-directory (expand-file-name project))
                                (file-name-as-directory project)))
              (setq line (string-replace root "" line))))
          (truncate-string-to-width line width nil nil "…"))))))

;;; ------------------------------------------------------------
;;; Events
;;; ------------------------------------------------------------

(defconst rata-agent-center--activity-events '(tool-call-update agent-message-chunk)
  "Events that update the activity line and, usually, nothing else.")

(defun rata-agent-center--handle-event (buffer event)
  "Record EVENT, an agent-shell event alist, on BUFFER's entry."
  (let ((kind (map-elt event :event))
        (data (map-elt event :data)))
    (if (eq kind 'clean-up)
        (remhash buffer rata-agent-center--registry)
      (when-let* ((entry (rata-agent-center--entry buffer)))
        (rata-agent-center--put
         buffer :state (rata-agent-center--next-state
                        (plist-get entry :state) event
                        (rata-agent-center--visible-p buffer)))
        (when-let* ((activity (rata-agent-center--next-activity entry event)))
          (apply #'rata-agent-center--put buffer activity))
        (pcase kind
          ('session-title-changed
           (rata-agent-center--put buffer :title (map-elt data :title)))
          ('turn-complete
           (let ((cost (map-elt (map-elt data :usage) :cost-amount)))
             (rata-agent-center--put
              buffer
              :last-stop-reason (map-elt data :stop-reason)
              :cost (and (numberp cost) (> cost 0) cost)
              :error nil)))
          ('error
           (rata-agent-center--put buffer :error (or (map-elt data :message)
                                                      "request failed")))
          ('input-submitted
           (rata-agent-center--put buffer :error nil)))))))

(defun rata-agent-center--make-handler (buffer)
  "Return the agent-shell `:on-event' callback for BUFFER.
It calls `rata-agent-center--handle-event' by name, so a reloaded
module takes effect in shells subscribed before the reload.
An event that changed only the activity line asks for the slower
activity render, so a streaming reply does not reprint five times a second."
  (lambda (event)
    (let ((before (plist-get (rata-agent-center--entry buffer) :state)))
      (condition-case err
          (rata-agent-center--handle-event buffer event)
        (error
         (rata-agent-center--put buffer :state 'error
                                 :error (format "agent-center: %s on %s"
                                                (error-message-string err)
                                                (map-elt event :event)))))
      (if (and (memq (map-elt event :event) rata-agent-center--activity-events)
               (eq before (plist-get (rata-agent-center--entry buffer) :state)))
          (rata-agent-center--schedule-activity-render)
        (rata-agent-center--schedule-render)))))

(defun rata-agent-center--subscribe (buffer)
  "Subscribe to every event in BUFFER and return the token, or nil."
  (when (and (fboundp 'agent-shell-subscribe-to)
             (rata-agent-center--shell-p buffer))
    (agent-shell-subscribe-to :shell-buffer buffer
                              :on-event (rata-agent-center--make-handler buffer))))

(defun rata-agent-center--register (buffer how)
  "Register the shell BUFFER, found HOW (`current' or `adopted').
Does nothing when BUFFER is already registered, so adopting twice, or a
mode hook after an adoption, cannot subscribe twice."
  (unless (rata-agent-center--entry buffer)
    (let* ((state (rata-agent-center--shell-state buffer))
           (status (rata-agent-center--status buffer)))
      (rata-agent-center--add-entry
       buffer
       :layout (rata-agent-center--layout-for buffer how)
       :project (rata-agent-center--project
                 (buffer-local-value 'default-directory buffer))
       :agent (ignore-errors (map-nested-elt state '(:agent-config :buffer-name)))
       :title (ignore-errors (map-nested-elt state '(:session :title)))
       ;; A new shell is handshaking; an adopted one is whatever status says.
       :state (if (eq how 'current)
                  'starting
                (rata-agent-center--reconcile 'ready status nil)))
      (rata-agent-center--put buffer :token (rata-agent-center--subscribe buffer))
      (rata-agent-center--schedule-render))))

(defun rata-agent-center--on-mode-hook ()
  "Register the current buffer, a shell that has just started.
On `agent-shell-mode-hook', which agent-shell runs after its state is
set, so subscribing here works."
  (rata-agent-center--register (current-buffer) 'current))

(defun rata-agent-center--agent-shell-loaded-p ()
  "Non-nil once agent-shell itself has loaded.
`featurep', not `fboundp': `agent-shell-buffers' is an autoload, and
calling it would load agent-shell at startup.  A function of its own so
tests can stub it -- Emacs 31's `featurep' ignores a `let' of `features'."
  (featurep 'agent-shell))

(defun rata-agent-center--adopt ()
  "Register every shell that is already open."
  (when (and (rata-agent-center--agent-shell-loaded-p)
             (fboundp 'agent-shell-buffers))
    (dolist (buf (agent-shell-buffers))
      (rata-agent-center--register buf 'adopted))))

;;; ============================================================
;;; The *Agents* buffer
;;; ============================================================

(defconst rata-agent-center-buffer-name "*Agents*"
  "Name of the overview buffer.")

(defcustom rata-agent-center-side 'right
  "Frame side the *Agents* panel is shown on."
  :type '(choice (const left) (const right) (const top) (const bottom)))

(defcustom rata-agent-center-width 60
  "Width in columns of the *Agents* panel (height, on top or bottom)."
  :type 'integer)

(defcustom rata-agent-center-show-activity t
  "Non-nil to show what each shell is doing on a dim line under its row.
The latest tool call, else the start of the latest agent message."
  :type 'boolean)

(defcustom rata-agent-center-activity-interval 1.0
  "Least seconds between two renders caused only by activity-line changes.
A streaming reply sends a chunk many times a second; state changes are
not held back by this."
  :type 'number)

;; gruvbox, in the style of `rata-persp-active-layout' in init-persp.el.
(defface rata-agent-center-needs-input '((t :foreground "#fe8019" :weight bold))
  "Badge of a shell waiting on a permission answer (gruvbox orange).")
(defface rata-agent-center-error '((t :foreground "#fb4934" :weight bold))
  "Badge of a shell whose last request failed (gruvbox red).")
(defface rata-agent-center-done '((t :foreground "#b8bb26" :weight bold))
  "Badge of a finished turn not yet looked at (gruvbox green).")
(defface rata-agent-center-working '((t :foreground "#fabd2f"))
  "Badge of a busy shell (gruvbox yellow).")
(defface rata-agent-center-starting '((t :foreground "#83a598"))
  "Badge of a shell still handshaking (gruvbox blue).")
(defface rata-agent-center-ready '((t :foreground "#d3869b"))
  "Badge of an idle, seen shell (gruvbox purple).
Not grey: grey reads as disabled and is hard to see on the dark background.")
(defface rata-agent-center-group-heading '((t :inherit bold))
  "Layout heading in the *Agents* panel.")
(defface rata-agent-center-activity '((t :inherit shadow :slant italic))
  "The activity line under a row: dim, since it is detail, not status.")

(defconst rata-agent-center--badges
  '((needs-input "⚠" "input") (error "✗" "error") (done "✓" "done")
    (working "●" "work") (starting "…" "start") (ready "·" "ready"))
  "State -> (GLYPH WORD).  Plain glyphs, so the panel reads the same in a TTY.")

(defun rata-agent-center--badge (state)
  "STATE's badge: glyph and word, in the state's face."
  (let ((badge (alist-get state rata-agent-center--badges)))
    (propertize (format "%s %s" (or (car badge) "?") (or (cadr badge) state))
                'face (intern-soft (format "rata-agent-center-%s" state)))))

(defun rata-agent-center--age (seconds)
  "SECONDS as one short unit: `59s', `3m', `1h', `2d'."
  (let ((s (max 0 (floor seconds))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm" (/ s 60)))
          ((< s 86400) (format "%dh" (/ s 3600)))
          (t (format "%dd" (/ s 86400))))))

(defun rata-agent-center--last (entry)
  "The panel's last column for ENTRY: error, else an unusual stop reason.
`end_turn' is how almost every turn ends, so it is left out, and so is the
cost (still recorded as :cost): the column is for what needs reading."
  (or (plist-get entry :error)
      (let ((reason (plist-get entry :last-stop-reason)))
        (if (member reason '(nil "end_turn")) "" reason))))

(defconst rata-agent-center--title-width 20
  "Width of the Title column; longer titles are cut with an ellipsis.")

(defun rata-agent-center--row (entry now)
  "ENTRY as a `tabulated-list-entries' element, its age measured at NOW."
  (list (plist-get entry :buffer)
        (vector (rata-agent-center--badge (plist-get entry :state))
                (or (plist-get entry :agent) "?")
                (truncate-string-to-width
                 (or (plist-get entry :title) (buffer-name (plist-get entry :buffer)))
                 rata-agent-center--title-width nil nil "…")
                (rata-agent-center--age (- now (or (plist-get entry :since) now)))
                (rata-agent-center--last entry))))

(defun rata-agent-center--entry< (a b)
  "Non-nil when entry A sorts before B: by state, then longest in it."
  (let ((ra (rata-agent-center--state-rank (plist-get a :state)))
        (rb (rata-agent-center--state-rank (plist-get b :state))))
    (or (< ra rb)
        (and (= ra rb) (< (or (plist-get a :since) 0) (or (plist-get b :since) 0))))))

(defvar rata-agent-center--folded nil
  "Layout names whose group is folded in the panel.
Kept here rather than in the buffer, because every render reprints it.")

(defun rata-agent-center--group-heading (layout entries &optional folded)
  "Heading for LAYOUT's group of ENTRIES: `layout — project'.
FOLDED adds how many rows are hidden.  The heading carries its layout and
its single project, if it has one, for commands run on the heading line."
  (let ((projects (delete-dups (delq nil (mapcar (lambda (e) (plist-get e :project))
                                                 entries)))))
    (propertize (concat (format "%s — %s" (or layout "(no layout)")
                                (pcase (length projects)
                                  (0 "?")
                                  (1 (car projects))
                                  (n (format "%d projects" n))))
                        (if folded (format "  [%d hidden]" (length entries)) ""))
                'face 'rata-agent-center-group-heading
                'rata-agent-center-heading t
                'rata-agent-center-layout layout
                'rata-agent-center-project (and (= (length projects) 1) (car projects)))))

(defun rata-agent-center--groups (entries now &optional folded)
  "ENTRIES (plists) grouped by layout, in `tabulated-list-groups' form.
Rows sort by state within a group; groups sort by their most urgent row,
then by layout name.  A group whose layout is in FOLDED prints its
heading only."
  (let (groups)
    (dolist (entry entries)
      (let* ((layout (plist-get entry :layout))
             (cell (assoc layout groups)))
        (if cell
            (push entry (cdr cell))
          (push (list layout entry) groups))))
    (setq groups (mapcar (lambda (g) (cons (car g) (sort (cdr g) #'rata-agent-center--entry<)))
                         groups))
    (setq groups (sort groups
                       (lambda (a b)
                         (let ((ra (rata-agent-center--state-rank (plist-get (cadr a) :state)))
                               (rb (rata-agent-center--state-rank (plist-get (cadr b) :state))))
                           (or (< ra rb)
                               (and (= ra rb) (string< (or (car a) "") (or (car b) ""))))))))
    (mapcar (lambda (g)
              (let ((fold (member (car g) folded)))
                (cons (rata-agent-center--group-heading (car g) (cdr g) fold)
                      (unless fold
                        (mapcar (lambda (e) (rata-agent-center--row e now)) (cdr g))))))
            groups)))

(defun rata-agent-center--reconcile-all ()
  "Correct every entry's state against `agent-shell-status'."
  (maphash (lambda (buf entry)
             (let ((state (rata-agent-center--reconcile
                           (plist-get entry :state) (rata-agent-center--status buf)
                           (rata-agent-center--visible-p buf))))
               (unless (eq state (plist-get entry :state))
                 (rata-agent-center--put buf :state state))))
           rata-agent-center--registry))

(defun rata-agent-center--fill ()
  "Recompute the current *Agents* buffer's groups from the registry."
  (rata-agent-center--sweep)
  (rata-agent-center--reconcile-all)
  (let ((groups (rata-agent-center--groups
                 (hash-table-values rata-agent-center--registry) (float-time)
                 rata-agent-center--folded)))
    (setq tabulated-list-groups groups
          tabulated-list-entries (apply #'append (mapcar #'cdr groups)))))

(defconst rata-agent-center--activity-prefix "   ↳ "
  "Indent and marker of the activity line, under the row's State column.")

(defun rata-agent-center--print-entry (id cols)
  "The `tabulated-list-printer': the row, then its activity line if any.
The activity line carries the row's `tabulated-list-id', so every command
that acts on a row acts on it too, and `rata-agent-center-activity' so
row-to-row motion can step over it.  Correct only because the panel has
no sort key: `tabulated-list-print' then reprints in full, never through
its one-line-per-entry incremental update."
  (tabulated-list-print-entry id cols)
  (when-let* ((rata-agent-center-show-activity)
              (entry (rata-agent-center--entry id))
              (win-width (if-let* ((win (get-buffer-window (current-buffer) t)))
                             (window-width win)
                           rata-agent-center-width))
              (line (rata-agent-center--activity-line
                     entry (- win-width (string-width rata-agent-center--activity-prefix) 1))))
    (insert (propertize (concat rata-agent-center--activity-prefix line "\n")
                        'face 'rata-agent-center-activity
                        'tabulated-list-id id
                        'tabulated-list-entry cols
                        'rata-agent-center-activity t))))

(define-derived-mode rata-agent-center-mode tabulated-list-mode "Agents"
  "Every live agent-shell session, grouped by persp layout."
  (setq tabulated-list-format
        `[("State" 7 nil) ("Agent" 6 nil) ("Title" ,rata-agent-center--title-width nil) ("Age" 4 nil) ("Last" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil
        tabulated-list-printer #'rata-agent-center--print-entry)
  (add-hook 'tabulated-list-revert-hook #'rata-agent-center--fill nil t)
  (tabulated-list-init-header))

(defun rata-agent-center--refresh-buffer ()
  "Print the registry into *Agents*, creating it, and return the buffer."
  (let ((buf (get-buffer-create rata-agent-center-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'rata-agent-center-mode)
        (rata-agent-center-mode))
      (rata-agent-center--fill)
      (tabulated-list-print t))
    buf))

;;; ------------------------------------------------------------
;;; Rendering: debounced, and only while someone can see it
;;; ------------------------------------------------------------

(defvar rata-agent-center--render-timer nil
  "The one pending render timer, or nil.")

(defvar rata-agent-center--age-timer nil
  "Repeating timer that refreshes the Age column while the panel is shown.")

(defun rata-agent-center--panel-windows (&optional frame)
  "Windows showing *Agents* on FRAME (default: every frame)."
  (when-let* ((buf (get-buffer rata-agent-center-buffer-name)))
    (get-buffer-window-list buf nil (or frame t))))

(defvar rata-agent-center--render-due nil
  "`float-time' at which the armed render timer fires, or nil.")

(defvar rata-agent-center--last-render 0
  "`float-time' of the last render, for `rata-agent-center-activity-interval'.")

(defconst rata-agent-center--render-delay 0.2
  "Debounce, in seconds, between an event and the render it asks for.")

(defun rata-agent-center--render ()
  "Reprint *Agents* if it is shown anywhere; otherwise just sweep.
Either way the mode-line segment is redrawn, since it is always shown."
  (setq rata-agent-center--render-timer nil
        rata-agent-center--render-due nil
        rata-agent-center--last-render (float-time))
  (if (rata-agent-center--panel-windows)
      (rata-agent-center--refresh-buffer)
    (rata-agent-center--sweep))
  (force-mode-line-update t))

(defun rata-agent-center--arm-render (delay)
  "Make sure a render happens within DELAY seconds, with one timer.
An armed timer due sooner already covers it; one due later is replaced.
The 50 ms slack keeps a burst of activity, whose deadline is recomputed
from a fresh clock each time, from re-arming over float rounding."
  (let ((due (+ (float-time) delay)))
    (unless (and (timerp rata-agent-center--render-timer)
                 rata-agent-center--render-due
                 (<= rata-agent-center--render-due (+ due 0.05)))
      (when (timerp rata-agent-center--render-timer)
        (cancel-timer rata-agent-center--render-timer))
      (setq rata-agent-center--render-due due
            rata-agent-center--render-timer
            (run-with-timer delay nil #'rata-agent-center--render)))))

(defun rata-agent-center--schedule-render ()
  "Arm one short timer to render, unless one is already armed sooner.
Event callbacks call this instead of rendering: they run inside
agent-shell's event dispatch, where rendering does not belong."
  (rata-agent-center--arm-render rata-agent-center--render-delay))

(defun rata-agent-center--schedule-activity-render ()
  "Ask for a render after an activity-only change, at most once per interval.
Nothing at all when activity lines are off or the panel is not shown:
the mode line does not show activity."
  (when (and rata-agent-center-show-activity (rata-agent-center--panel-windows))
    (rata-agent-center--arm-render
     (max rata-agent-center--render-delay
          (- rata-agent-center-activity-interval
             (- (float-time) rata-agent-center--last-render))))))

(defun rata-agent-center--age-tick ()
  "Refresh the Age column; stop ticking once the panel is gone."
  (if (rata-agent-center--panel-windows)
      (rata-agent-center--refresh-buffer)
    (when (timerp rata-agent-center--age-timer)
      (cancel-timer rata-agent-center--age-timer))
    (setq rata-agent-center--age-timer nil)))

;;; ------------------------------------------------------------
;;; The side window, and keeping it across layout switches
;;; ------------------------------------------------------------

(defvar rata-agent-center--pinned nil
  "Non-nil while the panel should be shown in every layout.
Set by opening the panel, cleared by closing it.")

(defun rata-agent-center--display ()
  "Show *Agents* in its side window on the selected frame; return the window."
  (display-buffer-in-side-window
   (rata-agent-center--refresh-buffer)
   `((side . ,rata-agent-center-side)
     (slot . 0)
     (window-width . ,rata-agent-center-width)
     (window-height . ,rata-agent-center-width)
     (preserve-size . (t . nil))
     (dedicated . t)
     (window-parameters (no-delete-other-windows . t)))))

(defun rata-agent-center--delete-panel (frame)
  "Delete every *Agents* window on FRAME."
  (dolist (win (rata-agent-center--panel-windows frame))
    (ignore-errors (delete-window win))))

(defun rata-agent-center--before-persp-deactivate (type frame-or-window _persp)
  "Take the panel off FRAME-OR-WINDOW before persp saves the layout.
persp saves a layout's window configuration, side windows included, and
restores it on switch (L-053).  Kept out of every saved configuration,
the panel cannot come back in a layout it was closed in, nor twice."
  (when (and (eq type 'frame) (frame-live-p frame-or-window))
    (rata-agent-center--delete-panel frame-or-window)))

(defun rata-agent-center--after-persp-activate (type frame-or-window _persp)
  "Put the panel back on FRAME-OR-WINDOW after a layout switch, if pinned."
  (when (and rata-agent-center--pinned (eq type 'frame) (frame-live-p frame-or-window))
    (with-selected-frame frame-or-window
      (rata-agent-center--display))))

(defun rata-agent-center--persp-save-filter (buffer)
  "Non-nil for *Agents*, which is never written into a persp state file.
persp's default filter already skips `*'-named buffers; this one does not
depend on that default."
  (equal (buffer-name buffer) rata-agent-center-buffer-name))

(with-eval-after-load 'persp-mode
  (add-hook 'persp-before-deactivate-functions #'rata-agent-center--before-persp-deactivate)
  (add-hook 'persp-activated-functions #'rata-agent-center--after-persp-activate)
  (add-to-list 'persp-filter-save-buffers-functions #'rata-agent-center--persp-save-filter))

;;; ------------------------------------------------------------
;;; Commands
;;; ------------------------------------------------------------

(defun rata-agent-center-open ()
  "Show the *Agents* panel, pin it across layouts, and select it."
  (interactive)
  (setq rata-agent-center--pinned t)
  (select-window (rata-agent-center--display))
  (unless (timerp rata-agent-center--age-timer)
    (setq rata-agent-center--age-timer
          (run-with-timer 30 30 #'rata-agent-center--age-tick))))

(defun rata-agent-center-close ()
  "Close the *Agents* panel on every frame and unpin it."
  (interactive)
  (setq rata-agent-center--pinned nil)
  (dolist (frame (frame-list))
    (rata-agent-center--delete-panel frame)))

(defun rata-agent-center-toggle ()
  "Open the *Agents* panel, or close it when it is shown on this frame."
  (interactive)
  (if (rata-agent-center--panel-windows (selected-frame))
      (rata-agent-center-close)
    (rata-agent-center-open)))

(defun rata-agent-center-refresh ()
  "Reprint *Agents* now."
  (interactive)
  (rata-agent-center--refresh-buffer))

(defun rata-agent-center--row-shell ()
  "The shell buffer on this line, or a `user-error'."
  (let ((shell (tabulated-list-get-id)))
    (unless (buffer-live-p shell)
      (user-error "No live agent shell on this line"))
    shell))

(defun rata-agent-center--main-window ()
  "The most recently used window that is not a side window."
  (or (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                (cons (get-mru-window nil nil nil)
                      (window-list nil 'nomini)))
      (user-error "No main window to show the shell in")))

(defun rata-agent-center--show-in-main (shell)
  "Show SHELL in a main (non-side) window of this frame; return the window."
  (let ((win (or (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                           (get-buffer-window-list shell nil nil))
                 (rata-agent-center--main-window))))
    (set-window-buffer win shell)
    win))

(defun rata-agent-center--mark-visited (shell)
  "Record that SHELL has been looked at: `done' becomes `ready'."
  (when-let* ((entry (rata-agent-center--entry shell)))
    (rata-agent-center--put shell :state (rata-agent-center--next-state
                                          (plist-get entry :state)
                                          '((:event . visited)) t))
    (rata-agent-center--schedule-render)))

(defun rata-agent-center--switch-layout (layout)
  "Switch to persp LAYOUT when it still exists and is not current."
  (when (and layout (bound-and-true-p persp-mode) (fboundp 'persp-switch)
             (not (equal layout (rata-agent-center--current-layout)))
             (member layout (persp-names)))
    (persp-switch layout)))

(defun rata-agent-center-visit ()
  "Go to this line's shell: its layout, then the shell in the main window."
  (interactive)
  (let* ((shell (rata-agent-center--row-shell))
         (entry (rata-agent-center--entry shell)))
    (rata-agent-center--switch-layout (plist-get entry :layout))
    (select-window (rata-agent-center--show-in-main shell))
    (rata-agent-center--mark-visited shell)))

(defun rata-agent-center-show ()
  "Show this line's shell in the main window, keeping focus in the panel."
  (interactive)
  (let ((shell (rata-agent-center--row-shell)))
    (rata-agent-center--show-in-main shell)
    (rata-agent-center--mark-visited shell)))

;;; ------------------------------------------------------------
;;; Attention: what needs you, and getting there
;;; ------------------------------------------------------------

(defconst rata-agent-center--attention-states '(needs-input error done)
  "States that need you.  `working', `starting' and `ready' do not.")

(defun rata-agent-center--most-urgent ()
  "The registry entry that most needs you, or nil.
Most urgent state first; within a state, the one waiting longest."
  (rata-agent-center--sweep)
  (rata-agent-center--reconcile-all)
  (car (sort (seq-filter (lambda (e) (memq (plist-get e :state)
                                           rata-agent-center--attention-states))
                         (hash-table-values rata-agent-center--registry))
             #'rata-agent-center--entry<)))

(defun rata-agent-center-next-attention ()
  "Go straight to the shell that most needs you, panel or not."
  (interactive)
  (let ((entry (or (rata-agent-center--most-urgent)
                   (user-error "No agent needs you"))))
    (rata-agent-center--switch-layout (plist-get entry :layout))
    (select-window (rata-agent-center--show-in-main (plist-get entry :buffer)))
    (rata-agent-center--mark-visited (plist-get entry :buffer))))

(defun rata-agent-center--attention-row-p ()
  "Non-nil when this line is a row whose shell needs you.
Never on an activity line, which belongs to the row above it."
  (when-let* (((not (get-text-property (point) 'rata-agent-center-activity)))
              (shell (tabulated-list-get-id))
              (entry (rata-agent-center--entry shell)))
    (memq (plist-get entry :state) rata-agent-center--attention-states)))

(defun rata-agent-center--goto-attention-row (direction)
  "Move to the next row needing you in DIRECTION (1 or -1); stay put if none."
  (let ((start (point)) found)
    (while (and (not found) (zerop (forward-line direction)) (not (eobp)))
      (setq found (rata-agent-center--attention-row-p)))
    (if found
        (goto-char (line-beginning-position))
      (goto-char start)
      (message "No %s agent needs you" (if (> direction 0) "later" "earlier")))))

(defun rata-agent-center-next-attention-row ()
  "Move to the next row whose shell needs you."
  (interactive)
  (rata-agent-center--goto-attention-row 1))

(defun rata-agent-center-previous-attention-row ()
  "Move to the previous row whose shell needs you."
  (interactive)
  (rata-agent-center--goto-attention-row -1))

(defun rata-agent-center--on-window-change (frame)
  "Mark the selected window's shell as seen: `done' becomes `ready'.
On the global `window-selection-change-functions' and
`window-buffer-change-functions', so it covers both moving to the
shell's window and showing the shell in the window you are in."
  (when (eq frame (selected-frame))
    (let ((buf (window-buffer (frame-selected-window frame))))
      (when (eq (plist-get (rata-agent-center--entry buf) :state) 'done)
        (rata-agent-center--mark-visited buf)))))

;;; ------------------------------------------------------------
;;; Groups and actions on a row
;;; ------------------------------------------------------------

(defun rata-agent-center--line-layout ()
  "The layout of this line's group, and whether there is one, as (FOUND . LAYOUT)."
  (if (get-text-property (line-beginning-position) 'rata-agent-center-heading)
      (cons t (get-text-property (line-beginning-position) 'rata-agent-center-layout))
    (when-let* ((entry (rata-agent-center--entry (tabulated-list-get-id))))
      (cons t (plist-get entry :layout)))))

(defun rata-agent-center--goto-heading (layout)
  "Move to the heading line of LAYOUT's group."
  (goto-char (point-min))
  (while (and (not (and (get-text-property (point) 'rata-agent-center-heading)
                        (equal (get-text-property (point) 'rata-agent-center-layout)
                               layout)))
              (zerop (forward-line 1))
              (not (eobp)))))

(defun rata-agent-center-toggle-group ()
  "Fold or unfold the group of this line, heading or row."
  (interactive)
  (let ((found (or (rata-agent-center--line-layout)
                   (user-error "Not on a group"))))
    (setq rata-agent-center--folded
          (if (member (cdr found) rata-agent-center--folded)
              (delete (cdr found) rata-agent-center--folded)
            (cons (cdr found) rata-agent-center--folded)))
    (rata-agent-center--fill)
    (tabulated-list-print)
    (rata-agent-center--goto-heading (cdr found))))

(defun rata-agent-center-interrupt ()
  "Interrupt this line's shell, after asking."
  (interactive)
  (let* ((shell (rata-agent-center--row-shell))
         (entry (rata-agent-center--entry shell)))
    (when (y-or-n-p (format "Interrupt %s? " (or (plist-get entry :title)
                                                 (buffer-name shell))))
      (with-current-buffer shell
        ;; FORCE: we have just asked; agent-shell would ask again.
        (agent-shell-interrupt t)))))

(defun rata-agent-center-new-shell ()
  "Start a new agent-shell in this line's layout and project."
  (interactive)
  (let* ((on-heading (get-text-property (line-beginning-position)
                                        'rata-agent-center-heading))
         (entry (unless on-heading (rata-agent-center--entry (tabulated-list-get-id))))
         (layout (cdr (rata-agent-center--line-layout)))
         (project (if on-heading
                      (get-text-property (line-beginning-position)
                                         'rata-agent-center-project)
                    (plist-get entry :project))))
    (rata-agent-center--switch-layout layout)
    ;; Never open the shell in the dedicated panel window.
    (select-window (rata-agent-center--main-window))
    (let ((default-directory (if (and project (file-directory-p project))
                                 (file-name-as-directory (expand-file-name project))
                               default-directory)))
      (call-interactively #'agent-shell-new-shell))))

;; `rata-agent-center-mode' derives from `tabulated-list-mode', whose keys evil's
;; normal state shadows, so they go through `evil-define-key*' -- the function;
;; the `evil-define-key' macro would compile to a broken call here.
(with-eval-after-load 'evil
  (evil-define-key* 'normal rata-agent-center-mode-map
    (kbd "RET") #'rata-agent-center-visit
    (kbd "o")   #'rata-agent-center-show
    (kbd "q")   #'rata-agent-center-close
    (kbd "g r") #'rata-agent-center-refresh
    (kbd "]]")  #'rata-agent-center-next-attention-row
    (kbd "[[")  #'rata-agent-center-previous-attention-row
    (kbd "TAB") #'rata-agent-center-toggle-group
    (kbd "za")  #'rata-agent-center-toggle-group
    (kbd "c")   #'rata-agent-center-new-shell
    (kbd "K")   #'rata-agent-center-interrupt))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aio" '(rata-agent-center-toggle :which-key "agents overview")
    "ain" '(rata-agent-center-next-attention :which-key "next agent needing you")))

;;; ============================================================
;;; Ambient signal: the mode-line segment
;;; ============================================================
;; So the panel need not be open.  No desktop notifications (operator, 2026-09-30).

(defconst rata-agent-center--mode-line-states '(needs-input error done working)
  "States counted in the mode line, in display order.")

(defconst rata-agent-center--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'rata-agent-center-toggle)
    map)
  "Keymap on the mode-line segment: a click toggles the panel.")

(defun rata-agent-center--counts ()
  "Live shells per state, as an alist in `rata-agent-center-states' order.
Only states with at least one shell appear.  Reads, never sweeps: this
runs from redisplay."
  (let (counts)
    (maphash (lambda (buf entry)
               (when (buffer-live-p buf)
                 (cl-incf (alist-get (plist-get entry :state) counts 0))))
             rata-agent-center--registry)
    (seq-keep (lambda (state) (when-let* ((n (alist-get state counts))) (cons state n)))
              rata-agent-center-states)))

(defun rata-agent-center--mode-line-text (counts)
  "The segment for COUNTS, e.g. `⚠2 ✓1 ●3'; the empty string when all are zero."
  (string-join
   (delq nil
         (mapcar (lambda (state)
                   (when-let* ((n (alist-get state counts))
                               ((> n 0)))
                     (propertize (format "%s%d" (car (alist-get state rata-agent-center--badges)) n)
                                 'face (intern-soft (format "rata-agent-center-%s" state))
                                 'local-map rata-agent-center--mode-line-map
                                 'mouse-face 'mode-line-highlight
                                 'help-echo (format "%d agent%s %s — mouse-1: agents panel"
                                                    n (if (= n 1) "" "s") state))))
                 rata-agent-center--mode-line-states))
   " "))

(defun rata-agent-center--mode-line-segment ()
  "The segment as shown: a leading space, or nothing at all."
  (let ((text (rata-agent-center--mode-line-text (rata-agent-center--counts))))
    (if (string-empty-p text) "" (concat " " text))))

(defvar rata-agent-center-mode-line '(:eval (rata-agent-center--mode-line-segment))
  "Mode-line construct for the agent counts, on `global-mode-string'.
doom-modeline shows `global-mode-string' in its `misc-info' segment.")
(put 'rata-agent-center-mode-line 'risky-local-variable t)

(add-to-list 'global-mode-string 'rata-agent-center-mode-line t)

;;; ============================================================
;;; Enable / disable
;;; ============================================================

(defun rata-agent-center-enable ()
  "Start tracking agent-shell sessions, adopting any already open."
  (interactive)
  (add-hook 'agent-shell-mode-hook #'rata-agent-center--on-mode-hook)
  (add-hook 'window-selection-change-functions #'rata-agent-center--on-window-change)
  (add-hook 'window-buffer-change-functions #'rata-agent-center--on-window-change)
  (rata-agent-center--adopt))

(defun rata-agent-center-disable ()
  "Stop tracking: unhook, unsubscribe from every shell, empty the registry."
  (interactive)
  (remove-hook 'agent-shell-mode-hook #'rata-agent-center--on-mode-hook)
  (remove-hook 'window-selection-change-functions #'rata-agent-center--on-window-change)
  (remove-hook 'window-buffer-change-functions #'rata-agent-center--on-window-change)
  (maphash (lambda (buf entry)
             (when-let* ((token (plist-get entry :token))
                         ((buffer-live-p buf))
                         ((fboundp 'agent-shell-unsubscribe)))
               (with-current-buffer buf
                 (ignore-errors (agent-shell-unsubscribe :subscription token)))))
           rata-agent-center--registry)
  (clrhash rata-agent-center--registry)
  (when (timerp rata-agent-center--render-timer)
    (cancel-timer rata-agent-center--render-timer))
  (setq rata-agent-center--render-timer nil
        rata-agent-center--render-due nil))

;; The hook needs nothing loaded; adoption needs `agent-shell-buffers', so it
;; runs again once agent-shell arrives (and at once after `SPC q r').
(rata-agent-center-enable)
(with-eval-after-load 'agent-shell
  (rata-agent-center--adopt))

(provide 'init-agent-center)
