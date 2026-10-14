;;; -*- lexical-binding: t; -*-
;;; init-cmake.el --- CMake build system support

(require 'cl-lib)

(declare-function projectile-project-root "projectile")
(declare-function rata-leader "init-evil" (&rest args))

(defcustom rata-cmake-generator
  (if (executable-find "ninja") "Ninja" "Unix Makefiles")
  "CMake generator to use for `rata-cmake-configure'.
Defaults to \"Ninja\" if the ninja executable is on PATH, otherwise
\"Unix Makefiles\"."
  :type 'string
  :group 'rata)

(defcustom rata-cmake-build-directory "build"
  "Name or path of the build directory used by `rata-cmake-*' commands."
  :type 'string
  :group 'rata)

(defcustom rata-cmake-target-executable nil
  "Relative path or name of the target executable inside the build directory.
When nil, `rata-cmake-run' will attempt to auto-detect or prompt."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Executable name or path"))
  :group 'rata)

(defun rata-cmake-project-root ()
  "Return the project root directory or `default-directory'."
  (or (and (fboundp 'projectile-project-root)
           (projectile-project-root))
      default-directory))

(defun rata-cmake-symlink-compile-commands (&optional root)
  "Symlink build/compile_commands.json to the project ROOT.
If ROOT is nil, uses `rata-cmake-project-root'."
  (interactive)
  (let* ((proj-root (expand-file-name (or root (rata-cmake-project-root))))
         (src (expand-file-name "compile_commands.json"
                                (expand-file-name rata-cmake-build-directory proj-root)))
         (dest (expand-file-name "compile_commands.json" proj-root)))
    (if (file-exists-p src)
        (progn
          (when (or (file-symlink-p dest) (file-exists-p dest))
            (delete-file dest))
          (make-symbolic-link src dest t)
          (message "Linked compile_commands.json -> %s" src))
      (message "No compile_commands.json found in %s"
               (expand-file-name rata-cmake-build-directory proj-root)))))

(defun rata-cmake-configure (&optional extra-args)
  "Run cmake configure, generating build/ with `rata-cmake-generator'.
Automatically exports compile_commands.json and symlinks it to project root.
Runs from the projectile project root.  EXTRA-ARGS is passed to cmake."
  (interactive)
  (let* ((root (rata-cmake-project-root))
         (default-directory root)
         (bdir (shell-quote-argument rata-cmake-build-directory))
         (gen (shell-quote-argument rata-cmake-generator))
         (extra (if (and extra-args (not (string-empty-p extra-args)))
                    (concat " " extra-args)
                  ""))
         (cmd (format "cmake -S . -B %s -G %s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON%s && cmake -E create_symlink %s/compile_commands.json compile_commands.json"
                      bdir gen extra bdir)))
    (compile cmd)))

(defun rata-cmake-build ()
  "Build the cmake project in `rata-cmake-build-directory'.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (rata-cmake-project-root)))
    (compile (format "cmake --build %s"
                     (shell-quote-argument rata-cmake-build-directory)))))

(defun rata-cmake-clean ()
  "Clean the cmake build directory without reconfiguring.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (rata-cmake-project-root)))
    (compile (format "cmake --build %s --target clean"
                     (shell-quote-argument rata-cmake-build-directory)))))

(defun rata-cmake-rebuild ()
  "Clean and rebuild the cmake project in one step.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (rata-cmake-project-root)))
    (compile (format "cmake --build %s --clean-first"
                     (shell-quote-argument rata-cmake-build-directory)))))

(defun rata-cmake--find-executables (build-dir)
  "Find executable files in BUILD-DIR, excluding build system internals."
  (when (file-directory-p build-dir)
    (let (execs)
      (dolist (file (directory-files-recursively build-dir "" nil t))
        (when (and (file-regular-p file)
                   (file-executable-p file)
                   (not (string-match-p "/CMakeFiles/" file))
                   (not (string-match-p "/\\.ninja" file))
                   (not (string-match-p "\\.\\(so\\|a\\|o\\|dylib\\|dll\\|cmake\\)\\'" file)))
          (push file execs)))
      (nreverse execs))))

(defun rata-cmake-resolve-target-executable ()
  "Resolve the executable path to run for the current project."
  (let* ((root (rata-cmake-project-root))
         (build-dir (expand-file-name rata-cmake-build-directory root)))
    (cond
     ((and rata-cmake-target-executable
           (file-executable-p (expand-file-name rata-cmake-target-executable build-dir)))
      (expand-file-name rata-cmake-target-executable build-dir))
     (t
      (let* ((candidates (rata-cmake--find-executables build-dir))
             (proj-name (and root (file-name-nondirectory (directory-file-name root))))
             (exact-match (and proj-name
                               (cl-find proj-name candidates
                                        :test (lambda (name file)
                                                (equal name (file-name-nondirectory file)))))))
        (cond
         (exact-match exact-match)
         ((= (length candidates) 1) (car candidates))
         ((> (length candidates) 1)
          (let ((choice (completing-read "Run executable: "
                                         (mapcar (lambda (f) (file-relative-name f build-dir))
                                                 candidates)
                                         nil t nil nil
                                         (and exact-match (file-relative-name exact-match build-dir)))))
            (expand-file-name choice build-dir)))
         (t nil)))))))

(defun rata-cmake-run (&optional target)
  "Run the built executable for the current CMake project.
If TARGET is provided, run that executable.  Otherwise resolves target
via `rata-cmake-resolve-target-executable'."
  (interactive)
  (let* ((root (rata-cmake-project-root))
         (default-directory root)
         (exe (or target (rata-cmake-resolve-target-executable))))
    (if exe
        (let ((exe-path (if (file-name-absolute-p exe)
                            exe
                          (expand-file-name exe (expand-file-name rata-cmake-build-directory root)))))
          (compile (shell-quote-argument exe-path)))
      (user-error "No executable found in %s; build the project first with `rata-cmake-build'"
                  (expand-file-name rata-cmake-build-directory root)))))

(use-package cmake-mode
  :mode (("CMakeLists\\.txt\\'" . cmake-mode)
         ("\\.cmake\\'" . cmake-mode))
  :after general
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'cmake-mode-map
    "mc"  '(:ignore t :which-key "cmake")
    "mcc" '(rata-cmake-configure :which-key "configure")
    "mcb" '(rata-cmake-build     :which-key "build")
    "mcl" '(rata-cmake-clean     :which-key "clean")
    "mcr" '(rata-cmake-rebuild   :which-key "rebuild")
    "mcs" '(rata-cmake-symlink-compile-commands :which-key "symlink compile_commands")
    "mr"  '(rata-cmake-run       :which-key "run target")))

(provide 'init-cmake)
