;;; -*- lexical-binding: t; -*-
;;; init-system.el --- System-level defaults (paths, backups, environment)

;; Redirect auto-generated files out of user-emacs-directory
(use-package no-littering
  :demand t
  :config
  (no-littering-theme-backups))

;; Copy shell environment into Emacs (critical for daemon mode)
(use-package exec-path-from-shell
  :demand t
  :config
  (when (daemonp)
    (exec-path-from-shell-initialize)))

;; --- GC Magic Hack (adaptive GC threshold) ---
;; Replaces manual gc-cons-threshold reset; idles at low threshold,
;; bumps to 16MB during interactive use to avoid micro-stutters.
;; Deferred to avoid blocking elpaca queue on first install.
(use-package gcmh
  :defer 1
  :custom
  (gcmh-idle-delay 5)
  (gcmh-high-cons-threshold (* 16 1024 1024))
  :config
  (gcmh-mode 1))

;; Recent file tracking
(recentf-mode 1)
(setq recentf-max-saved-items 200)

;; Ediff: side-by-side in same frame, restore windows on quit
(setq ediff-split-window-function #'split-window-horizontally
      ediff-window-setup-function #'ediff-setup-windows-plain)
(add-hook 'ediff-after-quit-hook-internal #'winner-undo)

;; Auth-source: read credentials from ~/.authinfo.gpg
(setq auth-sources '("~/.authinfo.gpg"))

;; GPG: use loopback pinentry so passphrase prompts don't freeze Emacs
(use-package epa
  :ensure nil
  :custom
  (epg-pinentry-mode 'loopback))

(defun rata-auth-get (host &optional user)
  "Get password from auth-source for HOST, optionally filtering by USER."
  (auth-source-pick-first-password :host host :user user))

;; TRAMP
(setq tramp-default-method "ssh")
(with-eval-after-load 'tramp
  (setq tramp-persistency-file-name
        (expand-file-name "var/tramp" user-emacs-directory))
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path))

;; Helper for TRAMP guards (used by apheleia, lsp file-watchers, etc.)
(defun rata-tramp-buffer-p ()
  "Return non-nil if current buffer is visiting a remote file."
  (and (buffer-file-name) (file-remote-p (buffer-file-name))))

;; Shackle: rule-based popup/buffer placement
(use-package shackle
  :demand t
  :config
  (shackle-mode 1)
  (setq shackle-rules
        '(("*compilation*"     :align below :size 0.3 :popup t)
          ("*vterm*"           :align below :size 0.4 :popup t :select t)
          ("*Help*"            :align right :size 0.4 :popup t :select t)
          ("*helpful*"         :align right :size 0.4 :popup t :select t :regexp t)
          ("*grep*"            :align below :size 0.3 :popup t)
          ("*Flycheck errors*" :align below :size 0.25 :popup t)
          ("*lsp-help*"        :align right :size 0.4 :popup t :select t)
          ("*Messages*"        :align below :size 0.25 :popup t))))

;; --- Popper (popup management) ---
(use-package popper
  :after general
  :demand t
  :config
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*Warnings\\*"
          "Output\\*$"
          "\\*Async Shell Command\\*"
          "\\*compilation\\*"
          "\\*Backtrace\\*"
          "\\*Help\\*"
          "\\*helpful"
          "\\*Flycheck errors\\*"
          "\\*lsp-help\\*"
          "\\*grep\\*"
          "\\*cargo-.*\\*"
          "\\*pytest.*\\*"
          "\\*restclient.*\\*"
          vterm-mode))
  (popper-mode 1)
  (global-set-key (kbd "M-`") #'popper-toggle)
  (global-set-key (kbd "C-M-`") #'popper-cycle)
  (global-set-key (kbd "M-~") #'popper-toggle-type))

;; Auto-save buffers on focus loss, buffer switch, idle
(use-package super-save
  :defer 1
  :custom
  (super-save-auto-save-when-idle t)
  (super-save-idle-duration 10)
  :config
  (super-save-mode 1))

(provide 'init-system)
