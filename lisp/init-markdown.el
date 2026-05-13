;;; -*- lexical-binding: t; -*-
;;; init-markdown.el --- Markdown editing and live preview

(use-package markdown-mode
  :defer t)

;; --- Markdown Preview ---
(use-package web-server
  :ensure (web-server :host github :repo "eschulte/emacs-web-server"
                      :local-repo "emacs-web-server.github.eschulte"
                      :main "web-server.el")
  :defer t)

(use-package markdown-preview-mode
  :after (markdown-mode general)
  :commands markdown-preview-mode
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'markdown-mode-map
    "mp"  '(:ignore t :which-key "preview")
    "mpp" '(markdown-preview-mode :which-key "preview in browser")))

(provide 'init-markdown)
