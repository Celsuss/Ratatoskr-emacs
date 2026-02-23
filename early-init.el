;;; -*- lexical-binding: t; -*-
;;; early-init.el --- Pre-initialization

;; Disable package.el — elpaca replaces it entirely
(setq package-enable-at-startup nil)

;; Clean up the UI before the frame appears
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)

;; Speed up startup by deferring GC during init
(setq gc-cons-threshold most-positive-fixnum)

;; Silence native-comp warnings during async compilation
(setq native-comp-async-report-warnings-errors 'silent)

;; Local Variables:
;; no-byte-compile: t
;; no-native-compile: t
;; no-update-autoloads: t
;; End:
