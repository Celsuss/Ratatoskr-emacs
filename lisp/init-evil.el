;; ~/.config/emacs-from-scratch/lisp/init-evil.el

;; --- 1. Pre-load Configuration ---
;; These variables MUST be set before 'evil' is loaded.

;; This is required for 'evil-collection' to work correctly.
(setq evil-want-keybinding nil)

;; Allow C-u to scroll up (like Vim) instead of triggering the universal argument
(setq evil-want-C-u-scroll t)

;; --- 2. Load Evil ---
(use-package evil
  :ensure t
  :init
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  :config
  (message "Setting up EVIL")
  (evil-mode 1))


;; --- 3. Load Evil Collection ---
;; This gives you Vim bindings in Dired, Package Manager, etc.
(use-package evil-collection
  :after evil
  :ensure t
  :config
  (evil-collection-init))

;; --- 4. Leader Key Setup (General.el) ---
;; 'general' is the modern, declarative way to handle keybindings.
;;
;; How to add keybindings in other files
;; (rata-leader
;;  :states '(normal visual insert emacs)
;;  "t"  '(:ignore t :which-key "tools")
;;  "tc" '(calc :which-key "calculator")
;;  "td" '(dired :which-key "dired"))
(use-package general
  :config
  ;; Setup the leader key as Space, just like Spacemacs
  (general-create-definer rata-leader
                          :prefix "SPC")

  ;; Bind some basic keys
  (rata-leader
   :states '(normal visual insert emacs)
   "SPC" '(execute-extended-command :which-key "execute command")

   "f"   '(:ignore t :which-key "files")                ; Group name
   "ff"  '(consult-find :which-key "find file")
   "fs"  '(save-buffer :which-key "save file")

   "b"   '(:ignore t :which-key "buffers")              ; Group name
   "bb"  '(consult-buffer :which-key "switch buffer")
   "bk"  '(kill-current-buffer :which-key "kill buffer")

   ;; Window management
   "w"   '(:ignore t :which-key "window")               ; Group name
   "wl"  '(evil-window-right :which-key "window right")
   "wh"  '(evil-window-left :which-key "window left")
   "wk"  '(evil-window-up :which-key "window up")
   "wj"  '(evil-window-down :which-key "window down")
   ;; TODO Add window management using numbers
   ;; "0..9" '(evil-window-down :which-key "Go to window")

   ;; Enhanced file operations
   "fr"  '(consult-recent-file :which-key "recent file")
   "fL"  '(consult-locate :which-key "locate file")

   ;; Enhanced buffer operations
   "bB"  '(consult-buffer-other-window :which-key "buffer other window")

   ;; Search group
   "s"   '(:ignore t :which-key "search")
   "sg"  '(consult-grep :which-key "grep")
   "sr"  '(consult-ripgrep :which-key "ripgrep")
   "ss"  '(consult-line :which-key "search line")
   "sS"  '(consult-line-multi :which-key "search line multi")
   "sk"  '(consult-keep-lines :which-key "keep lines")
   "si"  '(consult-info :which-key "info")

   ;; Git operations
   "g"   '(:ignore t :which-key "git")
   "gg"  '(consult-git-grep :which-key "git grep")

   ;; Project operations
   "p"   '(:ignore t :which-key "project")
   "pp"  '(consult-project-buffer :which-key "project buffer")
   "pf"  '(consult-project-find :which-key "project find")

   ;; Help and documentation
   "h"   '(:ignore t :which-key "help")
   "hm"  '(consult-man :which-key "man page")
   "hI"  '(consult-info :which-key "info")

   ;; Jump and navigation
   "j"   '(:ignore t :which-key "jump")
   "jl"  '(consult-line :which-key "jump to line")
   "jj"  '(consult-imenu :which-key "imenu jump")
   "jJ"  '(consult-imenu-multi :which-key "imenu jump multi")
   "jo"  '(consult-outline :which-key "outline jump")

   ;; Error navigation
   "e"   '(:ignore t :which-key "errors")
   "el"  '(consult-flymake :which-key "list errors")

   ;; Register and marks
   "r"   '(:ignore t :which-key "register")
   "rr"  '(consult-register :which-key "register")
   "rL"  '(consult-register-load :which-key "load register")
   "rS"  '(consult-register-store :which-key "store register")

   ;; Yank and kill ring
   "y"   '(:ignore t :which-key "yank")
   "yy"  '(consult-yank-from-kill-ring :which-key "yank from kill-ring")

   ;; Mode-specific
   "m"   '(:ignore t :which-key "mode")
   "mm"  '(consult-mode-command :which-key "mode command")

   ;; A binding to restart emacs easily while you are tweaking config
   "qr"  '((lambda () (interactive) (load-file user-init-file)) :which-key "reload init.el")))

(use-package winum
  :ensure t
  :config
  (winum-mode)
  :init
  (rata-leader
   :states '(normal visual insert emacs)
   ;; 0 is usually reserved for the sidebar (like treemacs)
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

(provide 'init-evil)
