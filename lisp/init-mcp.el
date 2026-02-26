;;; -*- lexical-binding: t; -*-
;;; init-mcp.el --- MCP server integration (EXPERIMENTAL)
;;
;; This module is experimental. Comment out (require 'init-mcp) in init.el
;; until mcp + mcp-server-emacs stabilize.

(use-package mcp
  :after general
  :config
  (rata-leader
    :states '(normal visual)
    "am"   '(:ignore t :which-key "MCP")
    "ams"  '(mcp-server-start :which-key "start server")
    "amS"  '(mcp-server-stop  :which-key "stop server")
    "aml"  '(mcp-list-resources :which-key "list resources")))

(provide 'init-mcp)
