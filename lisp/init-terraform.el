;;; -*- lexical-binding: t; -*-
;;; init-terraform.el --- Terraform infrastructure-as-code support

(defun rata-terraform-plan ()
  "Run `terraform plan` in the directory of the current file.
Shows the execution plan without applying changes."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "terraform plan")))

(defun rata-terraform-apply ()
  "Run `terraform apply` in the directory of the current file.
Applies the execution plan to the infrastructure."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "terraform apply")))

(defun rata-terraform-init ()
  "Run `terraform init` in the directory of the current file.
Initializes the working directory with providers and modules."
  (interactive)
  (let ((default-directory (file-name-directory (buffer-file-name))))
    (compile "terraform init")))

(use-package terraform-mode
  :defer t
  :after general
  :config
  (rata-leader
    :states '(normal visual)
    :keymaps 'terraform-mode-map
    "mT"  '(:ignore t :which-key "terraform")
    "mTp" '(rata-terraform-plan  :which-key "terraform plan")
    "mTa" '(rata-terraform-apply :which-key "terraform apply")
    "mTi" '(rata-terraform-init  :which-key "terraform init")))

(provide 'init-terraform)
