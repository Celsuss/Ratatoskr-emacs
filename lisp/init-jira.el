;;; -*- lexical-binding: t; -*-
;;; init-jira.el --- Jira issue browsing (jira.el)
;;
;; A read-mostly second view onto work tasks: Jira stays in Jira and gets its own
;; buffer, `work_tasks.org' stays hand-written.  Nothing here writes into the
;; org-roam tree.  Press `, e' in the issues list to export what is on screen to
;; Org-mode when a one-off bridge is wanted.  Key-by-key usage: docs/jira-cheatsheet.org.
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
  (jira-detail-reuse-buffer t))

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
  (rata-jira--bind-local-leader 'jira-issues-mode-map rata-jira-issues-key-mirror
                                "r" '(tablist-revert :which-key "refresh"))
  ;; `RET' opens the issue.  `evil-ret' moves down one line, which is useless in a
  ;; read-only list, and RET is what every other list-like buffer here uses.
  (general-define-key
   :states '(normal visual)
   :keymaps 'jira-issues-mode-map
   "RET" (lookup-key jira-issues-mode-map (kbd "RET"))))

(with-eval-after-load 'jira-detail
  (rata-jira--bind-local-leader 'jira-detail-mode-map rata-jira-detail-key-mirror))

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
    "Jt" '(jira-tempo  :which-key "tempo worklogs")))

(provide 'init-jira)
