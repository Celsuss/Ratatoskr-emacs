;;; -*- lexical-binding: t; -*-
;;; FAIL-0009-probe.el --- measure which global leader keys are live after init
;;
;; Run:  emacs --init-directory . --batch -l .are/memory/failures/FAIL-0009-probe.el
;; Not part of any gate: it reports a count, it does not assert one.

(load (expand-file-name "early-init.el" user-emacs-directory) nil t)
(load (expand-file-name "init.el" user-emacs-directory) nil t)

(defun dk--forms (file)
  "Return every rata-leader form in FILE."
  (let (out)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while t (push (read (current-buffer)) out))
        (error nil)))
    (let (found)
      (cl-labels ((walk (f)
                    (when (consp f)
                      (if (eq (car f) 'rata-leader)
                          (push (cdr f) found)
                        (let ((s f))
                          (while (consp s)
                            (when (consp (car s)) (walk (car s)))
                            (setq s (cdr s))))))))
        (mapc #'walk out))
      found)))

(defun dk--keys (body)
  "String keys in a rata-leader BODY, nil if the form is keymap-scoped."
  (unless (memq :keymaps body)
    (let (keys (items body) skip)
      (while items
        (let ((it (car items)))
          (cond (skip (setq skip nil))
                ((keywordp it) (setq skip t))
                ((stringp it)
                 (let ((v (cadr items)))
                   (unless (and (consp v) (eq (car v) 'quote)
                                (eq (car-safe (cadr v)) :ignore))
                     (push it keys))
                   (setq items (cdr items))))))
        (setq items (cdr items)))
      keys)))

(defun dk--spaced (keys)
  "Space out KEYS, keeping multi-character key names like SPC and TAB intact.
Splitting \"SPC\" into \"S P C\" made the first run of this probe report two
false positives."
  (let (out (i 0) (n (length keys)))
    (while (< i n)
      (let ((m (string-match "\\`\\(SPC\\|TAB\\|RET\\|ESC\\|DEL\\)" (substring keys i))))
        (if (eq m 0)
            (let ((tok (match-string 1 (substring keys i))))
              (push tok out)
              (setq i (+ i (length tok))))
          (push (string (aref keys i)) out)
          (setq i (1+ i)))))
    (mapconcat #'identity (nreverse out) " ")))

(let ((aux (evil-get-auxiliary-keymap general-override-mode-map 'normal))
      (dead 0) (live 0) report)
  (dolist (file (directory-files (expand-file-name "lisp" user-emacs-directory)
                                 t "^init-.*\\.el$"))
    (unless (equal (file-name-nondirectory file) "init-mcp.el")
      (dolist (body (dk--forms file))
        (dolist (k (dk--keys body))
          (let ((res (lookup-key aux (kbd (concat "SPC " (dk--spaced k))))))
            (if (and res (not (numberp res)))
                (setq live (1+ live))
              (setq dead (1+ dead))
              (push (format "  %-22s SPC %s" (file-name-nondirectory file) k) report)))))))
  (princ (format "\n===== GLOBAL LEADER KEY LIVENESS =====\nlive=%d dead=%d\n" live dead))
  (princ (mapconcat #'identity (sort report #'string<) "\n"))
  (princ "\n===== END =====\n"))
