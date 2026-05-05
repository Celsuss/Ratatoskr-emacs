;;; -*- lexical-binding: t; -*-
;;; init-helm.el --- Helm chart templating (YAML + Go templates via polymode)

(use-package polymode
  :after yaml-ts-mode
  :config
  (define-hostmode poly-yaml-hostmode
    :mode 'yaml-ts-mode)

  (define-innermode poly-go-template-innermode
    :mode 'go-ts-mode
    :head-matcher "{{[-]?"
    :tail-matcher "[-]?}}"
    :head-mode 'host
    :tail-mode 'host)

  (define-polymode poly-yaml-go-template-mode
    :hostmode 'poly-yaml-hostmode
    :innermodes '(poly-go-template-innermode)))

;; Auto-activate on Helm template files
(add-to-list 'auto-mode-alist
             '("/templates/.*\\.ya?ml\\'" . poly-yaml-go-template-mode))
(add-to-list 'auto-mode-alist
             '("\\.tpl\\'" . poly-yaml-go-template-mode))

(provide 'init-helm)
