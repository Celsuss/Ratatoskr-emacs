;;; -*- lexical-binding: t; -*-
;;; init-system.el --- System-level defaults (paths, backups, environment)

;; Redirect auto-generated files out of user-emacs-directory
(use-package no-littering
  :demand t)

;; Copy shell environment into Emacs (critical for daemon mode)
(use-package exec-path-from-shell
  :demand t
  :config
  (when (daemonp)
    (exec-path-from-shell-initialize)))

(provide 'init-system)
