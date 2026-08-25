;;; -*- lexical-binding: t; -*-
;;; init-jira.el --- Jira issue browsing (jira.el)
;;
;; A read-mostly second view onto work tasks: Jira stays in Jira and gets its own
;; buffer, `work_tasks.org' stays hand-written.  Nothing here writes into the
;; org-roam tree.  Press `e' in the issues list to export what is on screen to
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
  (jira-detail-reuse-buffer t)
  :config
  ;; jira.el does not support evil (upstream issue #31), and its keymaps live in
  ;; `tabulated-list-mode' and `magit-section-mode' children, which evil shadows --
  ;; the same trap as the *claude-loop* buffer documented in AGENTS.md.  Re-binding
  ;; its dozen keys by hand would break on every upstream release, so these buffers
  ;; get emacs state instead and the documented keys (? l C U e H S) work as-is.
  ;; C-z toggles back to normal state.
  (with-eval-after-load 'evil
    (dolist (mode '(jira-issues-mode jira-detail-mode jira-tempo-mode))
      (evil-set-initial-state mode 'emacs))))

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
