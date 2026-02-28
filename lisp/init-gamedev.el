;;; -*- lexical-binding: t; -*-
;;; init-gamedev.el --- Game development (Godot 4.x / GDExtension)

(defcustom rata-godot-executable "godot"
  "Path to the Godot editor executable."
  :type 'string
  :group 'rata)

(defun rata-godot-project-root ()
  "Return the directory containing project.godot, or nil."
  (when-let* ((root (locate-dominating-file default-directory "project.godot")))
    (expand-file-name root)))

(defun rata-godot-project-p ()
  "Return non-nil if current buffer is inside a Godot project."
  (rata-godot-project-root))

(defun rata-godot-open-editor ()
  "Open the Godot editor for the current project."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let ((default-directory root))
        (start-process "godot-editor" nil rata-godot-executable
                       "--editor" "--path" root))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-run-project ()
  "Run the current Godot project."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let ((default-directory root))
        (compile (format "%s --path %s" rata-godot-executable
                         (shell-quote-argument root))))
    (user-error "No project.godot found in parent directories")))

(defun rata-godot-run-scene ()
  "Run the current scene (.tscn file) or fall back to running the project."
  (interactive)
  (if-let* ((root (rata-godot-project-root)))
      (let* ((default-directory root)
             (scene (when (buffer-file-name)
                      (cl-find-if (lambda (f) (string-suffix-p ".tscn" f))
                                  (directory-files (file-name-directory
                                                    (buffer-file-name))
                                                   t "\\.tscn\\'")))))
        (if scene
            (compile (format "%s --path %s %s"
                             rata-godot-executable
                             (shell-quote-argument root)
                             (shell-quote-argument scene)))
          (rata-godot-run-project)))
    (user-error "No project.godot found in parent directories")))

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "ag"  '(:ignore t :which-key "godot")
    "age" '(rata-godot-open-editor :which-key "open editor")
    "agr" '(rata-godot-run-project :which-key "run project")
    "ags" '(rata-godot-run-scene   :which-key "run scene")))

(provide 'init-gamedev)
