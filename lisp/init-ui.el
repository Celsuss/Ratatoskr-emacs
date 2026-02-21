;;; -*- lexical-binding: t; -*-
;;; init-ui.el --- UI configuration

;; Relative line numbers
(setq display-line-numbers-type 'relative)
(global-display-line-numbers-mode t)

;; Disable UI chrome (belt + suspenders with early-init.el)
(setq tool-bar-mode     0
      scroll-bar-mode   0
      menu-bar-mode     0
      blink-cursor-mode 0)

;; --- Theme ---
(use-package gruvbox-theme
  :config
  (load-theme 'gruvbox-dark-medium t))

;; --- Which-key ---
(use-package which-key
  :init (which-key-mode)
  :config
  (setq which-key-idle-delay 0.3))

;; --- Nerd Icons ---
;; Run M-x nerd-icons-install-fonts once after first install
(use-package nerd-icons
  :demand t)

;; --- Doom Modeline ---
(use-package doom-modeline
  :after nerd-icons
  :init (doom-modeline-mode 1))

(provide 'init-ui)
