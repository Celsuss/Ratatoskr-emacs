;;; -*- lexical-binding: t; -*-
;;; init-docker.el --- Docker / Dockerfile support

(use-package dockerfile-mode
  :defer t)

;; --- Docker management ---
(use-package docker
  :after general
  :commands docker)

;; Global leader key at top level so it is live from startup, not only after
;; `docker' loads (see FAIL-0009 / L-011). `docker' is autoloaded via :commands.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "aD" '(docker :which-key "docker")))

(provide 'init-docker)
