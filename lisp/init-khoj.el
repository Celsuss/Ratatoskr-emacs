;;; -*- lexical-binding: t; -*-
;;; init-khoj.el --- Khoj 2.0 self-hosted semantic search + chat

;; The server is a `rata-' variable, not a bare :custom literal, so it can be
;; overridden from local.el (D-012).  A `(setq khoj-server-url ...)' there does
;; NOT work: use-package's :custom expands to `custom-theme-set-variables',
;; which sets the variable when khoj loads and silently overwrites whatever
;; local.el put there first.  Routing the :custom value through a variable that
;; local.el can set is the fix; `rata-test-khoj-server-url-comes-from-rata-variable'
;; and the `local-example-in-sync' audit keep it that way (L-051).  The homelab
;; hostname stays in git because it resolves nowhere but on that LAN.
(defvar rata-khoj-server-url "http://khoj.homelab.local"
  "Khoj server the `khoj' package talks to.  Set per machine in local.el.")

(use-package khoj
  :after general
  :commands (khoj khoj--chat khoj--new-conversation-session
             khoj--open-conversation-session khoj--delete-conversation-session
             khoj--server-index-files)
  :custom
  (khoj-server-url rata-khoj-server-url)
  (khoj-server-is-local t)
  (khoj-results-count 8)
  (khoj-index-directories (list (expand-file-name "~/workspace/second-brain/org-roam/"))))

;; Global leader keys at top level so they are live from startup (FAIL-0009).
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aik"   '(:ignore t :which-key "khoj")
    "aikk"  '(khoj                              :which-key "khoj")
    "aikc"  '(khoj--chat                        :which-key "chat")
    "aikn"  '(khoj--new-conversation-session    :which-key "new conversation")
    "aiko"  '(khoj--open-conversation-session   :which-key "open conversation")
    "aikd"  '(khoj--delete-conversation-session :which-key "delete conversation")
    "aiku"  '(khoj--server-index-files          :which-key "update index")))

(provide 'init-khoj)
