;;; -*- lexical-binding: t; -*-
;;; init-khoj.el --- Khoj 2.0 self-hosted semantic search + chat

(use-package khoj
  :after general
  :commands (khoj khoj--chat khoj--new-conversation-session
             khoj--open-conversation-session khoj--delete-conversation-session
             khoj--server-index-files)
  :custom
  (khoj-server-url "http://khoj.homelab.local")
  (khoj-server-is-local t)
  (khoj-results-count 8)
  (khoj-index-directories (list (expand-file-name "~/workspace/second-brain/org-roam/")))
  :config
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
