;;; -*- lexical-binding: t; -*-
;;; init-completion.el --- Completion framework (vertico, consult, embark, corfu)

;; --- Orderless Completion Style ---
(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion))))
  (completion-category-defaults nil)
  (completion-pcm-leading-wildcard t))

;; --- Vertico Vertical Completion UI ---
(use-package vertico
  :init
  (vertico-mode)
  :custom
  (vertico-cycle t)
  :config
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
  :init
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
  :custom
  (corfu-auto t)
  (corfu-auto-prefix 1)
  (corfu-auto-delay 0.2)
  (corfu-cycle t)
  :init
  (global-corfu-mode)
  (corfu-history-mode))

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
(use-package wgrep
  :after embark
  :custom
  (wgrep-auto-save-buffer t))

(provide 'init-completion)
