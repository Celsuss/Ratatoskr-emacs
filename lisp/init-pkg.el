;;; -*- lexical-binding: t; -*-
;;; init-pkg.el --- Package manager configuration (elpaca)

;; Elpaca is bootstrapped in early-init.el.
;; This module configures use-package defaults for all downstream modules.

;; All use-package declarations auto-install via elpaca
(setq use-package-always-ensure t)

(provide 'init-pkg)
