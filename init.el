;;; -*- lexical-binding: t; -*-
;;; init.el --- Ratatoskr Emacs configuration entry point

;; --- 1. GC ---
;; gcmh (in init-system.el) handles runtime GC tuning;
;; early-init.el sets gc-cons-threshold to most-positive-fixnum for startup.
;; Fallback: reset GC threshold after startup (gcmh takes over ~1s later).
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 16 1024 1024)))) ; gcmh takes over later

;; --- 2. Elpaca Bootstrap ---
(setq elpaca-queue-limit 5)
(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-sources-directory (expand-file-name "sources/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1 :inherit ignore
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca-activate)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-sources-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (<= emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let* ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                  ((zerop (apply #'call-process `("git" nil ,buffer t "clone"
                                                  ,@(when-let* ((depth (plist-get order :depth)))
                                                      (list (format "--depth=%d" depth) "--no-single-branch"))
                                                  ,(plist-get order :repo) ,repo))))
                  ((zerop (call-process "git" nil buffer t "checkout"
                                        (or (plist-get order :ref) "--"))))
                  (emacs (concat invocation-directory invocation-name))
                  ((zerop (call-process emacs nil buffer nil "-Q" "-L" "." "--batch"
                                        "--eval" "(byte-recompile-directory \".\" 0 'force)")))
                  ((require 'elpaca))
                  ((elpaca-generate-autoloads "elpaca" repo)))
            (progn (message "%s" (buffer-string)) (kill-buffer buffer))
          (error "%s" (with-current-buffer buffer (buffer-string))))
      ((error) (warn "%s" err) (delete-directory repo 'recursive))))
  (unless (require 'elpaca-autoloads nil t)
    (require 'elpaca)
    (elpaca-generate-autoloads "elpaca" repo)
    (let ((load-source-file-function nil)) (load "./elpaca-autoloads"))))
(add-hook 'after-init-hook #'elpaca-process-queues)
(elpaca `(,@elpaca-order))

;; --- 3. Elpaca use-package integration ---
(elpaca elpaca-use-package
        (elpaca-use-package-mode))

;; Process bootstrap queue synchronously so packages are on load-path
;; before modules are loaded below.
(elpaca-wait)

;; --- 4. Module Loader ---
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;; --- 5. Keep 'custom.el' separate ---
(setq custom-file (locate-user-emacs-file "custom.el"))
(when (file-exists-p custom-file)
  (load custom-file))

;; --- 6. Load Core Modules ---
(defvar rata--failed-modules nil
  "List of (MODULE . ERROR-STRING) for modules that failed to load.")

(defun rata-load-module (module)
  "Require MODULE with error handling.
When `init-file-debug' is set (--debug-init), errors propagate
normally for a full backtrace.  Otherwise, catch and log them to
`rata--failed-modules' so remaining modules still load."
  (if init-file-debug
      (require module)
    (condition-case err
        (require module)
      (error
       (let ((msg (error-message-string err)))
         (push (cons module msg) rata--failed-modules)
         (message "WARNING: Failed to load %s: %s" module msg))))))

(defun rata-report-init-errors ()
  "Print a summary of any modules that failed to load."
  (when rata--failed-modules
    (with-current-buffer (get-buffer-create "*init-errors*")
      (erase-buffer)
      (insert "Ratatoskr: the following modules failed to load:\n\n")
      (dolist (entry (nreverse rata--failed-modules))
        (insert (format "  %-25s %s\n" (car entry) (cdr entry))))
      (insert "\nRun M-x debug-init or `just debug' for a full backtrace.\n"))
    (message "WARNING: %d module(s) failed — see *init-errors* buffer"
             (length rata--failed-modules))))

(add-hook 'emacs-startup-hook #'rata-report-init-errors)

(rata-load-module 'init-pkg)
(rata-load-module 'init-system)
(rata-load-module 'init-ui)
(rata-load-module 'init-evil)        ; includes (elpaca-wait) — general + evil synchronize here
(rata-load-module 'init-completion)
(rata-load-module 'init-dev)
(rata-load-module 'init-lang)         ; treesit + dap-mode + combobulate
(rata-load-module 'init-rust)
(rata-load-module 'init-go)
(rata-load-module 'init-python)
(rata-load-module 'init-cpp)
(rata-load-module 'init-cmake)
(rata-load-module 'init-terraform)
(rata-load-module 'init-just)
(rata-load-module 'init-docker)
(rata-load-module 'init-markdown)
(rata-load-module 'init-yaml)
(rata-load-module 'init-ansible)
(rata-load-module 'init-jupyter)
(rata-load-module 'init-helm)
(rata-load-module 'init-pkgbuild)
(rata-load-module 'init-casual)
(rata-load-module 'init-k8s)
(rata-load-module 'init-gamedev)
(rata-load-module 'init-snippets)
(rata-load-module 'init-llm)
(rata-load-module 'init-irc)
(rata-load-module 'init-elfeed)
;; (rata-load-module 'init-mcp)      ; experimental — uncomment when stable
(rata-load-module 'init-persp)
(rata-load-module 'init-org)
(rata-load-module 'init-dashboard)
(elpaca-wait) ; ensure all packages fully loaded before startup hooks fire
