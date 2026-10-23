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
(defvar rata-lisp-directory (expand-file-name "lisp" user-emacs-directory)
  "Directory holding this configuration's modules.")
(add-to-list 'load-path rata-lisp-directory)

;; --- 5. Keep 'custom.el' separate ---
;; Two different jobs, deliberately two files, both gitignored:
;;
;;   custom.el  Custom's own scratch pad.  Machine-generated churn (faces,
;;              safe-local-variable-values), rewritten whenever you save from
;;              `M-x customize'.  Never hand-edit it and never sync it.
;;   local.el   Hand-written, per-machine: the values that must not sit on a
;;              public remote (instance hostnames, corporate identity).  A fresh
;;              checkout starts from the committed `local.el.example', which is
;;              the authoritative list of what a new machine needs.
(setq custom-file (locate-user-emacs-file "custom.el"))
(when (file-exists-p custom-file)
  (load custom-file))

;; Loaded after custom.el so a hand-written value wins over a stale Custom one,
;; and before the modules so their `defvar's see it.
(load (locate-user-emacs-file "local.el") 'noerror 'nomessage)

;; --- 6. Load Core Modules ---
(defvar rata--failed-modules nil
  "List of (MODULE . ERROR-STRING) for modules that failed to load.")

;; --- 6a. What this session loaded, and from when ---
;; `rata-reload-config' (SPC q r) re-applies an edited file without a restart.
;; Everything it needs is one record per file of the mtime it was loaded from.
(defvar rata-init-file (or user-init-file
                          (expand-file-name "init.el" user-emacs-directory))
  "This configuration's entry point.
Not `user-init-file', which Emacs leaves nil under --batch (`just batch',
the ERT suite) where this file is loaded by hand.")

(defvar rata--config-file-mtimes (make-hash-table :test 'equal)
  "Absolute file name -> its modification time when this session loaded it.")

(defun rata--note-loaded (file)
  "Record FILE's modification time as the copy now in memory.  Return FILE."
  (when (and file (file-exists-p file))
    (puthash file (file-attribute-modification-time (file-attributes file))
             rata--config-file-mtimes))
  file)

(defun rata-config-file-changed-p (file)
  "Return non-nil if FILE was edited after this session loaded it.
A file this session never loaded has not changed: creating `local.el' on
a running Emacs is a restart, not a reload."
  (let ((loaded (and file (gethash file rata--config-file-mtimes))))
    (and loaded
         (file-exists-p file)
         (time-less-p loaded (file-attribute-modification-time
                              (file-attributes file))))))

(defun rata-module-file (module)
  "Return MODULE's source file under `rata-lisp-directory', or nil.
Deliberately the .el and never a .elc: a reload exists to pick up an
edit, and `load' handed a bare feature name takes the byte-compiled file
over a newer source, `load-prefer-newer' being nil by default."
  (let ((file (expand-file-name (format "%s.el" module) rata-lisp-directory)))
    (and (file-exists-p file) file)))

(defun rata-load-module (module)
  "Require MODULE with error handling.
When `init-file-debug' is set (--debug-init), errors propagate
normally for a full backtrace.  Otherwise, catch and log them to
`rata--failed-modules' so remaining modules still load."
  (if init-file-debug
      (progn (require module)
             (rata--note-loaded (rata-module-file module)))
    (condition-case err
        (progn (require module)
               (rata--note-loaded (rata-module-file module)))
      (error
       (let ((msg (error-message-string err)))
         (push (cons module msg) rata--failed-modules)
         (message "WARNING: Failed to load %s: %s" module msg))))))

;; --- 6b. Reloading a changed configuration ---
(defun rata-config-module-order ()
  "Return the modules `init.el' loads, in the order it loads them.
Read out of the file rather than recorded during startup, so a module
added to init.el since Emacs started is picked up by a reload.  A
commented-out `rata-load-module' line is not a form -- which is how
init.el disables a module -- so it stays disabled here too."
  (with-temp-buffer
    (insert-file-contents rata-init-file)
    (goto-char (point-min))
    (let ((eof (make-symbol "eof"))
          (modules nil)
          form)
      (while (not (eq (setq form (condition-case nil
                                     (read (current-buffer))
                                   (end-of-file eof)))
                      eof))
        (when (and (eq (car-safe form) 'rata-load-module)
                   (eq (car-safe (cadr form)) 'quote))
          (push (cadr (cadr form)) modules)))
      (nreverse modules))))

(defun rata-config-stale-modules ()
  "Return the loaded modules whose file was edited since, in load order."
  (let (stale)
    (dolist (module (rata-config-module-order))
      (when (and (featurep module)
                 (rata-config-file-changed-p (rata-module-file module)))
        (push module stale)))
    (nreverse stale)))

(defun rata--load-module-source (module)
  "Re-evaluate MODULE's own source file.  Signal if it has none."
  (let ((file (or (rata-module-file module)
                  (user-error "No source file for module %s" module))))
    (load file nil 'nomessage)
    (rata--note-loaded file)
    module))

(defun rata--drain-elpaca ()
  "Run the package forms a reload has just re-queued.
Draining the queue is what makes a reload mean anything.
`elpaca-use-package' wraps the whole expansion of a `use-package' form
in an `elpaca' form, so re-evaluating a module only re-queues its
packages: every `:custom', `:config' and `:general' clause in it runs
when that queue is processed, and after startup nothing drains it but
elpaca's own interactive timer.  A bare `load' of a module therefore
appears to do nothing at all."
  (when (fboundp 'elpaca-process-queues) (elpaca-process-queues)))

(defun rata-reload-module (module)
  "Re-evaluate MODULE and apply what it declares.
Interactively, complete over the modules `init.el' loads."
  (interactive
   (list (intern (completing-read "Reload module: "
                                  (rata-config-module-order) nil t))))
  (prog1 (rata--load-module-source module)
    (rata--drain-elpaca)
    (when (called-interactively-p 'interactive)
      (message "Reloaded %s" module))))

(defun rata--reload-report (files reloaded added failed)
  "Return the one-line summary `rata-reload-config' echoes.
FILES are per-machine file names, RELOADED, ADDED and FAILED are modules."
  (let ((parts (delq nil
                     (list (and (or files reloaded)
                                (format "reloaded %s"
                                        (mapconcat #'identity
                                                   (append files (mapcar #'symbol-name reloaded))
                                                   " ")))
                           (and added (format "loaded new %s"
                                              (mapconcat #'symbol-name added " ")))
                           (and failed (format "FAILED %s"
                                               (mapconcat #'symbol-name failed " ")))))))
    (concat "Config: "
            (if parts
                (mapconcat #'identity parts ", ")
              "nothing to reload, no file has changed")
            (and (rata-config-file-changed-p rata-init-file)
                 " (init.el itself changed: restart for anything but its module list)"))))

(defun rata-reload-config (&optional force)
  "Reload every part of this configuration that has changed on disk.

Reloads `custom.el' and `local.el' if they were edited, every module
whose file was edited, and any module added to `init.el' since startup --
in init.el's own load order.  With a prefix argument FORCE, reload every
module whether or not it changed.

init.el itself is never re-run: that would replay the elpaca bootstrap
against a live session.  A change to init.el beyond its
`rata-load-module' lines is reported as needing a restart, and so does
installing a package added since startup (`M-x elpaca-try' does that one
on its own)."
  (interactive "P")
  (let ((stale (rata-config-stale-modules))
        (files nil) (reloaded nil) (added nil) (failed nil))
    (dolist (file (list custom-file (locate-user-emacs-file "local.el")))
      (when (rata-config-file-changed-p file)
        (load (rata--note-loaded file) nil 'nomessage)
        (push (file-name-nondirectory file) files)))
    (dolist (module (rata-config-module-order))
      (cond
       ((not (featurep module))
        (rata-load-module module)
        (if (featurep module)
            (push module added)
          (push module failed)))
       ((or force (memq module stale))
        (condition-case err
            (progn (rata--load-module-source module)
                   (push module reloaded))
          (error
           (push module failed)
           (message "WARNING: reloading %s failed: %s"
                    module (error-message-string err)))))))
    (rata--drain-elpaca)
    (setq files (nreverse files)
          reloaded (nreverse reloaded)
          added (nreverse added)
          failed (nreverse failed))
    (message "%s" (rata--reload-report files reloaded added failed))
    (list :files files :reloaded reloaded :added added :failed failed)))

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

;; Section 5 loaded these moments ago and this file is being read right now;
;; recording them is what lets `rata-reload-config' notice a later edit.
(mapc #'rata--note-loaded
      (list rata-init-file custom-file (locate-user-emacs-file "local.el")))

(rata-load-module 'init-pkg)
(rata-load-module 'init-system)
(rata-load-module 'init-net)          ; curl-based fetching; shr images for elfeed et al.
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
(rata-load-module 'init-sql)
(rata-load-module 'init-k8s)
(rata-load-module 'init-gamedev)
(rata-load-module 'init-snippets)
(rata-load-module 'init-llm)
(rata-load-module 'init-claude-loop)
(rata-load-module 'init-claude-loop-acp)
(rata-load-module 'init-khoj)
(rata-load-module 'init-irc)
(rata-load-module 'init-elfeed)
(rata-load-module 'init-elfeed-hn)
(rata-load-module 'init-mail)      ; mu4e over Proton Mail Bridge
(rata-load-module 'init-jira)
;; (rata-load-module 'init-mcp)      ; experimental — uncomment when stable
(rata-load-module 'init-persp)
(rata-load-module 'init-agent-permissions) ; agent-shell permission whitelist/blacklist policies
(rata-load-module 'init-agent-center) ; agent-shell overview across layouts
(rata-load-module 'init-agent-worktree) ; one git worktree + layout per agent task
(rata-load-module 'init-agent-prompts) ; prompt library inserted into agent shells
(rata-load-module 'init-agent-review)  ; interactive diff & review hub for agent worktrees
(rata-load-module 'init-agent-artifacts) ; Antigravity artifact opening and plan approval
(rata-load-module 'init-org)
(rata-load-module 'init-blog)      ; org-roam -> hugo blog export
(rata-load-module 'init-dialogic)  ; dialogic formatting for blog posts
(rata-load-module 'init-present)   ; org-re-reveal slide export
(rata-load-module 'init-dashboard)

;; Interactively we do NOT drain the queue here: a trailing (elpaca-wait) forced
;; EVERY package to finish installing and loading before `emacs-startup-hook'
;; fired, which negated the :defer/:after deferral the modules set up. general +
;; evil already synchronise via the (elpaca-wait) in init-evil.el, which is all
;; downstream modules need for their keymaps.
;;
;; In batch/headless runs (`just batch', the ERT suite, CI) there is no idle
;; loop to run elpaca's async queue, so nothing would be installed or autoloaded
;; before the process inspects the environment and exits. There we must drain
;; the queue synchronously -- otherwise deferred-package commands are not even
;; autoloaded and every static check that resolves a command symbol fails.
(when noninteractive
  (elpaca-wait))
