;;; -*- lexical-binding: t; -*-
;;; init.el --- Ratatoskr Emacs configuration entry point

;; --- 1. Performance Hook ---
;; Reset GC threshold after initialization is finished
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 2 1024 1024)))) ; 2mb

;; --- 2. Elpaca Bootstrap ---
(defvar elpaca-installer-version 0.11)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-repos-directory (expand-file-name "repos/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1 :inherit ignore
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca--activate-package)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-repos-directory))
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
(rata-load-module 'init-lang)
(rata-load-module 'init-k8s)
(rata-load-module 'init-gamedev)
(rata-load-module 'init-snippets)
(rata-load-module 'init-llm)
(rata-load-module 'init-irc)
;; (rata-load-module 'init-mcp)      ; experimental — uncomment when stable
(rata-load-module 'init-persp)
(rata-load-module 'init-org)
(rata-load-module 'init-dashboard)
(elpaca-wait) ; ensure all packages fully loaded before startup hooks fire
