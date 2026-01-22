;; ~/.config/emacs-from-scratch/init.el

;; --- 1. Performance Hook ---
;; Reset GC threshold after initialization is finished
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 2 1024 1024)))) ; 2mb

;; --- 2. Module Loader ---
;; Add the 'lisp' folder to the load path so Emacs can find your files
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; --- 3. Keep 'custom.el' separate ---
;; By default, Emacs adds auto-generated config to init.el.
;; This moves it to a separate file to keep your init.el clean.
(setq custom-file (locate-user-emacs-file "custom.el"))
(when (file-exists-p custom-file)
  (load custom-file))

;; --- 4. Load Core Modules ---
(require 'init-pkg)
(require 'init-completion)
(require 'init-ui)
(require 'init-evil)
(require 'init-org)
