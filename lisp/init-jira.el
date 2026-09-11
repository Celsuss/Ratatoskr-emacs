;;; -*- lexical-binding: t; -*-
;;; init-jira.el --- Jira issue browsing (jira.el)
;;
;; A read-mostly second view onto work tasks: Jira stays in Jira and gets its own
;; buffer, `work_tasks.org' stays hand-written.  The list carries a Sprint column
;; and is grouped into one heading per open sprint plus the backlog, so what is on
;; the board is visible at a glance, and an Org column marks the issues that already
;; have a heading in `work_tasks.org'.  `, i' appends the ones that do not, as new
;; TODO headings keyed on a `:JIRA:' property -- one direction, append-only, on
;; demand (D-019); nothing is ever synced back and no existing heading is rewritten.
;; The one thing written back to Jira besides what jira.el already offers is sprint
;; membership (`, m', Agile REST API), because the team board is a never-ending
;; sprint.  Key-by-key usage: docs/jira-cheatsheet.org.
;;
;; Credentials are never configured here.  Leaving `jira-username' and `jira-token'
;; unset is what makes jira.el fall back to `auth-source', i.e. ~/.authinfo.gpg:
;;
;;     machine YOUR-INSTANCE.atlassian.net login you@example.com port https password TOKEN
;;
;; With an on-premise Personal Access Token rather than a Cloud API token, also set
;; `jira-token-is-personal-access-token' and `rata-jira-api-version' to 2.

