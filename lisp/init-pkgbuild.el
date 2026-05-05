;;; -*- lexical-binding: t; -*-
;;; init-pkgbuild.el --- Arch Linux PKGBUILD support

(defun rata-makepkg-build ()
  "Build the current PKGBUILD package using makepkg -sf.
Skips checksums (-s) and forces rebuilding (-f)."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "makepkg -sf")))

(defun rata-makepkg-srcinfo ()
  "Generate .SRCINFO from the current PKGBUILD.
Required for AUR submissions."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "makepkg --printsrcinfo > .SRCINFO")))

(defun rata-namcap-check ()
  "Run namcap linter on the current PKGBUILD file.
Reports packaging errors and policy violations."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile (format "namcap %s" (buffer-file-name)))))

(defun rata-updpkgsums ()
  "Update checksums in the current PKGBUILD using updpkgsums.
Downloads sources and recalculates sha256sums."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "updpkgsums")))

(use-package pkgbuild-mode
  :mode "/PKGBUILD$"
  :after general
  :config
  (setq pkgbuild-update-sums-on-save nil)
  (rata-leader
    :states '(normal visual)
    :keymaps 'pkgbuild-mode-map
    "mp"  '(:ignore t :which-key "pkgbuild")
    "mpb" '(rata-makepkg-build    :which-key "makepkg build")
    "mps" '(rata-makepkg-srcinfo  :which-key "gen .SRCINFO")
    "mpn" '(rata-namcap-check     :which-key "namcap lint")
    "mpu" '(rata-updpkgsums       :which-key "update sums")))

(provide 'init-pkgbuild)
