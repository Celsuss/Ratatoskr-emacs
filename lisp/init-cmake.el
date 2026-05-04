;;; -*- lexical-binding: t; -*-
;;; init-cmake.el --- CMake build system support

(defun rata-cmake-configure ()
  "Run cmake configure, generating build/ with Unix Makefiles.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (projectile-project-root)))
    (compile "cmake -S . -B build -G 'Unix Makefiles'")))

(defun rata-cmake-build ()
  "Build the cmake project in build/.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (projectile-project-root)))
    (compile "cmake --build build")))

(defun rata-cmake-clean ()
  "Clean the cmake build directory without reconfiguring.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (projectile-project-root)))
    (compile "cmake --build build --target clean")))

(defun rata-cmake-rebuild ()
  "Clean and rebuild the cmake project in one step.
Runs from the projectile project root."
  (interactive)
  (let ((default-directory (projectile-project-root)))
    (compile "cmake --build build --clean-first")))

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
    "mcr" '(rata-cmake-rebuild   :which-key "rebuild")))

(provide 'init-cmake)
