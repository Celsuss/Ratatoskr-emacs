;;; -*- lexical-binding: t; -*-
;;; init-gamedev.el --- Game development (Godot 4.x / GDExtension)

(require 'cl-lib)
(eval-when-compile
  (require 'subr-x))

(defcustom rata-godot-executable "godot"
  "Path or binary name for the Godot editor executable.
When \"godot\", `rata-godot-executable-path' searches PATH, Steam
installation directories, and Flatpak before falling back to this name."
  :type 'string
  :group 'rata)

(defcustom rata-godot-build-command nil
  "Custom command to compile the C++ GDExtension library.
When nil, `rata-godot-build-extension' detects whether to use SCons,
CMake, or just."
  :type '(choice (const :tag "Auto-detect" nil)
                 (string :tag "Command string"))
  :group 'rata)

(defconst rata-godot-known-paths
  '("~/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64"
    "~/.steam/steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64"
    "~/.local/share/Steam/steamapps/common/Godot Engine/godot.x86_64"
    "~/.steam/steam/steamapps/common/Godot Engine/godot.x86_64"
    "/var/lib/flatpak/exports/bin/org.godotengine.Godot"
    "~/.local/share/flatpak/exports/bin/org.godotengine.Godot")
  "List of well-known fallback paths for the Godot binary.")

(defun rata-godot-executable-path ()
  "Return resolved path to the Godot binary.
Resolves `rata-godot-executable' if it is an existing file or on PATH,
then checks `rata-godot-known-paths', falling back to `rata-godot-executable'."
  (cond
   ((and (file-name-absolute-p rata-godot-executable)
         (file-executable-p (expand-file-name rata-godot-executable)))
    (expand-file-name rata-godot-executable))
   ((executable-find rata-godot-executable)
    (executable-find rata-godot-executable))
   ((cl-some (lambda (p)
               (let ((exp (expand-file-name p)))
                 (when (file-executable-p exp) exp)))
             rata-godot-known-paths))
   (t rata-godot-executable)))

(defun rata-godot-project-root (&optional dir)
  "Return the directory containing project.godot, or nil.
Starts searching from DIR or `default-directory'.  If not found in parent
hierarchy, checks subdirectories of the VCS root (e.g. project/ or game/ in a
C++ GDExtension repository)."
  (let ((start (or dir default-directory)))
    (or (when-let* ((root (locate-dominating-file start "project.godot")))
          (expand-file-name root))
        (when-let* ((git-root (locate-dominating-file start ".git")))
          (cl-some (lambda (sub)
                     (let ((candidate (expand-file-name sub git-root)))
                       (when (file-exists-p (expand-file-name "project.godot" candidate))
                         (file-name-as-directory candidate))))
                   '("project" "game" "godot"))))))

(defun rata-godot-project-p ()
  "Return non-nil if current buffer is inside a Godot project."
  (not (null (rata-godot-project-root))))

(defun rata-godot-extension-root (&optional dir)
  "Return directory containing GDExtension files (SConstruct, CMakeLists.txt).
Starts searching from DIR or `default-directory'."
  (let ((start (or dir default-directory)))
    (or (locate-dominating-file start "SConstruct")
        (locate-dominating-file start "CMakeLists.txt")
        (locate-dominating-file start (lambda (d)
                                        (directory-files d nil "\\.gdextension\\'" t)))
        (rata-godot-project-root start))))

(defun rata-godot-gdextension-p ()
  "Return non-nil if current buffer is inside a GDExtension project."
  (and (rata-godot-project-p)
       (not (null (rata-godot-extension-root)))))

(defun rata-godot-default-build-command (root)
  "Determine the default GDExtension build command for ROOT directory."
  (cond
   ((file-exists-p (expand-file-name "SConstruct" root))
    "scons platform=linux compiledb=yes")
   ((file-exists-p (expand-file-name "CMakeLists.txt" root))
    "cmake --build build")
   ((file-exists-p (expand-file-name "justfile" root))
    "just build")
   (t "scons platform=linux compiledb=yes")))

(defun rata-godot-build-extension ()
  "Compile the C++ GDExtension library."
  (interactive)
  (if-let* ((root (rata-godot-extension-root)))
      (let* ((default-directory (expand-file-name root))
             (cmd (or rata-godot-build-command
                      (rata-godot-default-build-command default-directory))))
        (compile cmd))
    (user-error "No GDExtension build root (SConstruct/CMakeLists.txt) found")))

(defun rata-godot-open-editor ()
  "Open the Godot editor for the current project."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let* ((default-directory root)
             (exe (rata-godot-executable-path)))
        (start-process "godot-editor" nil exe "--editor" "--path" root)
        (message "Launched Godot editor for %s" root))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-run-project ()
  "Run the current Godot project."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let* ((default-directory root)
             (exe (rata-godot-executable-path)))
        (compile (format "%s --path %s"
                         (shell-quote-argument exe)
                         (shell-quote-argument root))))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-resolve-scene-file (&optional arg)
  "Resolve the target scene file to run, respecting prefix ARG."
  (if arg
      (read-file-name "Run scene: " (rata-godot-project-root) nil t nil
                      (lambda (f) (or (file-directory-p f)
                                      (string-suffix-p ".tscn" f))))
    (let ((file (buffer-file-name)))
      (cond
       ;; 1. Current buffer is a .tscn file
       ((and file (string-suffix-p ".tscn" file))
        file)
       ;; 2. Companion .tscn in the same directory (foo.cpp -> foo.tscn, foo.gd -> foo.tscn)
       ((and file
             (let ((companion (concat (file-name-sans-extension file) ".tscn")))
               (when (file-exists-p companion) companion))))
       ;; 3. Check for any .tscn in current buffer's directory
       ((and file
             (cl-find-if (lambda (f) (string-suffix-p ".tscn" f))
                         (directory-files (file-name-directory file) t "\\.tscn\\'"))))
       (t nil)))))

(defun rata-godot-run-scene (&optional arg)
  "Run the current scene (.tscn file) or fall back to running the project.
With prefix ARG (C-u), prompt to choose a scene file."
  (interactive "P")
  (if-let* ((root (rata-godot-project-root)))
      (let* ((default-directory root)
             (exe (rata-godot-executable-path))
             (scene (rata-godot-resolve-scene-file arg)))
        (if scene
            (compile (format "%s --path %s %s"
                             (shell-quote-argument exe)
                             (shell-quote-argument root)
                             (shell-quote-argument (expand-file-name scene root))))
          (rata-godot-run-project)))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-debug-cpp ()
  "Launch the Godot project under a native C++ debugger (GDB/LLDB) for GDExtension."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let ((exe (rata-godot-executable-path)))
        (require 'dap-mode nil t)
        (require 'dap-gdb-lldb nil t)
        (if (fboundp 'dap-debug)
            (dap-debug
             (list :type (if (executable-find "gdb") "gdb" "lldb-vscode")
                   :request "launch"
                   :name (format "Godot C++: %s" (file-name-nondirectory (directory-file-name root)))
                   :target exe
                   :cwd root
                   :args (list "--path" root)))
          (user-error "dap-mode is not loaded")))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-debug-gdscript ()
  "Start a GDScript DAP debugging session on port 6006."
  (interactive)
  (require 'dap-gdscript nil t)
  (if (fboundp 'dap-debug)
      (dap-debug (list :type "gdscript"
                       :cwd (rata-godot-project-root)
                       :request "launch"
                       :name "Godot GDScript"))
    (user-error "dap-mode is not available")))

(defun rata-godot-format-buffer ()
  "Format the current buffer using apheleia or gdscript-format."
  (interactive)
  (cond
   ((fboundp 'apheleia-format-buffer)
    (call-interactively #'apheleia-format-buffer))
   ((fboundp 'gdscript-format-buffer)
    (call-interactively #'gdscript-format-buffer))
   (t (message "No formatter available"))))

(defun rata-godot-browse-api ()
  "Open Godot API documentation."
  (interactive)
  (if (fboundp 'gdscript-docs-browse-api)
      (call-interactively #'gdscript-docs-browse-api)
    (browse-url "https://docs.godotengine.org/en/stable/")))

;; --- Scene, Resource, Manifest, and Shader file associations ---
(add-to-list 'auto-mode-alist '("\\.gdextension\\'" . conf-toml-mode))
(add-to-list 'auto-mode-alist '("\\.tscn\\'" . conf-toml-mode))
(add-to-list 'auto-mode-alist '("\\.tres\\'" . conf-toml-mode))
(add-to-list 'auto-mode-alist '("project\\.godot\\'" . conf-toml-mode))

(use-package glsl-mode
  :mode ("\\.gdshader\\'" "\\.shader\\'"))

;; --- GDScript (for scripts, tools, and glue) ---
(eval-when-compile
  (defvar gdscript-godot-executable))

(use-package gdscript-mode
  :mode ("\\.gd\\'" . gdscript-mode)
  :hook (gdscript-mode . lsp-deferred)
  :config
  (setq gdscript-godot-executable (rata-godot-executable-path)))

;; --- Keybindings ---
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "ag"   '(:ignore t :which-key "godot")
    "age"  '(rata-godot-open-editor      :which-key "open editor")
    "agr"  '(rata-godot-run-project      :which-key "run project")
    "ags"  '(rata-godot-run-scene        :which-key "run scene")
    "agb"  '(rata-godot-build-extension  :which-key "build extension")
    "agd"  '(rata-godot-debug-cpp        :which-key "debug C++")
    "agD"  '(rata-godot-debug-gdscript   :which-key "debug GDScript"))

  (rata-leader
    :states '(normal visual)
    :keymaps '(c++-ts-mode-map c-ts-mode-map)
    "mg"   '(:ignore t :which-key "godot")
    "mge"  '(rata-godot-open-editor      :which-key "open editor")
    "mgr"  '(rata-godot-run-project      :which-key "run project")
    "mgs"  '(rata-godot-run-scene        :which-key "run scene")
    "mgb"  '(rata-godot-build-extension  :which-key "build extension")
    "mgd"  '(rata-godot-debug-cpp        :which-key "debug C++")
    "mb"   '(rata-godot-build-extension  :which-key "build extension"))

  (rata-leader
    :states '(normal visual)
    :keymaps 'gdscript-mode-map
    "me"   '(rata-godot-open-editor      :which-key "open editor")
    "mr"   '(rata-godot-run-project      :which-key "run project")
    "ms"   '(rata-godot-run-scene        :which-key "run scene")
    "mb"   '(rata-godot-build-extension  :which-key "build extension")
    "md"   '(rata-godot-debug-gdscript   :which-key "debug GDScript")
    "mD"   '(rata-godot-debug-cpp        :which-key "debug C++")
    "mf"   '(rata-godot-format-buffer    :which-key "format buffer")
    "mh"   '(rata-godot-browse-api       :which-key "browse API docs")))

(provide 'init-gamedev)
