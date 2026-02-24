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
    "l"   '(:ignore t :which-key "layouts")
    "ll"  '(persp-switch :which-key "switch layout")
    "ln"  '(persp-add-new :which-key "new layout")
    "lk"  '(persp-kill :which-key "kill layout")
    "lr"  '(persp-rename :which-key "rename layout")
    "la"  '(persp-add-buffer :which-key "add buffer")
    "lb"  '(persp-switch-to-buffer :which-key "switch to buffer")
    "ls"  '(persp-save-state-to-file :which-key "save layouts")
    "lL"  '(persp-load-state-from-file :which-key "load layouts")))

(provide 'init-persp)
