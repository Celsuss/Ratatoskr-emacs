;; ~/.config/emacs-from-scratch/lisp/init-pkg.el

(require 'package)

;; Add MELPA to your package archives (standard for most plugins)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)

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
