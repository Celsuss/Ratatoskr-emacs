;;; -*- lexical-binding: t; -*-
;;; init-docker.el --- Docker / Dockerfile support

(use-package dockerfile-mode
  :defer t)

;; --- Docker management ---
(use-package docker
  :after general
  :commands docker
  :config
  (rata-leader
    :states '(normal visual)
    "aD" '(docker :which-key "docker")))

(provide 'init-docker)
