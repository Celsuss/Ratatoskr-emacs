;;; -*- lexical-binding: t; -*-
;;; init-yaml.el --- YAML structural editing

(use-package yaml-pro
  :after yaml-ts-mode
  :hook (yaml-ts-mode . yaml-pro-ts-mode))

(provide 'init-yaml)
