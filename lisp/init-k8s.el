;;; -*- lexical-binding: t; -*-
;;; init-k8s.el --- Kubernetes tooling (kubel)

;; --- Kubel (interactive kubectl interface) ---
(use-package kubel
  :after general
  :commands kubel
  :config
  (rata-leader
    :states '(normal visual)
    "ak"  '(:ignore t :which-key "kubernetes")
    "akk" '(kubel :which-key "kubel")
    "akn" '(kubel-set-namespace :which-key "set namespace")
    "akc" '(kubel-set-context :which-key "set context")
    "akp" '(kubel-port-forward-pod :which-key "port forward")
    "akl" '(kubel-get-pod-logs :which-key "pod logs")))

;; --- Kubel-evil (evil bindings in kubel buffer) ---
(use-package kubel-evil
  :after kubel)

(provide 'init-k8s)
