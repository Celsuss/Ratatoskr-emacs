;;; -*- lexical-binding: t; -*-
;;; init-mail.el --- Email: mu4e over Proton Mail Bridge, mbsync in, smtpmail out
;;
;; The shape is the NeoMutt one, moved into Emacs:
;;
;;   Proton  <-->  Proton Mail Bridge (IMAP 1143 / SMTP 1025 on localhost)
;;                    |  mbsync (isync)           ^  smtpmail (built in)
;;                    v                           |
;;                 ~/Mail (Maildir)  --mu index-->  mu4e
;;
;; Proton is end-to-end encrypted, so nothing speaks IMAP to Proton directly:
;; Bridge decrypts locally and exposes plain IMAP/SMTP on 127.0.0.1 behind a
;; self-signed certificate.  Bridge needs a paid plan and a Secret Service
;; keychain (gnome-keyring) -- see .are/knowledge/INTEGRATIONS.md.
;;
;; Four things are per-machine and deliberately NOT in this file:
;;
;;   1. `rata-mail-address' -- set in local.el (local.el.example is the checklist).
;;   2. The Bridge password -- two lines in ~/.authinfo.gpg, one per port:
;;        machine 127.0.0.1 port 1143 login you@proton.me password <bridge-password>
;;        machine 127.0.0.1 port 1025 login you@proton.me password <bridge-password>
;;      smtpmail reads the 1025 line through auth-source; mbsync reads the 1143
;;      line through its PassCmd.  One secret, one place.
;;   3. ~/.mbsyncrc -- copy mbsyncrc.example at the repo root and fill in the address.
;;   4. The mu index -- `mu init --maildir=~/Mail --my-address=you@proton.me',
;;      then `mbsync proton' and `mu index' once.  `rata-mail-doctor' (SPC a e d)
;;      walks through what is still missing.
;;   5. Bridge's certificate -- Bridge 3.x keeps it inside its encrypted vault
;;      and writes no cert.pem until told: `cert export' in the Bridge CLI, to
;;      the directory named first in `rata-mail-bridge-cert-candidates' that
;;      applies to the host.  mbsync and smtpmail both read that file.
;;
;; The Bridge command itself is per-host too.  On Ubuntu it is the Flatpak
;; (`flatpak run ch.protonmail.protonmail-bridge').  On Arch the package puts a
;; Qt launcher on PATH as `protonmail-bridge', and `protonmail-bridge --cli'
;; does not work: the launcher waits for a gRPC config that the CLI frontend
;; never writes, times out, and leaves the backend orphaned.  The Go binary at
;; /usr/lib/protonmail/bridge/bridge takes `--cli' and `--noninteractive'
;; directly.  `rata-mail-bridge-command' picks the right spelling, so every
;; hint the doctor prints is one the host can run.
;;
;; mu4e is NOT an elpaca package.  Its elisp is version-locked to the `mu' binary
;; (the two speak a private protocol), so it is loaded from wherever the binary's
;; package put it -- Homebrew's Cellar here, /usr/share on Arch.  When no mu4e can
;; be found the leader keys still exist and say so (`rata-mail-unavailable'),
;; rather than being dead or bound to an undefined symbol.
;;
;; Proton-specific traps, each of which is a setting below or a line in
;; mbsyncrc.example:
;;   - Bridge files sent mail into Sent itself -> `mu4e-sent-messages-behavior'
;;     is `delete', or every sent message exists twice.
;;   - "All Mail" is a virtual folder of everything; syncing it duplicates the
;;     whole store and Bridge rejects mbsync's expunge on it.  "Labels/*" are the
;;     same messages again under each label.  Both are excluded in the template.
;;   - mbsync renames files on move -> `mu4e-change-filenames-when-moving' t.
;;   - The certificate is self-signed.  mbsync gets it via CertificateFile;
;;     Emacs gets it via `gnutls-trustfiles', so `smtpmail' never hits the NSM
;;     prompt.

(require 'seq)

(eval-when-compile
  (defvar mu4e-headers-mode-map)
  (defvar mu4e-view-mode-map)
  (defvar gnutls-trustfiles))

(declare-function mu4e "mu4e")
(declare-function mu4e-compose-new "mu4e-compose")
(declare-function mu4e-search "mu4e-search")
(declare-function mu4e-update-mail-and-index "mu4e-update")
(declare-function mu4e-org-store-and-capture "mu4e-org")

;;; ------------------------------------------------------------
;;; Per-machine values
;;; ------------------------------------------------------------

(defcustom rata-mail-address nil
  "The Proton address mu4e reads and smtpmail sends as.
nil in the tracked sources; set it in local.el.  Every entry point signals
a `user-error' naming local.el.example while it is unset."
  :type '(choice (const nil) string)
  :group 'rata)

(defcustom rata-mail-maildir (expand-file-name "~/Mail")
  "Where mbsync writes the Maildir and where `mu init --maildir' pointed."
  :type 'directory
  :group 'rata)

(defcustom rata-mail-mbsync-channel "proton"
  "The mbsync channel name.  Must match the `Channel' line in ~/.mbsyncrc;
mbsyncrc.example uses this value and a test keeps the two in step."
  :type 'string
  :group 'rata)

(defcustom rata-mail-bridge-host "127.0.0.1"
  "Where Proton Mail Bridge listens.  Bridge binds loopback only."
  :type 'string
  :group 'rata)

(defcustom rata-mail-bridge-imap-port 1143
  "Bridge's IMAP port (its default)."
  :type 'integer
  :group 'rata)

(defcustom rata-mail-bridge-smtp-port 1025
  "Bridge's SMTP port (its default)."
  :type 'integer
  :group 'rata)

(defcustom rata-mail-bridge-cert-candidates
  '("~/.var/app/ch.protonmail.protonmail-bridge/config/protonmail/bridge-v3/cert.pem"
    "~/.config/protonmail/bridge-v3/cert.pem")
  "Where Bridge's self-signed certificate is exported to: the Flatpak
sandbox first, then a native package's config directory.  The first that
exists is trusted for the SMTP connection; mbsync needs the same path in
its CertificateFile.  Bridge 3.x does not write this file by itself --
`cert export' in its CLI does (see `rata-mail-bridge-cert-dir')."
  :type '(repeat file)
  :group 'rata)

(defcustom rata-mail-update-interval 300
  "Seconds between automatic `mbsync' runs while mu4e is open, or nil."
  :type '(choice (const nil) integer)
  :group 'rata)

;;; ------------------------------------------------------------
;;; Locating things -- pure helpers first, so they are testable
;;; ------------------------------------------------------------

(defun rata-mail-mu4e-dir-candidates (mu-binary)
  "Directories that may hold mu4e.el for the `mu' binary at MU-BINARY.
Pure: derives the install prefix (strip `bin/mu') and lists the layouts
the packagers use -- Homebrew installs the elisp under a `mu/' directory
inside site-lisp, meson's default and the distro packages use `mu4e/'."
  (let ((prefix (file-name-directory
                 (directory-file-name (file-name-directory mu-binary)))))
    (list (expand-file-name "share/emacs/site-lisp/mu/mu4e" prefix)
          (expand-file-name "share/emacs/site-lisp/mu4e" prefix)
          (expand-file-name "share/emacs/site-lisp/mu" prefix))))

(defun rata-mail-mu4e-dir ()
  "The directory holding mu4e.el beside the installed `mu', or nil.
Both the PATH entry and its `file-truename' are tried: Homebrew's bin/mu is
a symlink into the Cellar, and the elisp is reachable from either side."
  (when-let* ((exe (executable-find "mu")))
    (seq-find (lambda (dir) (file-exists-p (expand-file-name "mu4e.el" dir)))
              (delete-dups
               (append (rata-mail-mu4e-dir-candidates exe)
                       (rata-mail-mu4e-dir-candidates (file-truename exe)))))))

(defun rata-mail-bridge-cert ()
  "The first existing certificate in `rata-mail-bridge-cert-candidates', or nil."
  (seq-find #'file-exists-p
            (mapcar #'expand-file-name rata-mail-bridge-cert-candidates)))

(defcustom rata-mail-bridge-native-binary "/usr/lib/protonmail/bridge/bridge"
  "Bridge's Go binary as the Arch package installs it, behind the Qt
launcher that `protonmail-bridge' on PATH runs.  The launcher cannot drive
`--cli'; this binary can."
  :type 'file
  :group 'rata)

(defcustom rata-mail-bridge-flatpak-id "ch.protonmail.protonmail-bridge"
  "The Flatpak application id of Bridge, on hosts that run it that way."
  :type 'string
  :group 'rata)

(defun rata-mail-bridge-command-for (flag native flatpak)
  "The shell command that runs Bridge with FLAG on a host described by
NATIVE (the Go binary exists at `rata-mail-bridge-native-binary') and
FLATPAK (the Flatpak is installed).  Pure, so the choice is testable:
the native binary wins because it is the only spelling on such a host
that works for `--cli'; otherwise the Flatpak; otherwise the install
command, so a hint on a bare host still says what to do."
  (cond (native (format "%s %s" rata-mail-bridge-native-binary flag))
        (flatpak (format "flatpak run %s %s" rata-mail-bridge-flatpak-id flag))
        (t (format "protonmail-bridge %s  (install: pacman -S protonmail-bridge, or flatpak install flathub %s)"
                   flag rata-mail-bridge-flatpak-id))))

(defun rata-mail-bridge-command (flag)
  "`rata-mail-bridge-command-for' FLAG, probing this host.
The Flatpak is detected by its sandbox directory rather than by running
`flatpak info', so the doctor never spawns a process to print a hint."
  (rata-mail-bridge-command-for
   flag
   (file-executable-p rata-mail-bridge-native-binary)
   (file-directory-p (expand-file-name
                      (concat "~/.var/app/" rata-mail-bridge-flatpak-id)))))

(defun rata-mail-bridge-cert-dir ()
  "The directory `cert export' should be pointed at on this host: the
Flatpak candidate when the sandbox exists, else the native one."
  (file-name-directory
   (expand-file-name
    (or (seq-find (lambda (c) (file-directory-p (file-name-directory (expand-file-name c))))
                  rata-mail-bridge-cert-candidates)
        (car (last rata-mail-bridge-cert-candidates))))))

(defun rata-mail-port-open-p (host port)
  "Non-nil when something accepts a TCP connection on HOST:PORT.
A plain connect-and-close: cheap, and it is exactly the question `is
Bridge running' reduces to."
  (let ((proc (ignore-errors
                (open-network-stream "rata-mail-probe" nil host port
                                     :type 'plain :nowait nil))))
    (when proc
      (delete-process proc)
      t)))

(defun rata-mail-bridge-running-p ()
  "Non-nil when Bridge's IMAP port accepts connections."
  (rata-mail-port-open-p rata-mail-bridge-host rata-mail-bridge-imap-port))

(defvar rata-mail--mu4e-dir (rata-mail-mu4e-dir)
  "Where mu4e was found at load time, or nil.  Read by `rata-mail--require'.")

;;; ------------------------------------------------------------
;;; Entry points -- always defined, so the keys are always live
;;; ------------------------------------------------------------

(defun rata-mail--require ()
  "Load mu4e, or explain in one `user-error' what is missing.
Configuration first (the operator's job), tooling second (`just
install-deps'), so the message names the thing to fix next."
  (unless rata-mail-address
    (user-error "Email is not configured: `rata-mail-address' is unset.  See local.el.example"))
  (unless rata-mail--mu4e-dir
    (user-error "mu4e not found beside `mu' -- install mu (just install-deps), then restart Emacs"))
  (require 'mu4e))

(defun rata-mail ()
  "Open mu4e's main view.  Works offline; only fetching needs Bridge."
  (interactive)
  (rata-mail--require)
  (mu4e))

(defun rata-mail-compose ()
  "Compose a new message."
  (interactive)
  (rata-mail--require)
  (mu4e-compose-new))

(defun rata-mail-search ()
  "Search the mu index."
  (interactive)
  (rata-mail--require)
  (call-interactively #'mu4e-search))

(defun rata-mail-update ()
  "Run mbsync and reindex.
Checks Bridge's port first: mbsync's own failure is a connection-refused
line buried in the update buffer, while this is one sentence with the
command that fixes it."
  (interactive)
  (rata-mail--require)
  (unless (rata-mail-bridge-running-p)
    (user-error "Proton Mail Bridge is not running (nothing on %s:%d).  Start it: %s"
                rata-mail-bridge-host rata-mail-bridge-imap-port
                (rata-mail-bridge-command "--noninteractive")))
  (mu4e-update-mail-and-index nil))

(defun rata-mail-doctor ()
  "Report each piece of the mail setup as present or missing.
The pieces are per-machine and not in the repo, so this is the checklist
for a new host; it prints the command that supplies each missing one."
  (interactive)
  (let ((rows
         (list
          (list "rata-mail-address" rata-mail-address
                "set it in local.el (see local.el.example)")
          (list "mu binary" (executable-find "mu")
                "just install-deps  (AUR `mu' on Arch; Homebrew on Ubuntu -- apt's is too old)")
          (list "mu4e elisp" rata-mail--mu4e-dir
                "comes with mu; restart Emacs after installing")
          (list "mbsync binary" (executable-find "mbsync")
                "just install-deps  (isync >= 1.5)")
          (list "~/.mbsyncrc" (and (file-exists-p "~/.mbsyncrc") "~/.mbsyncrc")
                "cp mbsyncrc.example ~/.mbsyncrc, then fill in the address")
          (list "Bridge certificate" (rata-mail-bridge-cert)
                (format "in `%s': login (once), then `cert export' to %s"
                        (rata-mail-bridge-command "--cli")
                        (rata-mail-bridge-cert-dir)))
          (list "Bridge listening" (and (rata-mail-bridge-running-p)
                                        (format "%s:%d" rata-mail-bridge-host
                                                rata-mail-bridge-imap-port))
                (rata-mail-bridge-command "--noninteractive"))
          (list "Maildir" (and (file-directory-p rata-mail-maildir) rata-mail-maildir)
                (format "mu init --maildir=%s --my-address=<address>; mbsync %s; mu index"
                        rata-mail-maildir rata-mail-mbsync-channel))
          (list "auth-source entry"
                (and rata-mail-address
                     (auth-source-search :host rata-mail-bridge-host
                                         :port (number-to-string rata-mail-bridge-smtp-port)
                                         :user rata-mail-address :max 1)
                     "~/.authinfo.gpg")
                (format "machine %s port %d login %s password <bridge-password>  (login must equal rata-mail-address exactly)"
                        rata-mail-bridge-host rata-mail-bridge-smtp-port
                        (or rata-mail-address "<address>"))))))
    (with-current-buffer (get-buffer-create "*rata-mail-doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Mail setup on this machine\n\n")
        (pcase-dolist (`(,what ,value ,fix) rows)
          (insert (format "  %-20s %s\n" what
                          (if value
                              (format "OK   %s" (if (stringp value) value ""))
                            (format "MISSING  -> %s" fix)))))
        (special-mode))
      (display-buffer (current-buffer)))))

;;; ------------------------------------------------------------
;;; mu4e -- only when its elisp exists beside the binary
;;; ------------------------------------------------------------

(when rata-mail--mu4e-dir
  (add-to-list 'load-path rata-mail--mu4e-dir)

  (use-package mu4e
    :ensure nil
    :commands (mu4e mu4e-compose-new mu4e-search mu4e-update-mail-and-index)
    :custom
    ;; Fetching.
    (mu4e-get-mail-command (concat "mbsync " rata-mail-mbsync-channel))
    (mu4e-update-interval rata-mail-update-interval)
    (mu4e-change-filenames-when-moving t)  ; mbsync renames on move
    (mu4e-hide-index-messages t)
    ;; Proton's folders as Bridge names them.
    (mu4e-sent-folder   "/Sent")
    (mu4e-drafts-folder "/Drafts")
    (mu4e-trash-folder  "/Trash")
    (mu4e-refile-folder "/Archive")
    (mu4e-sent-messages-behavior 'delete)  ; Bridge files the copy itself
    (mu4e-maildir-shortcuts '((:maildir "/INBOX"   :key ?i)
                              (:maildir "/Sent"    :key ?s)
                              (:maildir "/Archive" :key ?a)
                              (:maildir "/Drafts"  :key ?d)
                              (:maildir "/Trash"   :key ?t)))
    (mu4e-bookmarks '((:name "Inbox"       :query "maildir:/INBOX"                    :key ?i)
                      (:name "Unread"      :query "flag:unread AND NOT flag:trashed"  :key ?u)
                      (:name "Today"       :query "date:today..now"                   :key ?t)
                      (:name "Last 7 days" :query "date:7d..now"                      :key ?w)
                      (:name "Flagged"     :query "flag:flagged"                      :key ?f)))
    ;; Reading.
    (mu4e-headers-date-format "%Y-%m-%d")
    (mu4e-headers-fields '((:human-date . 12) (:flags . 6) (:from . 24) (:subject)))
    (mu4e-attachment-dir (expand-file-name "~/Downloads"))
    (mu4e-confirm-quit nil)
    ;; Writing.
    (mu4e-compose-format-flowed t)
    (message-kill-buffer-on-exit t)
    :config
    (require 'mu4e-org)  ; `mu4e:' org links, `org-store-link' on a message
    ;; Local leader in the two reading buffers.  Scoped with :keymaps to maps
    ;; that exist only once mu4e is loaded, which is the one case where a
    ;; binding belongs in :config (AGENTS.md, keybinding conventions).
    (general-define-key
     :states '(normal visual)
     :keymaps '(mu4e-headers-mode-map mu4e-view-mode-map)
     :prefix ","
     ""  '(:ignore t :which-key "mail")
     "c" '(mu4e-org-store-and-capture :which-key "capture to org")
     "u" '(rata-mail-update           :which-key "fetch and index"))))

;;; ------------------------------------------------------------
;;; Sending -- smtpmail through Bridge, password from auth-source
;;; ------------------------------------------------------------

(when rata-mail-address
  (setq user-mail-address rata-mail-address))

(setq send-mail-function         #'smtpmail-send-it
      message-send-mail-function #'smtpmail-send-it
      smtpmail-smtp-server       rata-mail-bridge-host
      smtpmail-smtp-service      rata-mail-bridge-smtp-port
      smtpmail-stream-type       'starttls
      smtpmail-smtp-user         rata-mail-address)

;; Trust Bridge's self-signed certificate for the STARTTLS handshake.  Without
;; this, gnutls reports the chain as untrusted and NSM asks on every send.
(with-eval-after-load 'gnutls
  (when-let* ((cert (rata-mail-bridge-cert)))
    (add-to-list 'gnutls-trustfiles cert)))

;;; ------------------------------------------------------------
;;; Keys -- top level, so they exist from startup (FAIL-0009)
;;; ------------------------------------------------------------

(rata-leader
  :states '(normal visual)
  "ae"  '(:ignore t :which-key "email")
  "aee" '(rata-mail         :which-key "open mu4e")
  "aec" '(rata-mail-compose :which-key "compose")
  "aeu" '(rata-mail-update  :which-key "fetch and index")
  "aes" '(rata-mail-search  :which-key "search")
  "aed" '(rata-mail-doctor  :which-key "setup check"))

(provide 'init-mail)
