;;; -*- lexical-binding: t; -*-
;;; init-persp.el --- Workspace management with persp-mode

(use-package persp-mode
  :after general
  :demand t
  :custom
  (persp-auto-resume-time -1)
  :config
  (persp-mode 1)
  (rata-leader
    :states '(normal visual insert emacs)
    "L"   '(:ignore t :which-key "layouts")
    "Ll"  '(persp-switch :which-key "switch layout")
    "Ln"  '(persp-add-new :which-key "new layout")
    "Lk"  '(persp-kill :which-key "kill layout")
    "Lr"  '(persp-rename :which-key "rename layout")
    "La"  '(persp-add-buffer :which-key "add buffer")
    "Lb"  '(persp-switch-to-buffer :which-key "switch to buffer")
    "Ls"  '(persp-save-state-to-file :which-key "save layouts")
    "LL"  '(persp-load-state-from-file :which-key "load layouts")))

(provide 'init-persp)
