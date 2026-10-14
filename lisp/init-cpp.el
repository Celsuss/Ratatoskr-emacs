;;; -*- lexical-binding: t; -*-
;;; init-cpp.el --- C / C++ language support (GDExtension / general)

(require 'init-cmake)

(declare-function apheleia-format-buffer "apheleia")
(declare-function lsp-clangd-find-other-file "lsp-clangd")
(declare-function ff-find-other-file "find-file")
(declare-function dap-debug "dap-mode")
(declare-function lsp-deferred "lsp-mode")
(declare-function rata-leader "init-evil" (&rest args))
(declare-function rata-godot-project-p "init-gamedev")
(declare-function rata-godot-build-extension "init-gamedev")

(eval-when-compile
  (defvar lsp-clients-clangd-args)
  (defvar apheleia-mode-alist))

(defcustom rata-cpp-debugger 'gdb
  "Debugger to use for `rata-cpp-debug'.
Options are `gdb' (native Emacs GUD/GDB) or `dap' (via dap-mode)."
  :type '(choice (const :tag "Native GDB (GUD)" gdb)
                 (const :tag "DAP Mode" dap))
  :group 'rata)

;; File associations for C++ headers and inline files
(add-to-list 'auto-mode-alist '("\\.h\\'" . c++-ts-mode))
(add-to-list 'auto-mode-alist '("\\.hpp\\'" . c++-ts-mode))
(add-to-list 'auto-mode-alist '("\\.hxx\\'" . c++-ts-mode))
(add-to-list 'auto-mode-alist '("\\.inl\\'" . c++-ts-mode))
(add-to-list 'auto-mode-alist '("\\.tpp\\'" . c++-ts-mode))

(add-hook 'c++-ts-mode-hook #'lsp-deferred)
(add-hook 'c-ts-mode-hook #'lsp-deferred)

(with-eval-after-load 'lsp-mode
  (setq lsp-clients-clangd-args
        '("--header-insertion=never"
          "--clang-tidy"
          "--completion-style=detailed"
          "--background-index")))

(with-eval-after-load 'apheleia
  (setf (alist-get 'c++-ts-mode apheleia-mode-alist) 'clang-format)
  (setf (alist-get 'c-ts-mode apheleia-mode-alist) 'clang-format))

;; --- DAP / LLDB / GDB (C++ debugging) ---
(with-eval-after-load 'dap-mode
  (require 'dap-lldb nil t)
  (require 'dap-gdb-lldb nil t))

(defun rata-cpp-switch-header-source ()
  "Switch between C/C++ header and source file.
Uses `lsp-clangd-find-other-file' if LSP is active, falling back to
`ff-find-other-file'."
  (interactive)
  (cond
   ((and (bound-and-true-p lsp-mode)
         (fboundp 'lsp-clangd-find-other-file))
    (condition-case nil
        (lsp-clangd-find-other-file)
      (error (if (fboundp 'ff-find-other-file)
                 (ff-find-other-file nil t)
               (user-error "Failed to switch header/source file")))))
   ((fboundp 'ff-find-other-file)
    (ff-find-other-file nil t))
   (t (user-error "No header/source switching mechanism available"))))

(defun rata-cpp-build ()
  "Build the C/C++ project.
If inside a Godot GDExtension project, delegates to
`rata-godot-build-extension'.  Otherwise calls `rata-cmake-build'."
  (interactive)
  (if (and (fboundp 'rata-godot-project-p)
           (rata-godot-project-p)
           (fboundp 'rata-godot-build-extension))
      (rata-godot-build-extension)
    (rata-cmake-build)))

(defun rata-cpp-run (&optional target)
  "Run the built target executable for the current project.
Delegates to `rata-cmake-run'."
  (interactive)
  (rata-cmake-run target))

(defun rata-cpp-debug (&optional target)
  "Debug the project executable under GDB or DAP.
TARGET is the executable to debug.  If nil, resolves target via
`rata-cmake-resolve-target-executable'."
  (interactive)
  (let* ((root (rata-cmake-project-root))
         (default-directory root)
         (exe (or target (rata-cmake-resolve-target-executable))))
    (if exe
        (let ((exe-path (if (file-name-absolute-p exe)
                            exe
                          (expand-file-name exe (expand-file-name rata-cmake-build-directory root)))))
          (if (and (eq rata-cpp-debugger 'dap)
                   (bound-and-true-p dap-mode)
                   (fboundp 'dap-debug))
              (dap-debug
               (list :type "gdb"
                     :request "launch"
                     :name (format "C++: %s" (file-name-nondirectory exe-path))
                     :target exe-path
                     :cwd root))
            ;; Native Emacs GDB:
            (gdb (format "gdb -i=mi %s" (shell-quote-argument exe-path)))))
      (user-error "No executable found to debug; build the project first"))))

;; Keybindings for C/C++ modes
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    :keymaps '(c++-ts-mode-map c-ts-mode-map)
    "ma"  '(rata-cpp-switch-header-source :which-key "other file (header/source)")
    "mo"  '(rata-cpp-switch-header-source :which-key "other file (header/source)")
    "mb"  '(rata-cpp-build                :which-key "build project")
    "mr"  '(rata-cpp-run                  :which-key "run target")
    "md"  '(rata-cpp-debug                :which-key "debug target")
    "mf"  '(apheleia-format-buffer        :which-key "format buffer")
    "mc"  '(:ignore t :which-key "cmake")
    "mcc" '(rata-cmake-configure          :which-key "configure")
    "mcb" '(rata-cmake-build              :which-key "build")
    "mcl" '(rata-cmake-clean              :which-key "clean")
    "mcr" '(rata-cmake-rebuild            :which-key "rebuild")
    "mcs" '(rata-cmake-symlink-compile-commands :which-key "symlink compile_commands")))

(provide 'init-cpp)