(defcustom rata-jira-base-url nil
  "Base URL of the Jira instance, e.g. \"https://acme.atlassian.net\".
Set this in `local.el', which is gitignored: this repository has a public
remote and the instance hostname is corporate identity.  `local.el.example'
is the checklist (D-012); `custom.el' is Custom's own churn, never hand-edited.
While nil, the commands load but cannot reach an instance."
  :type '(choice (const :tag "Not configured" nil) string)
  :group 'rata)

(defcustom rata-jira-api-version 3
  "Jira REST API version.  Cloud takes 3; older on-premise instances need 2."
  :type 'integer
  :group 'rata)

(defcustom rata-jira-excluded-statuses '("CLOSED" "DEPLOYED" "DONE" "REJECTED")
  "Issue statuses kept out of the default `jira-issues' query.
Finished work is noise in a list whose job is \"what is on my plate\".

These are instance workflow names, not Jira built-ins.  JQL matches them
case-insensitively, but it does not tolerate a name that no status in the
instance carries: Jira rejects the whole query with a 400 and the list comes
back empty rather than unfiltered.  Trim the list in `local.el' on an instance
with a different workflow; nil restores jira.el's own default query.

This is scope, not truncation.  In the issues list, `, l' then `j' clears the
JQL argument for a one-off look at everything."
  :type '(repeat string)
  :group 'rata)

(use-package jira
  :commands (jira-issues jira-tempo)
  :custom
  ;; `directory-file-name' drops a trailing slash.  Not cosmetic: jira.el derives
  ;; the auth-source host by stripping only "https://" (jira-api.el:99,108), so a
  ;; URL ending in "/" yields the host "acme.atlassian.net/", no `machine' line
  ;; matches, `jira-api--token' returns nil and the request 401s as though the
  ;; token were wrong.  Cost one debugging session; see L-018.
  (jira-base-url (if rata-jira-base-url
                     (directory-file-name rata-jira-base-url)
                   ""))
  (jira-api-version rata-jira-api-version)
  ;; Upstream ships 30 and pages the rest with `M-n'.  That paging only works on
  ;; Cloud.  jira.el asks for `search/jql' first and falls back to the legacy
  ;; `search' endpoint on a 404 (jira-api.el:238) -- which is what a Server/DC
  ;; instance like ours does, since `search/jql' is Cloud-only.  The legacy
  ;; endpoint paginates with `startAt'/`total'; jira.el only ever reads
  ;; `nextPageToken' and never sends `startAt' (jira-issues.el:107,179).  So on
  ;; Server/DC `jira-issues--pagination-next' is permanently nil, `M-n' answers
  ;; "No more pages.", `total' is never shown, and the list is silently the
  ;; first 30 matches of an unordered JQL -- an arbitrary 30, since the query
  ;; carries no ORDER BY and the client-side sort only reorders what arrived.
  ;; Raising the page size is the only mitigation that does not patch upstream.
  ;; Server-side cap is `jira.search.views.default.max' (1000 by default).
  (jira-issues-max-results 100)
  ;; `:rata-org' and `:rata-sprint' are this module's own columns: whether the
  ;; issue already has a heading in `work_tasks.org' (see "Org" below), and the
  ;; sprint the issue is in now, blank for the backlog ("Sprint column" below).
  (jira-issues-table-fields '(:key :rata-org :issue-type-name :status-name :rata-sprint
                              :assignee-name :progress-percent :work-ratio
                              :remaining-time :summary))
  (jira-detail-reuse-buffer t))

;; --- Default query: assigned to me, and not already finished ---
;;
;; jira.el has no option for this.  `--status=' is a single equality
;; (jira-issues.el:222) and there is no negation argument at all, so the only
;; composable place to say "not these four" is the `--jql=' argument: when it is
;; set, `jira-issues--refresh' emits `(JQL) AND <the other arguments>'
;; (jira-issues.el:231-238), so the exclusion survives whatever else is toggled
;; in the query menu.
;;
;; The argument reaches a menu that was never opened through the prefix's
;; default value, which is where `--myself' already comes from: `jira-issues'
;; does not invoke the transient at all, it calls `tablist-revert', and
;; `jira-issues--refresh' reads `(transient-args 'jira-issues-menu)' -- for which
;; transient falls back to the set, saved or default value of a prefix that was
;; never displayed.  Hence a `:filter-return' advice on the default rather than a
;; replacement for it: it composes with `--myself' and `jira-issues-default-type'
;; instead of restating them, so an upstream change to either is inherited rather
;; than shadowed.
;;
;; Two things it deliberately does not cover.  `C-x C-s' in the query menu
;; persists an argument set, and a saved value wins over the default -- `C-x C-k'
;; comes back to this one.  And `F' (a saved Jira filter) replaces the JQL
;; wholesale by design (jira-issues.el:340): a server-side filter is the server's
;; query, not ours.

(defun rata-jira-exclusion-jql (statuses)
  "Return a JQL clause excluding STATUSES, or nil when STATUSES is empty."
  (when statuses
    (format "status not in (%s)"
            (mapconcat (lambda (status)
                         (format "\"%s\"" (string-replace "\"" "\\\"" status)))
                       statuses ", "))))

(defun rata-jira--default-jql-value (value)
  "Add the `rata-jira-excluded-statuses' exclusion to transient VALUE.
VALUE is jira.el's default argument list for `jira-issues-menu'.  A `--jql='
already present in VALUE wins: this module supplies a default, and an upstream
default query would be upstream's decision, not ours."
  (let ((jql (rata-jira-exclusion-jql rata-jira-excluded-statuses)))
    (if (or (null jql)
            (seq-some (lambda (arg)
                        (and (stringp arg) (string-prefix-p "--jql=" arg)))
                      value))
        value
      (cons (concat "--jql=" jql) value))))

(with-eval-after-load 'jira-issues
  (advice-add 'jira-issues--transient-default-value
              :filter-return #'rata-jira--default-jql-value))

;; --- Sprints: move issues onto and off the board (Agile REST API) ---
;;
;; The team board is a Scrum board with one sprint that is never closed, run as a
;; kanban board.  "Put this on the board" therefore means "move the issue into the
;; active sprint", and jira.el has nothing for it: no board or sprint listing and no
;; move.  `, u' on the Sprint field goes through the issue PUT with a candidate list
;; scraped from issues that already carry a sprint, so a fresh sprint is never
;; offered, and the value is sent as an object where the field wants an id.
;;
;; Sprint operations live in a different API family, `/rest/agile/1.0/', which
;; `jira-api--url' cannot build -- but it passes an endpoint through untouched when
;; it already starts with the base URL (jira-api.el:174), so a full Agile URL gets
;; jira.el's auth header, error log and current-host handling for free, with no
;; second HTTP layer and no patch to upstream.
;; `rata-test-jira-agile-url-passes-through-jira-api' binds that assumption to
;; upstream's code.  request.el skips the parser on the 204 these endpoints return
;; (request.el:567), so jira.el's default `json-read' parser is safe here.
;;
;; The active sprint is shown everywhere -- as the default in the prompt, on its
;; candidate, in the confirmation -- because on a never-ending sprint the whole
;; question is "did it land on the board", and the wrong sprint looks like success.
;; Calls are synchronous: the pickers need the answer before they can ask, and a
;; move is one small POST -- the same trade jira.el makes for its own menus.
;; See D-017 and docs/jira-cheatsheet.org.

(defcustom rata-jira-board-id nil
  "Numeric id of the Agile board whose sprints `rata-jira-move-to-sprint' offers.
Set it in `local.el' (see `local.el.example'); it is in the board's URL as
`rapidView=NNN'.  While nil, the first sprint command asks which board to use
and remembers the answer for the session.  `, m o' changes it either way."
  :type '(choice (const :tag "Ask once per session" nil) integer)
  :group 'rata)

(defvar rata-jira--session-board-id nil
  "Board chosen with `rata-jira-choose-board' this session.
When set it beats `rata-jira-board-id'.")

(defvar rata-jira--boards nil
  "Cache: alist of (BASE-URL . BOARDS), BOARDS as the Agile API returns them.")

(defvar rata-jira--sprints nil
  "Cache: alist of ((BASE-URL . BOARD-ID) . SPRINTS), open sprints per board.")

(declare-function jira-api-call "jira-api")
(declare-function jira-api--get-current-url "jira-api")
(declare-function jira-utils-marked-item "jira-utils")
(declare-function jira-utils-marked-items "jira-utils")
(declare-function request-response-data "request")
;; Compile-time stubs only -- these hooks are owned by jira.el, which loads later.
(eval-when-compile
  (defvar jira-issues-changed-hook)
  (defvar jira-detail-changed-hook))

(defun rata-jira-agile-url (base endpoint)
  "Return the Agile REST URL for ENDPOINT under BASE.
The result starts with BASE, which is what makes `jira-api--url' pass it
through instead of prefixing `/rest/api/N/'."
  (concat (directory-file-name base) "/rest/agile/1.0/"
          (if (string-prefix-p "/" endpoint) (substring endpoint 1) endpoint)))

(defun rata-jira-agile-error-message (data)
  "Return Jira's own explanation from an Agile API error body DATA, or nil.
DATA is the parsed JSON: `errorMessages' is a vector of strings and `errors'
an alist of field -> string; either, both or neither may be present."
  (let ((all (append (append (alist-get 'errorMessages data) nil)
                     (mapcar (lambda (e) (format "%s: %s" (car e) (cdr e)))
                             (alist-get 'errors data)))))
    (when all (string-join all "; "))))

(defun rata-jira--agile-call (verb endpoint &rest args)
  "Synchronous VERB request to the Agile ENDPOINT; return the parsed body.
ARGS are passed on to `jira-api-call'.  Signals a `user-error' carrying Jira's
message on failure, because the reasons are the operator's to act on: a closed
sprint, an issue outside the board filter, no Jira Software licence."
  (let* ((failure nil)
         (response
          (apply #'jira-api-call verb
                 (rata-jira-agile-url (jira-api--get-current-url) endpoint)
                 :sync t
                 :error (cl-function
                         (lambda (&key response error-thrown &allow-other-keys)
                           (setq failure
                                 (or (ignore-errors
                                       (rata-jira-agile-error-message
                                        (request-response-data response)))
                                     (format "%s" error-thrown)))))
                 args)))
    (when failure
      (user-error "Jira: %s" failure))
    (request-response-data response)))

(defun rata-jira--agile-values (endpoint &optional params)
  "Return every `values' element of the paged Agile ENDPOINT as a list.
The Agile API pages with `startAt' and reports `isLast'; boards and sprints
both do, and an instance can have more than the 50-per-page default."
  (let ((start 0) (all nil) (last nil))
    (while (not last)
      (let* ((page (rata-jira--agile-call
                    "GET" endpoint
                    :params (append params
                                    `(("startAt" . ,(number-to-string start))
                                      ("maxResults" . "50")))))
             (values (append (alist-get 'values page) nil)))
        (setq all (append all values)
              start (+ start (length values))
              last (or (eq (alist-get 'isLast page) t) (null values)))))
    all))

(defun rata-jira--boards (&optional refresh)
  "Return the boards of the current host, from cache unless REFRESH."
  (let ((url (jira-api--get-current-url)))
    (when refresh
      (setq rata-jira--boards (assoc-delete-all url rata-jira--boards)))
    (or (cdr (assoc url rata-jira--boards))
        (let ((boards (rata-jira--agile-values "board")))
          (push (cons url boards) rata-jira--boards)
          boards))))

(defun rata-jira--sprints (board-id &optional refresh)
  "Return the active and future sprints of BOARD-ID, from cache unless REFRESH."
  (let ((key (cons (jira-api--get-current-url) board-id)))
    (when refresh
      (setq rata-jira--sprints (assoc-delete-all key rata-jira--sprints)))
    (or (cdr (assoc key rata-jira--sprints))
        (let ((sprints (rata-jira--agile-values (format "board/%s/sprint" board-id)
                                                '(("state" . "active,future")))))
          (push (cons key sprints) rata-jira--sprints)
          sprints))))

(defun rata-jira-board-label (board)
  "Return the completion label for BOARD: name, type, project and id."
  (let ((project (alist-get 'projectKey (alist-get 'location board))))
    (format "%s  [%s%s]  #%s"
            (alist-get 'name board) (alist-get 'type board)
            (if project (concat ", " project) "")
            (alist-get 'id board))))

(defun rata-jira-open-sprints (sprints)
  "Return the open SPRINTS, active ones first.
Closed sprints are dropped even if the server sent them: an issue can be moved
into one, and nothing on the board would show it."
  (let* ((open (seq-remove (lambda (s) (equal (alist-get 'state s) "closed")) sprints))
         (active-p (lambda (s) (equal (alist-get 'state s) "active"))))
    (append (seq-filter active-p open) (seq-remove active-p open))))

(defun rata-jira-sprint-label (sprint)
  "Return the completion label for SPRINT: name, state and end date if any."
  (let ((end (alist-get 'endDate sprint)))
    (format "%s  [%s]%s"
            (alist-get 'name sprint) (alist-get 'state sprint)
            (if (and (stringp end) (>= (length end) 10))
                (format "  ends %s" (substring end 0 10))
              ""))))

(defun rata-jira-active-sprint (sprints)
  "Return the active sprint among SPRINTS, or nil."
  (seq-find (lambda (s) (equal (alist-get 'state s) "active")) sprints))

(defun rata-jira-move-payloads (keys)
  "Return the request bodies moving issue KEYS.
At most 50 keys per body, which is the Agile API's cap per call."
  (let (out)
    (while keys
      (push `(("issues" . ,(vconcat (seq-take keys 50)))) out)
      (setq keys (nthcdr 50 keys)))
    (nreverse out)))

(defun rata-jira--target-issues ()
  "Return the issue keys an action applies to.
The marked ones, else the one at point -- the same rule as jira.el's own
change-issue menu, in both the list and the detail buffer."
  (let ((keys (delq nil (or (jira-utils-marked-items)
                            (list (jira-utils-marked-item))))))
    (or keys (user-error "No Jira issue here; run `jira-issues' first"))))

(defun rata-jira--board-id ()
  "Return the board to work with.
Asks once per session when nothing is configured."
  (or rata-jira--session-board-id
      rata-jira-board-id
      (rata-jira-choose-board)))

(defun rata-jira--after-change ()
  "Refresh whichever jira.el buffer the action ran from, as jira-actions does."
  (cond ((derived-mode-p 'jira-issues-mode) (run-hooks 'jira-issues-changed-hook))
        ((derived-mode-p 'jira-detail-mode) (run-hooks 'jira-detail-changed-hook))))

(defun rata-jira-choose-board (&optional refresh)
  "Pick the Agile board for this session from those the instance lists.
With prefix argument REFRESH, ask the server again instead of using the cache."
  (interactive "P")
  (let* ((boards (rata-jira--boards refresh))
         (choices (mapcar (lambda (b) (cons (rata-jira-board-label b) (alist-get 'id b)))
                          boards))
         (pick (and choices (completing-read "Jira board: " choices nil t))))
    (unless choices (user-error "Jira: this host lists no Agile boards"))
    (setq rata-jira--session-board-id (cdr (assoc pick choices)))
    (message "Jira board for this session: %s" pick)
    rata-jira--session-board-id))

(defun rata-jira-show-active-sprint (&optional refresh)
  "Say which sprint is active on the team board, with its end date.
With prefix argument REFRESH, refetch the sprint list first."
  (interactive "P")
  (let* ((board (rata-jira--board-id))
         (active (rata-jira-active-sprint (rata-jira--sprints board refresh))))
    (if active
        (message "Board #%s: active sprint is %s" board (rata-jira-sprint-label active))
      (message "Board #%s has no active sprint" board))))

(defun rata-jira-move-to-sprint (&optional refresh)
  "Move the marked issues (or the one at point) into a sprint of the team board.
The active sprint is the default and is labelled as such: on a board run as a
never-ending sprint, that is the move that means \"onto the board\".  With
prefix argument REFRESH, refetch the sprint list first."
  (interactive "P")
  (let* ((keys (rata-jira--target-issues))
         (board (rata-jira--board-id))
         (sprints (rata-jira-open-sprints (rata-jira--sprints board refresh)))
         (active (rata-jira-active-sprint sprints))
         (default (and active (rata-jira-sprint-label active)))
         (choices (mapcar (lambda (s) (cons (rata-jira-sprint-label s) (alist-get 'id s)))
                          sprints))
         (what (string-join keys ", ")))
    (unless choices (user-error "Jira: board #%s has no open sprint" board))
    (let* ((pick (completing-read
                  (format "Move %s to sprint%s: " what
                          (if default (format " (default %s)" default) ""))
                  choices nil t nil nil default))
           (sprint-id (cdr (assoc pick choices))))
      (dolist (body (rata-jira-move-payloads keys))
        (rata-jira--agile-call "POST" (format "sprint/%s/issue" sprint-id) :data body))
      (message "Moved %s to %s" what pick)
      (rata-jira--after-change))))

(defun rata-jira-move-to-backlog ()
  "Move the marked issues (or the one at point) out of their sprint.
They land in the backlog.  On a never-ending sprint this is the only way to
take something off the board."
  (interactive)
  (let* ((keys (rata-jira--target-issues))
         (what (string-join keys ", ")))
    (when (y-or-n-p (format "Move %s to the backlog, off the board? " what))
      (dolist (body (rata-jira-move-payloads keys))
        (rata-jira--agile-call "POST" "backlog/issue" :data body))
      (message "Moved %s to the backlog" what)
      (rata-jira--after-change))))

(defun rata-jira-refresh-agile-cache ()
  "Forget the cached boards and sprints; the next command fetches them again."
  (interactive)
  (setq rata-jira--boards nil
        rata-jira--sprints nil)
  (message "Jira boards and sprints will be fetched again on next use"))

(defconst rata-jira-sprint-keys
  '("m"  (:ignore t :which-key "sprint")
    "ms" (rata-jira-move-to-sprint :which-key "move to sprint (active = default)")
    "mb" (rata-jira-move-to-backlog :which-key "move to backlog")
    "ma" (rata-jira-show-active-sprint :which-key "show active sprint")
    "mo" (rata-jira-choose-board :which-key "choose board")
    "mr" (rata-jira-refresh-agile-cache :which-key "refetch boards/sprints"))
  "Local-leader bindings for the sprint commands.
Shared by the list and detail buffers.  These are this module's own commands,
not a mirror of upstream keys, so they sit outside
`rata-jira-issues-key-mirror'.")

;; --- Sprint column and grouping: which issues are on the board ---
;;
;; "Assigned to me" mixes the board and the backlog into one list.  The Sprint
;; custom field tells them apart, and jira.el already knows it (`:sprints', shown
;; in the detail view) -- but never manages to *request* it for the list:
;; `jira-issues--api-get-issues' builds the `fields' parameter with `%s' on each
;; field's parent, and a custom field's parent is the list `(custom "Sprint")', so
;; the server is asked for a field literally named "(custom Sprint)", ignores it,
;; and the column is blank with no error anywhere (L-042).  On Jira Server/DC a
;; second gap sits underneath: the `field' endpoint sends `id' but no `key', and
;; upstream keeps `(NAME . key)', so `jira-fields' is all nils and no custom field
;; can be resolved by anyone (FAIL-0017 -- the first version of this column
;; shipped against a Cloud-shaped fixture and showed every issue as backlog).
;; Three advices fix that without touching upstream: `jira-table-field-parent'
;; resolves a `(custom NAME)' parent to its `customfield_NNNNN' id through
;; `jira-fields'; `jira-api-get-fields' is overridden to fall back to `id'; and
;; the search fetches the field list synchronously while `jira-fields' cannot
;; resolve anything -- on the first `jira-issues' of a session the search goes
;; out before `jira-api-get-basic-data' has its answer, and a column that is
;; blank on the first look and filled on the second is a bug report waiting to
;; happen.
;;
;; The field's value is every sprint the issue has ever been in, closed ones
;; included, so "in a sprint" means "has a sprint that is not closed"
;; (`rata-jira-current-sprint').  Its shape depends on the deployment: Cloud and
;; recent Server/DC send objects with `name' and `state'; older Server/DC sends
;; the sprint's Java toString, `...Sprint@1a2b[id=7,state=ACTIVE,name=Board,...]'.
;; `rata-jira-sprint-info' reads both.  Upstream's `jira-fmt-issue-sprints' would
;; signal on the string form and lists the closed history as if it were current.
;;
;; Grouping is Emacs 30's `tabulated-list-groups': one heading per open sprint,
;; active first, then "Backlog"; each group is sorted on its own by the current
;; sort column, and `, m g' toggles it for the buffer.  tablist predates grouped
;; tables, and three of its commands walk the buffer assuming every line is an
;; entry: `tablist-sort' (`S') rearranges lines with `sort-subr' and would scatter
;; the headings among the issues, `tablist-put-mark' (behind `m', `t', `U')
;; signals "No entry at this position" on a heading, and a regexp filter indexes
;; the heading's nil entry.  Each gets a guard that applies only while
;; `tabulated-list-groups' is non-nil in the buffer, so no other tablist buffer
;; sees any change.  `rata-test-jira-issues-list-groups-by-sprint' prints a
;; fixture list through the real mode and exercises all three.

(defcustom rata-jira-group-by-sprint t
  "Non-nil groups the issue list by sprint: open sprints first, then Backlog.
The default for a new list; `, m g' toggles it in the buffer at hand."
  :type 'boolean
  :group 'rata)

(defface rata-jira-group-heading
  '((t :inherit bold))
  "Face of the sprint and backlog headings in the Jira issue list."
  :group 'rata)

(eval-when-compile
  (defvar jira-fields)
  (defvar jira-issues-fields)
  (defvar jira-issues--raw-issues)
  (defvar tabulated-list-groups)
  (defvar tabulated-list-entries)
  (defvar tabulated-list-format))
(declare-function jira-table-extract-field "jira-table")
(declare-function tabulated-list-sort "tabulated-list")
(declare-function tabulated-list-print "tabulated-list")
(declare-function tabulated-list-get-id "tabulated-list")

(with-eval-after-load 'jira-utils
  (unless (assq :rata-sprint jira-issues-fields)
    (push '(:rata-sprint . ((:path . (fields (custom "Sprint")))
                            (:columns . 16)
                            (:name . "Sprint")
                            (:formatter . rata-jira-fmt-sprint)))
          jira-issues-fields))
  ;; The Org column is computed from the key alone (`rata-jira-fmt-org', below).
  (unless (assq :rata-org jira-issues-fields)
    (push '(:rata-org . ((:path . (key))
                         (:columns . 3)
                         (:name . "Org")
                         (:formatter . rata-jira-fmt-org)))
          jira-issues-fields)))

(defun rata-jira-sprint-info (item)
  "Return (NAME . STATE) for ITEM, one element of Jira's Sprint field, or nil.
ITEM is either an alist with `name' and `state' (Cloud, recent Server/DC) or
the sprint's Java toString (older Server/DC), which looks like
`...greenhopper.service.sprint.Sprint@1a2b[id=7,state=ACTIVE,name=Board,...]'.
STATE is returned lower-cased, \"\" when absent."
  (cond
   ((and (consp item) (consp (car item)))
    (let ((name (alist-get 'name item))
          (state (alist-get 'state item)))
      (when (stringp name)
        (cons name (if (stringp state) (downcase state) "")))))
   ((stringp item)
    (let ((name (and (string-match "[[,]name=\\(.*?\\)\\(?:,[A-Za-z]+=\\|\\]\\'\\)" item)
                     (match-string 1 item)))
          (state (and (string-match "[[,]state=\\([A-Za-z]+\\)" item)
                      (match-string 1 item))))
      (when name
        (cons name (if state (downcase state) "")))))))

(defun rata-jira-current-sprint (value)
  "Return (NAME . STATE) of the sprint the issue is in now, or nil for the backlog.
VALUE is the Sprint field: a vector or list of every sprint the issue has ever
been in.  Closed sprints are history, not membership, so an issue whose sprints
are all closed is in the backlog.  With an active and a future sprint both
open, the active one wins."
  (let* ((infos (delq nil (mapcar #'rata-jira-sprint-info
                                  (and (sequencep value) (append value nil)))))
         (open (seq-remove (lambda (info) (equal (cdr info) "closed")) infos)))
    (or (seq-find (lambda (info) (equal (cdr info) "active")) open)
        (car open))))

(defun rata-jira-fmt-sprint (value)
  "Format the Sprint field VALUE for the list: the current sprint's name, else \"\".
A sprint that is not active carries its state, so a future sprint does not
read as the board."
  (let ((current (rata-jira-current-sprint value)))
    (cond ((null current) "")
          ((equal (cdr current) "active") (car current))
          (t (format "%s (%s)" (car current) (cdr current))))))

(defun rata-jira-group-heading (sprint count)
  "Return the heading line of a group of COUNT issues.
SPRINT is (NAME . STATE), or nil for the backlog."
  (propertize (if sprint
                  (format "%s  [%s]  (%d)" (car sprint) (cdr sprint) count)
                (format "Backlog  (%d)" count))
              'face 'rata-jira-group-heading))

(defun rata-jira-group-issues (entries sprint-of)
  "Group the tabulated-list ENTRIES by sprint, in `tabulated-list-groups' form.
SPRINT-OF maps an entry's id (the issue key) to (NAME . STATE), or nil for
the backlog.  Active sprints come first, then the other open ones by name,
then the backlog; a group with nothing in it is not shown.  Entries keep
their order within a group -- `tabulated-list-print' sorts each group by
the current sort column afterwards."
  (let ((groups nil))
    (dolist (entry entries)
      (let* ((sprint (funcall sprint-of (car entry)))
             (cell (assoc sprint groups)))
        (if cell
            (push entry (cdr cell))
          (push (cons sprint (list entry)) groups))))
    (let ((rank (lambda (sprint)
                  (cond ((null sprint) 2)
                        ((equal (cdr sprint) "active") 0)
                        (t 1)))))
      (mapcar (lambda (group)
                (cons (rata-jira-group-heading (car group) (length (cdr group)))
                      (nreverse (cdr group))))
              (sort groups
                    (lambda (a b)
                      (let ((ra (funcall rank (car a)))
                            (rb (funcall rank (car b))))
                        (or (< ra rb)
                            (and (= ra rb)
                                 (string< (or (car (car a)) "")
                                          (or (car (car b)) "")))))))))))

(defun rata-jira--sprint-lookup ()
  "Return a function from issue key to its current sprint.
Built once per print, over the issues on screen."
  (let ((table (make-hash-table :test #'equal)))
    (seq-doseq (issue jira-issues--raw-issues)
      (puthash (jira-table-extract-field jira-issues-fields :key issue)
               (rata-jira-current-sprint
                (jira-table-extract-field jira-issues-fields :rata-sprint issue))
               table))
    (lambda (key) (gethash key table))))

(defun rata-jira--issue-groups ()
  "The issue list's `tabulated-list-groups' function.
Returns the current entries grouped by sprint."
  (rata-jira-group-issues (if (functionp tabulated-list-entries)
                              (funcall tabulated-list-entries)
                            tabulated-list-entries)
                          (rata-jira--sprint-lookup)))

(defun rata-jira--setup-issue-groups ()
  "Group the issue list by sprint when `rata-jira-group-by-sprint' says so.
On `jira-issues-mode-hook'; `tabulated-list-groups' is permanent-local, so
this outlives the reverts the list does on every refresh."
  (setq tabulated-list-groups (and rata-jira-group-by-sprint #'rata-jira--issue-groups)))

(add-hook 'jira-issues-mode-hook #'rata-jira--setup-issue-groups)

(defun rata-jira-toggle-sprint-grouping ()
  "Toggle the sprint headings in this issue list.
`rata-jira-group-by-sprint' is the default a fresh list starts from."
  (interactive)
  (unless (derived-mode-p 'jira-issues-mode)
    (user-error "Not in a Jira issue list"))
  (setq tabulated-list-groups (if tabulated-list-groups nil #'rata-jira--issue-groups))
  (tabulated-list-print t)
  (message "Jira issues: sprint grouping %s" (if tabulated-list-groups "on" "off")))

;; Requesting the custom field.  `jira-table-field-parent' is what
;; `jira-issues--api-get-issues' puts in the `fields' parameter, one per column.

(defun rata-jira--resolve-custom-parent (parent)
  "Turn a `(custom NAME)' field PARENT into its `customfield_NNN' id.
Unknown NAME gives nil, which the caller drops from the request; any other
PARENT is returned as is.  `:filter-return' advice on `jira-table-field-parent'."
  (if (and (consp parent) (eq (car parent) 'custom))
      (cdr (assoc (cadr parent) jira-fields))
    parent))

(defun rata-jira--fields-from-response (data)
  "Return the (NAME . ID) alist jira.el keeps in `jira-fields'.
DATA is the parsed body of the `field' endpoint.  Cloud sends both `key' and
`id' for a field; Jira Server/DC sends only `id'.  Upstream reads `key'
alone, so on Server every entry is (NAME . nil), no custom field can ever be
resolved, and the Sprint line in the detail view is empty too (FAIL-0017)."
  (mapcar (lambda (field)
            (cons (cdr (assoc 'name field))
                  (or (cdr (assoc 'key field)) (cdr (assoc 'id field)))))
          data))

(defun rata-jira--fields-usable-p (fields)
  "Non-nil when FIELDS (a `jira-fields' value) can resolve a custom field.
Empty, or every entry without an id, means no."
  (and fields (seq-some #'cdr fields) t))

(defun rata-jira--fetch-fields (&optional force callback)
  "jira.el's `jira-api-get-fields', with the Server/DC id fallback.
Fetch unless `jira-fields' is already usable or FORCE; then call CALLBACK.
Installed as `:override' advice, so the detail view and `, u' see ids too."
  (if (or force (not (rata-jira--fields-usable-p jira-fields)))
      (jira-api-call "GET" "field"
                     :callback (lambda (data _response)
                                 (setq jira-fields (rata-jira--fields-from-response data)))
                     :complete (lambda (&rest _) (when callback (funcall callback))))
    (when callback (funcall callback))))

(defun rata-jira--get-fields-advice (&rest args)
  "`:override' for `jira-api-get-fields'; ARGS are its `:force' / `:callback'."
  (rata-jira--fetch-fields (plist-get args :force) (plist-get args :callback)))

(defun rata-jira--ensure-fields (&rest _)
  "Fetch the field list synchronously while `jira-fields' cannot resolve anything.
`:before' advice on `jira-issues--api-get-issues', so the first search of a
session can already name the Sprint field's id: `jira-issues' fires the search
and `jira-api-get-basic-data' at the same time, and the latter's field fetch
is several requests down its chain.  It skips its own fetch once the list is
filled, so this is not a duplicate; on failure nothing changes."
  (unless (rata-jira--fields-usable-p jira-fields)
    (let ((data (ignore-errors
                  (request-response-data (jira-api-call "GET" "field" :sync t)))))
      (when data
        (setq jira-fields (rata-jira--fields-from-response data))))))

(with-eval-after-load 'jira-table
  (advice-add 'jira-table-field-parent :filter-return #'rata-jira--resolve-custom-parent))

(with-eval-after-load 'jira-api
  (advice-add 'jira-api-get-fields :override #'rata-jira--get-fields-advice))

(with-eval-after-load 'jira-issues
  (advice-add 'jira-issues--api-get-issues :before #'rata-jira--ensure-fields))

;; tablist guards, live only in a grouped buffer.

(defun rata-jira--tablist-sort-grouped (orig &rest args)
  "Sort a grouped buffer through `tabulated-list-sort'; otherwise ORIG with ARGS.
`tablist-sort' reorders the buffer's lines in place and would carry the group
headings along.  `tabulated-list-sort' re-prints, and printing sorts each
group on its own.  A column name in ARGS (tablist's prefix argument) is
honoured; without one the column at point is used, as upstream does."
  (if (not tabulated-list-groups)
      (apply orig args)
    (let ((column (car args)))
      (cond
       ((stringp column)
        (tabulated-list-sort
         (or (seq-position tabulated-list-format column
                           (lambda (col name) (equal (car col) name)))
             (user-error "No such column: %s" column))))
       ((get-text-property (point) 'tabulated-list-column-name)
        (tabulated-list-sort))
       (t (user-error "Point is on a group heading; move onto an issue to pick the column"))))))

(defun rata-jira--tablist-put-mark-grouped (orig &rest args)
  "Do nothing on a group heading instead of signalling; otherwise ORIG with ARGS.
`t' and `U' call `tablist-put-mark' on every line of the buffer."
  (if (and tabulated-list-groups
           (not (save-excursion
                  (when (car args) (goto-char (car args)))
                  (tabulated-list-get-id))))
      nil
    (apply orig args)))

(defun rata-jira--tablist-filter-eval-grouped (orig filter id entry &rest more)
  "A group heading -- no ID, no ENTRY -- matches no FILTER; otherwise ORIG.
So a regexp filter neither hides nor marks a heading, and never indexes nil."
  (if (and tabulated-list-groups (null id) (null entry))
      nil
    (apply orig filter id entry more)))

(with-eval-after-load 'tablist
  (advice-add 'tablist-sort :around #'rata-jira--tablist-sort-grouped)
  (advice-add 'tablist-put-mark :around #'rata-jira--tablist-put-mark-grouped))

(with-eval-after-load 'tablist-filter
  (advice-add 'tablist-filter-eval :around #'rata-jira--tablist-filter-eval-grouped))

;; --- Org: one-way import into work_tasks.org (D-019) ---
;;
;; The operator keeps work tasks by hand in `work_tasks.org' and also has tickets
;; in Jira.  D-011 rejected a sync: the org headings carry colleagues' notes, briefs
;; and sub-checklists that a mirror would clobber, and Jira and the file disagree
;; about what a task is.  What is wanted is narrower -- "which of my tickets have no
;; heading yet, and add those" -- and that is what this section does, under three
;; rules that make it safe where a sync would not be:
;;
;; 1. One direction.  Jira to org, never back.  Marking a heading DONE does not
;;    transition the ticket; nothing here PUTs anything.
;; 2. Append-only.  An existing heading is never rewritten, re-titled or moved.
;;    Identity is the `:JIRA:' property, not the title -- titles get edited -- and
;;    an issue whose key the file already carries is skipped, so running the import
;;    twice adds nothing (`rata-test-jira-import-appends-new-issues-only').
;; 3. On demand.  No timer.  `, i' in the issue list or detail buffer, on the
;;    marked issues or the one at point, after a y-or-n-p naming the file.
;;
;; The `Org' column marks issues that are already in the file, so "new" is visible
;; before anything is written; it reads the file from disk, re-parsing only when
;; the file changed.  `SPC J l' on an org heading records which issue it is, for
;; the headings that predate Jira -- once linked, the import stops treating that
;; ticket as new.  Both commands save the buffer, because the column reads disk.
;;
;; Only the key, the summary and a link are copied.  Status, type and assignee
;; change in Jira and would go stale here in a week, and the body under a heading
;; is the operator's to write.  After an import the file's kanban dynamic block is
;; refreshed, because `work_tasks.org' carries one that nothing else refreshes.
;; Every function that shapes text is pure and tested against a fixture file in
;; `temporary-file-directory'; nothing in tests/ touches ~/workspace/second-brain/.

(defcustom rata-jira-org-file nil
  "Org file `rata-jira-import-to-org' appends to.
nil means `work_tasks.org' in `rata-org-roam-dir' (from `init-org.el'), the
file the \"Work Task\" capture template also writes to."
  :type '(choice (const :tag "work_tasks.org in the org-roam root" nil) file)
  :group 'rata)

(defcustom rata-jira-org-heading "Tasks"
  "Heading in `rata-jira-org-file' under which imported issues are appended.
Matched exactly, tags and TODO keyword aside.  New entries go one level below
it, at the end of its subtree."
  :type 'string
  :group 'rata)

(defcustom rata-jira-org-tags '("work" "jira")
  "Tags put on an imported heading, and on a heading linked with
`rata-jira-org-link-heading'.  `work' mirrors the capture template."
  :type '(repeat string)
  :group 'rata)

(defcustom rata-jira-org-refresh-kanban t
  "Non-nil refreshes the dynamic blocks of `rata-jira-org-file' after an import.
`work_tasks.org' carries an `org-kanban' block that nothing else refreshes; a
new heading that is not on the board would otherwise be invisible there."
  :type 'boolean
  :group 'rata)

(defcustom rata-jira-org-mark "✓"
  "What the Org column shows for an issue that is already in the org file."
  :type 'string
  :group 'rata)

(defconst rata-jira-org-property "JIRA"
  "Property whose value is the issue key an org heading stands for.
The import and the Org column key on it; the title is never compared.")

(defconst rata-jira-key-regexp "\\`[A-Za-z][A-Za-z0-9_]*-[0-9]+\\'"
  "A Jira issue key on its own: project key, dash, number.")

(defvar rata-org-roam-dir)              ; init-org.el, loaded after this module
(defvar rata-jira--org-keys-cache nil
  "(FILE (MODTIME SIZE) . KEYS): the last read of the org file.
Re-read when the file's modification time or size changed.")

(eval-when-compile
  (defvar jira-detail--current)
  (defvar jira-detail--current-key)
  (defvar jira-base-url))
(declare-function jira-issues--data-format-issue "jira-issues")
(declare-function org-find-exact-headline-in-buffer "org")
(declare-function org-current-level "org")
(declare-function org-end-of-subtree "org")
(declare-function org-back-to-heading "org")
(declare-function org-set-property "org")
(declare-function org-toggle-tag "org")
(declare-function org-update-all-dblocks "org")

(defun rata-jira--org-file ()
  "Return the org file to import into, or nil while nothing can name one."
  (let ((file (or rata-jira-org-file
                  (and (boundp 'rata-org-roam-dir)
                       (expand-file-name "work_tasks.org" rata-org-roam-dir)))))
    (and file (expand-file-name file))))

(defun rata-jira-org-keys-in-string (text)
  "Return the issue keys TEXT carries as `rata-jira-org-property' values.
One per property line, upper-cased, in order of appearance, without
duplicates.  Only the property counts: a key mentioned in a title or a link
is not a claim that the heading is that issue."
  (let ((re (format "^[ \t]*:%s:[ \t]+\\([A-Za-z][A-Za-z0-9_]*-[0-9]+\\)[ \t]*$"
                    (regexp-quote rata-jira-org-property)))
        (case-fold-search t)
        (start 0)
        (keys nil))
    (while (string-match re text start)
      (let ((key (upcase (match-string 1 text))))
        (unless (member key keys) (push key keys)))
      (setq start (match-end 0)))
    (nreverse keys)))

(defun rata-jira-org-known-keys (&optional file)
  "Return the issue keys FILE (default `rata-jira--org-file') already carries.
Read from disk, not from a visiting buffer -- what is not saved is not in the
agenda either -- and cached until the file changes on disk.  nil when there
is no such file."
  (let* ((file (or file (rata-jira--org-file)))
         (attrs (and file (file-attributes file)))
         (stamp (and attrs (list (file-attribute-modification-time attrs)
                                 (file-attribute-size attrs)))))
    (cond ((null attrs) nil)
          ((and rata-jira--org-keys-cache
                (equal (car rata-jira--org-keys-cache) file)
                (equal (cadr rata-jira--org-keys-cache) stamp))
           (cddr rata-jira--org-keys-cache))
          (t (let ((keys (rata-jira-org-keys-in-string
                          (with-temp-buffer
                            (insert-file-contents file)
                            (buffer-string)))))
               (setq rata-jira--org-keys-cache (cons file (cons stamp keys)))
               keys)))))

(defun rata-jira-fmt-org (key)
  "Format the Org column for issue KEY: `rata-jira-org-mark' when the file has it."
  (if (and (stringp key) (member key (rata-jira-org-known-keys)))
      rata-jira-org-mark
    ""))

(defun rata-jira-org-heading-text (summary)
  "Return SUMMARY fit for one heading line: whitespace runs collapsed, trimmed."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or summary ""))))

(defun rata-jira-org-entry (issue level base-url &optional time)
  "Return the org entry for the raw Jira ISSUE as a heading at LEVEL.
A TODO heading with the summary and `rata-jira-org-tags'; a property drawer
holding `rata-jira-org-property' (the key) and CREATED (TIME, default now,
as the capture template writes it); then a link to the issue on BASE-URL.
Ends with a newline.  Nothing else is copied: what changes in Jira would only
go stale here, and the body is the operator's."
  (let* ((key (alist-get 'key issue))
         (title (rata-jira-org-heading-text
                 (alist-get 'summary (alist-get 'fields issue))))
         (tags (if rata-jira-org-tags
                   (format " :%s:" (string-join rata-jira-org-tags ":"))
                 "")))
    (concat (make-string level ?*) " TODO "
            (if (string-empty-p title) key title) tags "\n"
            ":PROPERTIES:\n"
            (format ":%s: %s\n" rata-jira-org-property key)
            ;; "C" locale: org's own stamps say `Sat', whatever LANG says.
            (let ((system-time-locale "C"))
              (format-time-string ":CREATED: [%Y-%m-%d %a %H:%M]\n" time))
            ":END:\n"
            (format "[[%s/browse/%s][%s]]\n" (directory-file-name base-url) key key))))

(defun rata-jira-org-import-issues (issues file base-url)
  "Append the raw Jira ISSUES not yet in FILE under `rata-jira-org-heading'.
Return (ADDED . SKIPPED), two lists of keys.  An issue whose key FILE already
carries as `rata-jira-org-property' is skipped, so this is idempotent.
Existing text is not touched: entries go after the last line of the
heading's subtree, with links built on BASE-URL.  The buffer is saved, and
its dynamic blocks refreshed first when `rata-jira-org-refresh-kanban'.
Signals a `user-error' when FILE has no such heading."
  (require 'org)
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (save-restriction
        (widen)
        (let* ((known (rata-jira-org-keys-in-string (buffer-string)))
               (pos (org-find-exact-headline-in-buffer rata-jira-org-heading nil t))
               (added nil)
               (skipped nil))
          (unless pos
            (user-error "No heading `%s' in %s" rata-jira-org-heading file))
          (goto-char pos)
          (let ((level (1+ (org-current-level))))
            ;; End of the subtree's content, before any trailing blank lines,
            ;; which stay where they are: between the new entries and the
            ;; next heading.
            (org-end-of-subtree t t)
            (skip-chars-backward " \t\n")
            (if (looking-at "[ \t]*\n")
                (goto-char (match-end 0))
              (insert "\n"))
            (dolist (issue issues)
              (let ((key (alist-get 'key issue)))
                (if (or (member key known) (member key added))
                    (push key skipped)
                  (insert (rata-jira-org-entry issue level base-url))
                  (push key added)))))
          (when added
            (when rata-jira-org-refresh-kanban
              (org-update-all-dblocks))
            (save-buffer))
          (cons (nreverse added) (nreverse skipped)))))))

(defun rata-jira--raw-issues-for (keys)
  "Return the raw issues for KEYS, as the current jira.el buffer holds them.
The list keeps every issue on screen in `jira-issues--raw-issues'; the detail
buffer keeps its one issue in `jira-detail--current'."
  (let ((pool (cond ((derived-mode-p 'jira-detail-mode)
                     (and jira-detail--current (list jira-detail--current)))
                    (t (append jira-issues--raw-issues nil)))))
    (mapcar (lambda (key)
              (or (seq-find (lambda (issue) (equal (alist-get 'key issue) key)) pool)
                  (user-error "Jira: %s is not in this buffer; refresh and retry" key)))
            keys)))

(defun rata-jira--redraw-issues ()
  "Re-print the issue list from the issues it already holds, no request."
  (when (derived-mode-p 'jira-issues-mode)
    (setq tabulated-list-entries
          (mapcar #'jira-issues--data-format-issue (append jira-issues--raw-issues nil)))
    (tabulated-list-print t)))

(defun rata-jira-import-to-org ()
  "Append the marked issues (or the one at point) to the work tasks org file.
One direction only, Jira to org; issues already in the file are skipped and
the file's existing text is never rewritten.  Asks first, naming the file."
  (interactive)
  (let* ((keys (rata-jira--target-issues))
         (file (or (rata-jira--org-file)
                   (user-error "Set `rata-jira-org-file'; init-org.el has not named the roam root")))
         (issues (rata-jira--raw-issues-for keys))
         (known (rata-jira-org-known-keys file))
         (new (seq-remove (lambda (key) (member key known)) keys))
         (name (file-name-nondirectory file)))
    (cond
     ((not (file-exists-p file))
      (user-error "Jira: %s does not exist" file))
     ((null new)
      (message "Jira: %s already in %s" (string-join keys ", ") name))
     ((y-or-n-p (format "Add %s to %s%s? " (string-join new ", ") name
                        (if (< (length new) (length keys))
                            (format " (%d already there)" (- (length keys) (length new)))
                          "")))
      (let ((result (rata-jira-org-import-issues issues file (jira-api--get-current-url))))
        (message "Added %s to %s%s"
                 (string-join (car result) ", ") name
                 (if (cdr result)
                     (format "; already there: %s" (string-join (cdr result) ", "))
                   ""))
        (rata-jira--redraw-issues))))))

(defun rata-jira--issue-candidates ()
  "Return (LABEL . KEY) for every issue the Jira list currently holds."
  (mapcar (lambda (issue)
            (let ((key (alist-get 'key issue)))
              (cons (format "%s  %s" key
                            (rata-jira-org-heading-text
                             (alist-get 'summary (alist-get 'fields issue))))
                    key)))
          (append (and (boundp 'jira-issues--raw-issues) jira-issues--raw-issues) nil)))

(defun rata-jira--read-key ()
  "Read a Jira issue key, offering the issues in the list as candidates.
Free text is accepted; the key at point is the default when there is one."
  (let* ((candidates (rata-jira--issue-candidates))
         (at-point (thing-at-point 'symbol t))
         (default (and at-point (string-match-p rata-jira-key-regexp at-point)
                       (upcase at-point)))
         (pick (completing-read
                (format "Jira issue key%s: " (if default (format " (default %s)" default) ""))
                candidates nil nil nil nil default)))
    (upcase (string-trim (or (cdr (assoc pick candidates)) (car (split-string pick)) "")))))

(defun rata-jira-org-link-heading (key)
  "Record that the org heading at point is Jira issue KEY.
Sets `rata-jira-org-property', adds `rata-jira-org-tags' and saves, so the
Org column shows the issue as present and the import stops offering it.  For
headings written before Jira; nothing is sent to Jira."
  (interactive (list (rata-jira--read-key)))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org buffer"))
  (unless (string-match-p rata-jira-key-regexp key)
    (user-error "Not a Jira issue key: %s" key))
  (setq key (upcase key))
  (condition-case nil
      (org-back-to-heading t)
    (error (user-error "No org heading at point")))
  (org-set-property rata-jira-org-property key)
  (dolist (tag rata-jira-org-tags)
    (org-toggle-tag tag 'on))
  (when buffer-file-name (save-buffer))
  (message "Heading is now Jira issue %s" key))

;; --- Evil: these buffers stay in evil normal state (D-015) ---
;;
;; jira.el has no evil support (upstream issue #31): `jira-issues-mode' derives from
;; `tabulated-list-mode' and `jira-detail-mode' from `magit-section-mode', and evil's
;; normal state shadows their single-letter keys -- the same mechanism that made plain
;; `define-key' dead in the *claude-loop* buffer (L-017).
;;
;; Until 2026-09-08 the answer here was `evil-set-initial-state ... 'emacs', which is two
;; lines and never drifts.  The operator wants evil motions in these buffers instead, so
;; the module now keeps normal state and mirrors jira.el's own keys under the local
;; leader (`,').  Everything evil-collection already provides is deliberately NOT
;; re-bound: `j'/`k' motion, `/' search, `q' quit, `g r' refresh, and `m'/`u'/`U'/`t'
;; marking in the tablist buffers all work in normal state as they are.  See D-015.
;;
;; The mirror is built with `lookup-key', not by naming upstream's commands: most of
;; jira.el's bindings are anonymous closures over private helpers
;; (`jira-utils-marked-item'), so there is no symbol to bind, and copying their bodies
;; would fork upstream.  Pointing at whatever the mode map holds keeps this file free of
;; jira.el internals -- the technique this config already uses for dashboard
;; (`init-evil.el').  Its failure mode is a missing key rather than a wrong one, and
;; `rata-test-jira-mirrored-keys-exist-upstream' turns an upstream rename into a red test.

(declare-function general-define-key "general")

(defconst rata-jira-issues-key-mirror
  '(("?" "?" "actions menu")
    ("l" "l" "query menu")
    ("I" "d" "issue detail")
    ("f" "f" "find issue by key")
    ("O" "o" "open in browser")
    ("C" "c" "change status/resolution")
    ("W" "w" "add worklog")
    ("c" "y" "copy issue key")
    ("e" "e" "export menu")
    ("T" "t" "tempo worklogs")
    ("H" "h" "switch host"))
  "Local-leader mirror for `jira-issues-mode-map'.
Each entry is (UPSTREAM-KEY LEADER-SUFFIX WHICH-KEY-LABEL): whatever jira.el
binds to UPSTREAM-KEY is re-bound to `,' + LEADER-SUFFIX in normal and visual
state.  Suffixes are mnemonic rather than upstream's letters, because upstream
distinguishes `c'/`C' by case and a leader map need not.")

(defconst rata-jira-detail-key-mirror
  '(("?" "?" "actions menu")
    ("+" "c" "add comment")
    ("e" "e" "edit comment at point")
    ("-" "x" "remove comment at point")
    ("C" "s" "change status/resolution")
    ("U" "u" "update field")
    ("w" "w" "watchers")
    ("S" "S" "add subtask")
    ("P" "p" "parent issue")
    ("O" "o" "open in browser")
    ("f" "f" "find issue by key")
    ("c" "y" "copy issue key")
    ("g" "r" "refresh"))
  "Local-leader mirror for `jira-detail-mode-map'.
See `rata-jira-issues-key-mirror' for the entry format.")

(defconst rata-jira-tempo-key-mirror
  '(("?" "?" "actions menu")
    ("D" "x" "delete worklog")
    ("I" "i" "issue list"))
  "Local-leader mirror for `jira-tempo-mode-map'.
See `rata-jira-issues-key-mirror' for the entry format.")

(defun rata-jira--mirror-args (map mirror)
  "Return `general-define-key' arguments mirroring MIRROR out of MAP.
An entry whose upstream key MAP no longer binds is reported to *Messages* and
skipped: an upstream rename should cost one leader key, not the module."
  (let (args)
    (pcase-dolist (`(,upstream ,suffix ,label) mirror)
      (let ((def (lookup-key map (kbd upstream))))
        (if (or (null def) (numberp def))
            (message "init-jira: jira.el no longer binds %S; `, %s' (%s) skipped"
                     upstream suffix label)
          (push suffix args)
          (push (list def :which-key label) args))))
    (nreverse args)))

(defun rata-jira--bind-local-leader (map-symbol mirror &rest extra)
  "Bind MIRROR, then EXTRA, under `,' in MAP-SYMBOL for normal and visual state.
EXTRA is key/definition pairs in `general-define-key' form, also prefixed."
  (apply #'general-define-key
         :states '(normal visual)
         :keymaps map-symbol
         :prefix ","
         "" '(:ignore t :which-key "jira")
         (append (rata-jira--mirror-args (symbol-value map-symbol) mirror) extra)))

(with-eval-after-load 'jira-issues
  (apply #'rata-jira--bind-local-leader 'jira-issues-mode-map rata-jira-issues-key-mirror
         "r" '(tablist-revert :which-key "refresh")
         "i" '(rata-jira-import-to-org :which-key "import into work_tasks.org")
         ;; List-only: the detail buffer has nothing to group.
         "mg" '(rata-jira-toggle-sprint-grouping :which-key "toggle sprint grouping")
         rata-jira-sprint-keys)
  ;; `RET' opens the issue.  `evil-ret' moves down one line, which is useless in a
  ;; read-only list, and RET is what every other list-like buffer here uses.
  (general-define-key
   :states '(normal visual)
   :keymaps 'jira-issues-mode-map
   "RET" (lookup-key jira-issues-mode-map (kbd "RET"))))

(with-eval-after-load 'jira-detail
  (apply #'rata-jira--bind-local-leader 'jira-detail-mode-map rata-jira-detail-key-mirror
         "i" '(rata-jira-import-to-org :which-key "import into work_tasks.org")
         rata-jira-sprint-keys))

(with-eval-after-load 'jira-tempo
  (rata-jira--bind-local-leader 'jira-tempo-mode-map rata-jira-tempo-key-mirror
                                "r" '(tablist-revert :which-key "refresh")))

;; Global leader keys at top level, never in a deferred `:config' -- a key written
;; there does not exist until the package loads, and a package reached only through
;; its own keybinding never loads.  See FAIL-0009 and L-011.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "J"  '(:ignore t :which-key "jira")
    "Jj" '(jira-issues :which-key "issues")
    "Jt" '(jira-tempo  :which-key "tempo worklogs")
    ;; Org-side: the heading at point stands for an issue (org buffers only).
    "Jl" '(rata-jira-org-link-heading :which-key "link org heading to issue")))

(provide 'init-jira)
