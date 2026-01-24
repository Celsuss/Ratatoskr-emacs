;; ~/.config/emacs-from-scratch/lisp/init-pkg.el

(require 'package)

;; Define package repos
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")  ;; The "Core" repo. Official packages signed by the FSF.
        ("nongnu" . "https://elpa.nongnu.org/nongnu/") ;; The "Extra" repo. Curated, stable packages
        ("melpa"  . "https://melpa.org/packages/")))   ;; The "AUR". Massive selection, community-maintained, built automatically from Git.

;; Priorities repos, higher number higher prio.
(setq package-archive-priorities
      '(("gnu"    . 5)
        ("nongnu" . 5)
        ("melpa"  . 10)))

(package-initialize)

;; Ensure 'use-package' is available
(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))

(eval-when-compile
  (require 'use-package))

;; "ensure t" makes use-package automatically download packages if missing.
;; This makes your config declarative and portable.
(setq use-package-always-ensure t)

(provide 'init-pkg)
