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
  (setq which-key-idle-delay 0.1))

;; --- Nerd Icons ---
;; Run M-x nerd-icons-install-fonts once after first install
(use-package nerd-icons
  :demand t)

;; --- Doom Modeline ---
(use-package doom-modeline
  :after nerd-icons
  :init (doom-modeline-mode 1))

;; --- Rainbow Delimiters ---
(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;; --- Helpful ---
(use-package helpful
  :defer t
  :init
  (global-set-key [remap describe-function] #'helpful-callable)
  (global-set-key [remap describe-variable] #'helpful-variable)
  (global-set-key [remap describe-key]      #'helpful-key))

(with-eval-after-load 'init-evil
  (rata-leader
    :states '(normal visual insert emacs)
    "hf" '(helpful-callable :which-key "describe function")
    "hv" '(helpful-variable :which-key "describe variable")
    "hk" '(helpful-key      :which-key "describe key")))

;; --- Golden Ratio ---
(use-package golden-ratio
  :defer t
  :config
  (setq golden-ratio-exclude-buffer-regexp
        '("\\*magit" "\\*Org Agenda\\*" "\\*vterm\\*")))

(with-eval-after-load 'init-evil
  (rata-leader
    :states '(normal visual insert emacs)
    "tg" '(golden-ratio-mode :which-key "golden ratio")))

(provide 'init-ui)
