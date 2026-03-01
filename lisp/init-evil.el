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

  (general-create-definer rata-local-leader
    :prefix ",")

  (general-simulate-key "C-c C-c" :name rata-send-c-c-c-c)

  (rata-local-leader
    :states '(normal visual)
    "," '(rata-send-c-c-c-c :which-key "C-c C-c"))

  ;; Custom functions for new keybindings
  (defun rata-kill-buffer-and-window ()
    "Kill the current buffer and delete its window."
    (interactive)
    (kill-current-buffer)
    (when (> (count-windows) 1)
      (delete-window)))

  (rata-leader
   :states '(normal visual)
   "SPC" '(execute-extended-command :which-key "execute command")
   "TAB" '(evil-switch-to-windows-last-buffer :which-key "last buffer")
   "/"   '(consult-ripgrep :which-key "project search")

   "f"   '(:ignore t :which-key "files")
   "ff"  '(find-file :which-key "find file")
   "fs"  '(save-buffer :which-key "save file")
   "fr"  '(consult-recent-file :which-key "recent file")
   "fL"  '(consult-locate :which-key "locate file")
   "fR"  '(rename-visited-file :which-key "rename file")
   "fD"  '((lambda () (interactive)
              (when (buffer-file-name)
                (delete-file (buffer-file-name))
                (kill-buffer)))
            :which-key "delete file")
   "fC"  '(copy-file :which-key "copy file")

   "b"   '(:ignore t :which-key "buffers")
   "bb"  '(consult-buffer :which-key "switch buffer")
   "bB"  '(consult-buffer-other-window :which-key "buffer other window")
   "bk"  '(kill-current-buffer :which-key "kill buffer")
   "bs"  '(scratch-buffer :which-key "scratch buffer")
   "bn"  '(next-buffer :which-key "next buffer")
   "bp"  '(previous-buffer :which-key "prev buffer")
   "bR"  '(revert-buffer :which-key "revert buffer")
   "br"  '(rename-buffer :which-key "rename buffer")

   "w"   '(:ignore t :which-key "window")
   "wl"  '(evil-window-right :which-key "window right")
   "wh"  '(evil-window-left :which-key "window left")
   "wk"  '(evil-window-up :which-key "window up")
   "wj"  '(evil-window-down :which-key "window down")
   "w/"  '(evil-window-vsplit :which-key "split vertical")
   "w-"  '(evil-window-split :which-key "split horizontal")
   "wd"  '(delete-window :which-key "delete window")
   "wx"  '(rata-kill-buffer-and-window :which-key "kill buffer & window")
   "wm"  '(delete-other-windows :which-key "maximize window")
   "w="  '(balance-windows :which-key "balance windows")
   "ww"  '(other-window :which-key "cycle window")
   "wr"  '(evil-window-rotate-downwards :which-key "rotate windows")
   "wu"  '(winner-undo :which-key "winner undo")

   "s"   '(:ignore t :which-key "search")
   "sg"  '(consult-grep :which-key "grep")
   "sr"  '(consult-ripgrep :which-key "ripgrep")
   "ss"  '(consult-line :which-key "search line")
   "sS"  '(consult-line-multi :which-key "search line multi")
   "sk"  '(consult-keep-lines :which-key "keep lines")
   "si"  '(consult-info :which-key "info")
   "sw"  '(wgrep-change-to-wgrep-mode :which-key "wgrep")

   "g"   '(:ignore t :which-key "git")

   "p"   '(:ignore t :which-key "project")
   "pp"  '(consult-project-buffer :which-key "project buffer")

   "h"   '(:ignore t :which-key "help")
   "hm"  '(consult-man :which-key "man page")
   "hI"  '(consult-info :which-key "info")
   "hb"  '(describe-bindings :which-key "describe bindings")
   "hw"  '(where-is :which-key "where is")
   "hf"  '(helpful-callable :which-key "describe function")
   "hv"  '(helpful-variable :which-key "describe variable")
   "hk"  '(helpful-key :which-key "describe key")
   "hH"  '(helpful-at-point :which-key "help at point")
   "ha"  '(apropos :which-key "apropos")

   "j"   '(:ignore t :which-key "jump")
   "jl"  '(consult-line :which-key "jump to line")
   "jj"  '(consult-imenu :which-key "imenu jump")
   "jJ"  '(consult-imenu-multi :which-key "imenu jump multi")
   "jo"  '(consult-outline :which-key "outline jump")

   "e"   '(:ignore t :which-key "errors")
   "en"  '(flycheck-next-error :which-key "next error")
   "ep"  '(flycheck-previous-error :which-key "prev error")
   "el"  '(consult-flycheck :which-key "list errors")
   "eL"  '(flycheck-error-list-mode :which-key "error list buffer")

   "r"   '(:ignore t :which-key "register")
   "rr"  '(consult-register :which-key "register")
   "rL"  '(consult-register-load :which-key "load register")
   "rS"  '(consult-register-store :which-key "store register")

   "y"   '(:ignore t :which-key "yank")
   "yy"  '(consult-yank-from-kill-ring :which-key "yank from kill-ring")

   "m"   '(:ignore t :which-key "mode")
   "mm"  '(consult-mode-command :which-key "mode command")

   "c"   '(:ignore t :which-key "compile")
   "cc"  '(compile :which-key "compile")
   "cr"  '(recompile :which-key "recompile")
   "ck"  '(kill-compilation :which-key "kill compilation")

   "x"   '(:ignore t :which-key "text")
   "xa"  '(align-regexp :which-key "align regexp")
   "xs"  '(sort-lines :which-key "sort lines")
   "xc"  '(count-words-region :which-key "count words")
   "xj"  '(join-line :which-key "join line")
   "xu"  '(upcase-region :which-key "upcase region")
   "xU"  '(downcase-region :which-key "downcase region")
   "xd"  '(duplicate-line :which-key "duplicate line")

   "t"   '(:ignore t :which-key "toggle")
   "tn"  '(display-line-numbers-mode :which-key "line numbers")
   "tr"  '((lambda () (interactive)
              (if (eq display-line-numbers 'relative)
                  (setq display-line-numbers t)
                (setq display-line-numbers 'relative)))
            :which-key "relative numbers")
   "tl"  '(toggle-truncate-lines :which-key "truncate lines")
   "tg"  '(golden-ratio-mode :which-key "golden ratio")

   "n"   '(:ignore t :which-key "narrow")
   "nb"  '(narrow-to-region :which-key "region")
   "nf"  '(narrow-to-defun :which-key "function")
   "np"  '(narrow-to-page :which-key "page")
   "nw"  '(widen :which-key "widen")

   "q"   '(:ignore t :which-key "quit")
   "qq"  '(save-buffers-kill-terminal :which-key "quit emacs")
   "qQ"  '(kill-emacs :which-key "quit without saving")
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
   :states '(normal visual)
   "0" '(winum-select-window-0-or-10 :which-key "window 0..9")
   "1" '(winum-select-window-1 :which-key "window 1")
   "2" '(winum-select-window-2 :which-key "window 2")
   "3" '(winum-select-window-3 :which-key "window 3")
   "4" '(winum-select-window-4 :which-key "window 4")
   "5" '(winum-select-window-5 :which-key "window 5")
   "6" '(winum-select-window-6 :which-key "window 6")
   "7" '(winum-select-window-7 :which-key "window 7")
   "8" '(winum-select-window-8 :which-key "window 8")
   "9" '(winum-select-window-9 :which-key "window 9"))
  ;; Hide winum 1-9 from which-key (key 0 shows "window 0..9")
  ;; Must be pushed AFTER rata-leader so it lands in front of general.el's rules
  (push '((nil . "winum-select-window-[1-9]") . t)
        which-key-replacement-alist)
  ;; Rename key "0" to "0..9" in which-key display
  (push '(("0" . "winum-select-window-0-or-10") . ("0..9" . "window 0..9"))
        which-key-replacement-alist))

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
