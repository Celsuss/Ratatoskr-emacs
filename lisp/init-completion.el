;;; -*- lexical-binding: t; -*-

;; ~/.config/emacs-from-scratch/lisp/init-completion.el

;; --- Orderless Completion Style ---
;; Set up Orderless as the default completion style for better pattern matching
;; https://github.com/oantolin/orderless
(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion))))
  (completion-category-defaults nil) ;; Disable defaults, use vertico settings
  (completion-pcm-leading-wildcard t)) ;; Emacs 31: partial-completion behaves like substring

;; --- Vertico Vertical Completion UI ---
;; Main completion interface with vertical layout
;; https://github.com/minad/vertico
(use-package vertico
  :init
  (vertico-mode)
  :custom
  (vertico-cycle t)  ; Enable cycling through completion candidates
  ;; (vertico-scroll-margin 0) ;; Different scroll margin
  ;; (vertico-count 20) ;; Show more candidates
  ;; (vertico-resize t) ;; Grow and shrink the Vertico minibuffer
  :config
  ;; Enable Vertico's keybindings for better navigation
  (setq vertico-resize nil
        vertico-count 10))

;; Persist history over Emacs restarts. Vertico sorts by history position.
(use-package savehist
  :init
  (savehist-mode))

;; --- Marginalia Annotations ---
;; Add rich annotations to completion candidates
;; https://github.com/minad/marginalia
(use-package marginalia
  :after vertico
  :init
  (marginalia-mode)
  :custom
  (marginalia-annotators '(marginalia-annotators-heavy marginalia-annotators-light nil)))

;; --- Consult Enhanced Commands ---
;; Replace standard Emacs commands with enhanced Consult equivalents
;; https://github.com/minad/consult
(use-package consult
  :after vertico
  :config
  ;; Configure Consult to use ripgrep when available
  (setq consult-find-command "find . -type f -not -path '*/.*' -print0 | xargs -0 grep -l ''"
        consult-ripgrep-command "rg --null --line-buffered --color=never --max-columns=1000 --path-separator / --smart-case --no-heading --with-filename --line-number --search-context-separator ' -- ' ''"))



;; --- Embark Actions ---
;; Context-sensitive actions for completion candidates
;; https://github.com/oantolin/embark
(use-package embark
  :after vertico
  :config
  ;; Embark keybindings for various contexts
  (setq embark-action-indicator 'highlight
        embark-become-indicator 'highlight
        embark-prompter 'embark-completing-read-prompter))


;; --- Embark Consult Integration ---
;; Integration between Embark and Consult for enhanced functionality
;; https://github.com/emacs-straight/embark-consult
(use-package embark-consult
  :after (embark consult)
  :hook
  (embark-collect-mode . consult-preview-at-point-mode))

;; --- Embark Keybindings ---
;; Set up keybindings for Embark actions
;; TODO Fix this it's not working
(with-eval-after-load 'vertico
  (general-define-key
   :keymaps 'vertico-map
   "C-." 'embark-act  ; Embark action on candidate
   "C-;" 'embark-export)) ; Export candidate to buffer


(provide 'init-completion)
