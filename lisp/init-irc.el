;;; -*- lexical-binding: t; -*-
;;; init-irc.el --- IRC client (Circe)

;; --- Helper functions ---

(defun rata-irc-quakenet-auth ()
  "Authenticate with QuakeNet's Q bot after connecting."
  (when (string= circe-server-name "QuakeNet")
    (let ((pass (rata-auth-get "quakenet" "Celsuss")))
      (when pass
        (circe-command-PRIVMSG "Q@CServe.quakenet.org"
                               (format "AUTH Celsuss %s" pass))))))

(defun rata-irc-next-activity ()
  "Jump to the next IRC buffer with activity."
  (interactive)
  (tracking-next-buffer))

(defun rata-irc-list-channels ()
  "Switch to an IRC channel buffer."
  (interactive)
  (let ((buffers (cl-remove-if-not
                  (lambda (buf)
                    (with-current-buffer buf
                      (derived-mode-p 'circe-channel-mode)))
                  (buffer-list))))
    (if buffers
        (switch-to-buffer
         (completing-read "IRC channel: "
                          (mapcar #'buffer-name buffers)))
      (message "No IRC channel buffers open"))))

(defun rata-irc-switch-server ()
  "Switch to an IRC server buffer."
  (interactive)
  (let ((buffers (cl-remove-if-not
                  (lambda (buf)
                    (with-current-buffer buf
                      (derived-mode-p 'circe-server-mode)))
                  (buffer-list))))
    (if buffers
        (switch-to-buffer
         (completing-read "IRC server: "
                          (mapcar #'buffer-name buffers)))
      (message "No IRC server buffers open"))))

(defun rata-irc-connect-all ()
  "Connect to all primary IRC networks silently."
  (interactive)
  (circe "Libera Chat")
  (circe "QuakeNet"))

(defun rata-irc-quit ()
  "Quit all IRC connections."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'circe-server-mode)
        (circe-command-QUIT "Leaving")))))

;; --- Circe ---
(use-package circe
  :after general
  ;; :commands circe
  :commands (circe rata-irc-connect-all)
  :custom
  (circe-network-options
   `(("Libera Chat"
      :host "irc.libera.chat"
      :port 6697
      :tls t
      :nick "celsuss"
      :user "celsuss"
      :sasl-username "celsuss"
      :sasl-password ,(lambda (_) (rata-auth-get "irc.libera.chat" "celsuss"))
      :channels (,(mapconcat #'identity
                             '("#emacs" "#spacemacs" "##llamas" "#linux" "#Linuxkompis"
                               "#archlinux" "#archlinux-offtopic" "#archlinux-devops"
                               "#archlinux-projects" "#archlinux-releng" "#archlinux-pacman"
                               "#archlinux-nordics" "#archlinux-testing")
                             ",")))
     ;; :channels ("#emacs" "#archlinux" "#systemcrafters"))
     ("QuakeNet"
      :host "stockholm.se.quakenet.org"
      :port 6667
      :nick "Celsuss"
      :user "Celsuss"
      :channels (,(mapconcat #'identity
                             '("#sweclockers" "#stockholm")
                             ",")))))

  (circe-reduce-lurker-spam t)
  :config
  (require 'lui-track-bar)
  (enable-circe-color-nicks)
  (enable-lui-track-bar)
  (add-hook 'circe-server-connected-hook #'rata-irc-quakenet-auth)
  :init
  (rata-leader
    :states '(normal visual)
    "ac"  '(:ignore t :which-key "chat")
    "acc" '(rata-irc-connect-all :which-key "connect IRC")
    ;; "acc" '(circe :which-key "connect IRC")
    "acc" '(rata-irc-connect-all :which-key "connect IRC")
    "acl" '(rata-irc-list-channels :which-key "list channels")
    "acn" '(rata-irc-next-activity :which-key "next activity")
    "acq" '(rata-irc-quit :which-key "quit IRC")
    "acs" '(rata-irc-switch-server :which-key "switch server")))

(provide 'init-irc)
