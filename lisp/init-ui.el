;; ~/.config/emacs-from-scratch/lisp/init-ui.el

;; Enable relative line numbers (standard for Vim/Spacemacs users)
(setq display-line-numbers-type 'relative)
(global-display-line-numbers-mode t)

;; Disable unwanted stuff
(setq tool-bar-mode     0    ;; Remove toolbar
      scroll-bar-mode   0    ;; Remove scollbars
      menu-bar-mode     0    ;; Remove menu bar
      blink-cursor-mode 0)   ;; Solid cursor, not blinking

;; Install and load the Doom One theme (very popular Spacemacs look)
(use-package doom-themes
  :config
  (load-theme 'doom-one t))

(use-package which-key
  :init (which-key-mode)
  :config
  (setq which-key-idle-delay 0.3))

(provide 'init-ui)
