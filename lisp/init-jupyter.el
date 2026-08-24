;;; -*- lexical-binding: t; -*-
;;; init-jupyter.el --- Jupyter notebook client (EIN)

(use-package ein
  :after general
  :commands (ein:run ein:login ein:notebooklist-open))

;; Global leader keys at top level so they are live from startup (FAIL-0009).
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aj"  '(:ignore t :which-key "jupyter")
    "ajr" '(ein:run                  :which-key "start jupyter")
    "ajl" '(ein:login                :which-key "login to jupyter")
    "ajn" '(ein:notebooklist-open    :which-key "notebook list")))

(provide 'init-jupyter)
