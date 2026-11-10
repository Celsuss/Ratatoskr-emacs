;;; -*- lexical-binding: t; -*-
;;; init-beads.el --- Project-local Beads inspection entry point

;; The UI uses magit-section, already supplied by Magit.  Load it only when
;; requested; neither the CLI nor a Beads database is needed during startup.
(autoload 'rata-beads "rata-beads" nil t)

(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "gt" '(rata-beads :which-key "Beads tasks")))

(provide 'init-beads)
;;; init-beads.el ends here
