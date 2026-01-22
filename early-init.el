;; ~/.config/emacs-from-scratch/early-init.el

;; Disable package.el initialization at startup (we will handle it manually in init.el)
(setq package-enable-at-startup nil)

;; clean up the UI before the frame appears
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)

;; Speed up startup by ignoring generic GC limits during init
(setq gc-cons-threshold most-positive-fixnum)
