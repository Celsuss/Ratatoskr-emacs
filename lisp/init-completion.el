;;; -*- lexical-binding: t; -*-
;;; init-completion.el --- Completion framework (vertico, consult, embark, corfu)

;; --- Orderless Completion Style ---
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion))))
  (completion-pcm-leading-wildcard t))

;; --- Vertico Vertical Completion UI ---
(use-package vertico
  :demand t
  :custom
  (vertico-cycle t)
  :config
  (vertico-mode)
  (setq vertico-resize nil
        vertico-count 10))

;; Persist history over Emacs restarts. Vertico sorts by history position.
(use-package savehist
  :ensure nil
  :init
  (savehist-mode))

;; --- Marginalia Annotations ---
(use-package marginalia
  :after vertico
  :config
  (marginalia-mode)
  :custom
  (marginalia-annotators '(marginalia-annotators-heavy marginalia-annotators-light nil)))

;; --- Consult Enhanced Commands ---
(use-package consult
  :after vertico)

;; --- Embark Actions ---
(use-package embark
  :after vertico
  :bind
  (:map vertico-map
   ("C-." . embark-act)
   ("C-;" . embark-export))
  :config
  (setq embark-action-indicator 'highlight
        embark-become-indicator 'highlight
        embark-prompter 'embark-completing-read-prompter))

;; --- Embark Consult Integration ---
(use-package embark-consult
  :after (embark consult)
  :hook
  (embark-collect-mode . consult-preview-at-point-mode))

;; --- Corfu (in-buffer completion popup) ---
(use-package corfu
  :demand t
  :custom
  (corfu-auto t)
  (corfu-auto-prefix 1)
  (corfu-auto-delay 0.2)
  (corfu-cycle t)
  :config
  (global-corfu-mode)
  (corfu-history-mode))

;; --- Corfu Terminal (child-frame fallback for TUI) ---
(use-package corfu-terminal
  :after corfu
  :config
  (unless (display-graphic-p)
    (corfu-terminal-mode 1)))

;; --- Cape (completion-at-point extensions) ---
(use-package cape
  :after corfu
  :init
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-dabbrev))

;; --- Nerd Icons Corfu ---
(use-package nerd-icons-corfu
  :after (corfu nerd-icons)
  :config
  (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

;; --- Wgrep (editable grep buffers) ---
(autoload 'wgrep-change-to-wgrep-mode "wgrep" nil t)

(use-package wgrep
  :after embark
  :commands (wgrep-change-to-wgrep-mode wgrep-finish-edit wgrep-abort-changes)
  :custom
  (wgrep-auto-save-buffer t))

(provide 'init-completion)
