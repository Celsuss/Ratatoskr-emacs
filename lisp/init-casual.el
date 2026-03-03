;;; -*- lexical-binding: t; -*-
;;; init-casual.el --- Casual transient menus for utility modes

(use-package casual
  :ensure t
  :defer t
  :after (evil general)
  :config
  ;; --- Dired ---
  (evil-define-key 'normal dired-mode-map (kbd "C-o") #'casual-dired-tmenu)
  (rata-leader
    :states '(normal)
    :keymaps 'dired-mode-map
    "." '(casual-dired-tmenu :which-key "casual menu"))

  ;; --- IBuffer ---
  (evil-define-key 'normal ibuffer-mode-map (kbd "C-o") #'casual-ibuffer-tmenu)
  (evil-define-key 'normal ibuffer-mode-map (kbd "F") #'casual-ibuffer-filter-tmenu)
  (evil-define-key 'normal ibuffer-mode-map (kbd "s") #'casual-ibuffer-sortby-tmenu)

  ;; --- Calc ---
  (evil-define-key 'normal calc-mode-map (kbd "C-o") #'casual-calc-tmenu)

  ;; --- Info ---
  (evil-define-key 'normal Info-mode-map (kbd "C-o") #'casual-info-tmenu)

  ;; --- Isearch ---
  (define-key isearch-mode-map (kbd "C-o") #'casual-isearch-tmenu)

  ;; --- Re-Builder ---
  (evil-define-key 'normal reb-mode-map (kbd "C-o") #'casual-re-builder-tmenu)

  ;; --- Bookmarks ---
  (evil-define-key 'normal bookmark-bmenu-mode-map (kbd "C-o") #'casual-bookmarks-tmenu)
  (rata-leader
    :states '(normal visual)
    "ab" '(bookmark-bmenu-list :which-key "bookmarks")))

(provide 'init-casual)
