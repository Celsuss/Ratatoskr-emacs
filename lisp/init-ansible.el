;;; -*- lexical-binding: t; -*-
;;; init-ansible.el --- Ansible playbook editing

(use-package ansible
  :hook ((yaml-ts-mode . ansible)
         (yaml-mode    . ansible))
  :config
  (setq ansible-vault-password-file "~/.ansible-vault-pass"))

(use-package ansible-doc
  :after (ansible general)
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'ansible-key-map
    "ma"  '(:ignore t :which-key "ansible")
    "mad" '(ansible-doc :which-key "ansible doc")))

(provide 'init-ansible)
