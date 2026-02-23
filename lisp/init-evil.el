;;; -*- lexical-binding: t; -*-
;;; init-evil.el --- Evil mode and leader keybindings

;; These variables MUST be set before evil is loaded
(setq evil-want-keybinding nil)
(setq evil-want-C-u-scroll t)

;; --- Evil ---
(use-package evil
  :demand t
  :init
  (setq evil-want-integration t
        evil-want-keybinding nil)
  :config
  (evil-mode 1))

;; --- Evil Collection ---
(use-package evil-collection
  :after evil
  :demand t
  :config
  (evil-collection-init))

;; --- General (leader key) ---
(use-package general
  :demand t
  :config
  (general-create-definer rata-leader
    :prefix "SPC")

  (rata-leader
   :states '(normal visual insert emacs)
   "SPC" '(execute-extended-command :which-key "execute command")

   "f"   '(:ignore t :which-key "files")
   "ff"  '(consult-find :which-key "find file")
   "fs"  '(save-buffer :which-key "save file")
   "fr"  '(consult-recent-file :which-key "recent file")
   "fL"  '(consult-locate :which-key "locate file")

   "b"   '(:ignore t :which-key "buffers")
   "bb"  '(consult-buffer :which-key "switch buffer")
   "bB"  '(consult-buffer-other-window :which-key "buffer other window")
   "bk"  '(kill-current-buffer :which-key "kill buffer")

   "w"   '(:ignore t :which-key "window")
   "wl"  '(evil-window-right :which-key "window right")
   "wh"  '(evil-window-left :which-key "window left")
   "wk"  '(evil-window-up :which-key "window up")
   "wj"  '(evil-window-down :which-key "window down")

   "s"   '(:ignore t :which-key "search")
   "sg"  '(consult-grep :which-key "grep")
   "sr"  '(consult-ripgrep :which-key "ripgrep")
   "ss"  '(consult-line :which-key "search line")
   "sS"  '(consult-line-multi :which-key "search line multi")
   "sk"  '(consult-keep-lines :which-key "keep lines")
   "si"  '(consult-info :which-key "info")

   "g"   '(:ignore t :which-key "git")
   "gg"  '(consult-git-grep :which-key "git grep")

   "p"   '(:ignore t :which-key "project")
   "pp"  '(consult-project-buffer :which-key "project buffer")

   "h"   '(:ignore t :which-key "help")
   "hm"  '(consult-man :which-key "man page")
   "hI"  '(consult-info :which-key "info")

   "j"   '(:ignore t :which-key "jump")
   "jl"  '(consult-line :which-key "jump to line")
   "jj"  '(consult-imenu :which-key "imenu jump")
   "jJ"  '(consult-imenu-multi :which-key "imenu jump multi")
   "jo"  '(consult-outline :which-key "outline jump")

   "e"   '(:ignore t :which-key "errors")
   "el"  '(consult-flymake :which-key "list errors")

   "r"   '(:ignore t :which-key "register")
   "rr"  '(consult-register :which-key "register")
   "rL"  '(consult-register-load :which-key "load register")
   "rS"  '(consult-register-store :which-key "store register")

   "y"   '(:ignore t :which-key "yank")
   "yy"  '(consult-yank-from-kill-ring :which-key "yank from kill-ring")

   "m"   '(:ignore t :which-key "mode")
   "mm"  '(consult-mode-command :which-key "mode command")

   "q"   '(:ignore t :which-key "quit")
   "qr"  '((lambda () (interactive) (load-file user-init-file)) :which-key "reload init.el")))

;; Synchronize elpaca queue — general + evil must be ready before
;; any downstream module calls rata-leader
(elpaca-wait)

;; --- Winum (window numbers) ---
(use-package winum
  :after general
  :config
  (winum-mode)
  (rata-leader
   :states '(normal visual insert emacs)
   "0" '(winum-select-window-0-or-10 :which-key "window 0")
   "1" '(winum-select-window-1 :which-key "window 1")
   "2" '(winum-select-window-2 :which-key "window 2")
   "3" '(winum-select-window-3 :which-key "window 3")
   "4" '(winum-select-window-4 :which-key "window 4")
   "5" '(winum-select-window-5 :which-key "window 5")
   "6" '(winum-select-window-6 :which-key "window 6")
   "7" '(winum-select-window-7 :which-key "window 7")
   "8" '(winum-select-window-8 :which-key "window 8")
   "9" '(winum-select-window-9 :which-key "window 9")))

;; --- Undo-fu (better undo for evil) ---
(use-package undo-fu
  :after evil
  :config
  (setq evil-undo-system 'undo-fu))

;; --- Evil-surround (cs, ys, ds) ---
(use-package evil-surround
  :after evil
  :config
  (global-evil-surround-mode 1))

;; --- Evil-nerd-commenter (comment toggle) ---
(use-package evil-nerd-commenter
  :after (evil general)
  :config
  (rata-leader
    :states '(normal visual)
    ";" '(evilnc-comment-or-uncomment-lines :which-key "comment")))

;; --- Avy (jump to visible text) ---
(use-package avy
  :after general
  :config
  (rata-leader
    :states '(normal visual)
    "jc" '(avy-goto-char-2 :which-key "jump to char")
    "jw" '(avy-goto-word-0 :which-key "jump to word")
    "jn" '(avy-goto-line   :which-key "jump to line")))

;; --- Evil-matchit (% to jump matching tags/parens) ---
(use-package evil-matchit
  :after evil
  :config
  (global-evil-matchit-mode 1))

;; --- Evil-args (inner/outer argument text objects) ---
(use-package evil-args
  :after evil
  :config
  (define-key evil-inner-text-objects-map "a" 'evil-inner-arg)
  (define-key evil-outer-text-objects-map "a" 'evil-outer-arg))

;; --- Evil-textobj-tree-sitter (language-aware text objects) ---
(use-package evil-textobj-tree-sitter
  :after evil
  :config
  (define-key evil-outer-text-objects-map "f"
    (cons "outer function" (evil-textobj-tree-sitter-get-textobj "function.outer")))
  (define-key evil-inner-text-objects-map "f"
    (cons "inner function" (evil-textobj-tree-sitter-get-textobj "function.inner")))
  (define-key evil-outer-text-objects-map "c"
    (cons "outer class" (evil-textobj-tree-sitter-get-textobj "class.outer")))
  (define-key evil-inner-text-objects-map "c"
    (cons "inner class" (evil-textobj-tree-sitter-get-textobj "class.inner"))))

;; --- Evil-mc (multiple cursors) ---
(use-package evil-mc
  :after evil
  :config
  (global-evil-mc-mode 1))

;; --- Smartparens ---
(use-package smartparens
  :after evil
  :config
  (require 'smartparens-config)
  (smartparens-global-mode 1)
  (show-smartparens-global-mode 1)
  (electric-pair-mode -1))

(provide 'init-evil)
