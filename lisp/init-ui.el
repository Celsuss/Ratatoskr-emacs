;;; -*- lexical-binding: t; -*-
;;; init-ui.el --- UI configuration

;; Absolute line numbers
(setq display-line-numbers-type t)
(global-display-line-numbers-mode t)

;; Disable UI chrome (belt + suspenders with early-init.el). These are minor
;; modes, so they must be called as functions -- `setq'ing the mode variable
;; does not toggle the mode (the cursor kept blinking under the old code).
;; The bar modes are already off via early-init.el frame params.
(blink-cursor-mode -1)

;; --- Theme ---
(use-package gruvbox-theme
  :config
  (load-theme 'gruvbox-dark-medium t)
  (set-face-attribute 'line-number nil
                      :background (face-attribute 'default :background))
  (set-face-attribute 'line-number-current-line nil
                      :background (face-attribute 'default :background)))

;; --- Which-key ---
;; Built into Emacs 30; :ensure nil uses the bundled copy instead of pulling
;; the external ELPA package under `use-package-always-ensure'.
(use-package which-key
  :ensure nil
  :init
  (setq which-key-idle-delay 0.1
        which-key-idle-secondary-delay 0.05
        which-key-allow-imprecise-window-fit t)
  (which-key-mode)
)

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
    :states '(normal visual)
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
    :states '(normal visual)
    "tg" '(golden-ratio-mode :which-key "golden ratio")))

;; --- hl-todo (highlight TODO/FIXME keywords) ---
(use-package hl-todo
  :hook (prog-mode . hl-todo-mode)
  :config
  (setq hl-todo-keyword-faces
        '(("TODO"       . "#FF8C00")
          ("FIXME"      . "#FF0000")
          ("HACK"       . "#FF00FF")
          ("NOTE"       . "#00BFFF")
          ("DEPRECATED" . "#808080")
          ("BUG"        . "#FF0000")
          ("XXX"        . "#FF00FF"))))

(with-eval-after-load 'init-evil
  (rata-leader
    :states '(normal visual)
    "et" '(hl-todo-next     :which-key "next TODO")
    "eT" '(hl-todo-previous :which-key "prev TODO")))

(provide 'init-ui)
