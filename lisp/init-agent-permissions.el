;;; init-agent-permissions.el --- Agent shell permission management -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Declarative whitelist and blacklist permission policies for `agent-shell'
;; across multiple harness backends (Claude Code, Pi, Gemini, Antigravity,
;; Codex, OpenCode, Goose, etc.).
;;
;; Intercepts ACP `session/request_permission' requests via
;; `agent-shell-permission-responder-function' before any interactive prompt is
;; rendered.
;;
;; Safety Precedence:
;; 1. Blacklist rules are evaluated first. If matched, the request is immediately
;;    DENIED (reject_once / cancelled) and logged.
;; 2. Whitelist rules are evaluated next. If matched, the request is immediately
;;    ALLOWED (allow_once or allow_always).
;; 3. If neither matches, execution falls back to `rata-agent-permissions-default-action'
;;    (default `'ask', which returns nil so agent-shell renders the normal UI dialog
;;    and alerts the *Agents* panel).
;;
;; No OS command is ever executed by the rule evaluation engine or automated tests.
;; Evaluation is 100% in-memory string matching against structured ACP metadata.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'map)
(require 'seq)
(require 'subr-x)

(defgroup rata-agent-permissions nil
  "Permission management for agent-shell."
  :group 'agent-shell)

(defcustom rata-agent-permissions-enabled t
  "Whether automatic permission evaluation is enabled.
When nil, all permission requests fall back to the interactive dialog."
  :type 'boolean
  :group 'rata-agent-permissions)

(defcustom rata-agent-permissions-default-action 'ask
  "Default action when neither blacklist nor whitelist matches a request.
Options are:
  `ask'   - Fall back to the interactive permission dialog (recommended).
  `deny'  - Deny any unlisted tool execution (zero-trust).
  `allow' - Auto-allow unlisted tool execution."
  :type '(choice (const :tag "Interactive Prompt (Ask)" ask)
                 (const :tag "Deny Unlisted" deny)
                 (const :tag "Allow Unlisted" allow))
  :group 'rata-agent-permissions)

(defcustom rata-agent-permissions-log t
  "Whether to log auto-allowed and denied decisions to `*Messages*'."
  :type 'boolean
  :group 'rata-agent-permissions)

(defvar rata-agent-permissions-default-blacklist
  '((:kind "execute"
     :command "\\(^\\|[;&|[:space:]]\\)\\(rm[[:space:]]+-[^[:space:]]*r\\|shred\\|mkfs\\|dd\\|reboot\\|shutdown\\|sudo\\|su\\|chmod[[:space:]]+-[^[:space:]]*R[[:space:]]+777\\)"
     :reason "Destructive system command")
    (:kind "execute"
     :command "\\(^\\|[;&|[:space:]]\\)git[[:space:]]+\\(push[[:space:]]+.*\\(--force\\|-f\\)\\|reset[[:space:]]+--hard\\|clean[[:space:]]+-[^[:space:]]*f\\)"
     :reason "Destructive git operation")
    (:path "\\(\\.authinfo\\|/\\.ssh/\\|/\\.gnupg/\\|id_rsa\\|id_ed25519\\|\\.env\\'\\|local\\.el\\'\\)"
     :reason "Sensitive credential or configuration file"))
  "Default blacklist rules applied to all backends.
Blacklist rules take precedence over all whitelist rules.")

(defvar rata-agent-permissions-default-whitelist
  '((:kind "execute"
     :command "\\(^\\|[;&|[:space:]]\\)git[[:space:]]+\\(status\\|diff\\|log\\|show\\|branch\\|remote\\|rev-parse\\)\\([[:space:]]\\|\\'\\)"
     :reason "Safe read-only git command")
    (:kind "execute"
     :command "\\(^\\|[;&|[:space:]]\\)\\(just[[:space:]]+\\(lint\\|test\\|check\\|compile\\|todos\\)\\|cargo[[:space:]]+\\(test\\|check\\|clippy\\)\\|go[[:space:]]+test\\|pytest\\|npm[[:space:]]+test\\)\\([[:space:]]\\|\\'\\)"
     :reason "Safe test or lint runner")
    (:kind "execute"
     :command "\\(^\\|[;&|[:space:]]\\)\\(ls\\|cat\\|head\\|tail\\|wc\\|pwd\\|date\\|which\\|echo\\|grep\\|find\\)\\([[:space:]]\\|\\'\\)"
     :reason "Safe read-only shell utility")
    (:kind ("read" "search")
     :predicate rata-agent-permissions--path-in-project-p
     :reason "Read or search within project directory"))
  "Default whitelist rules applied to all backends.")

(defcustom rata-agent-permissions-blacklist nil
  "User custom blacklist rules appended to the default blacklist.
Each entry is a plist with match keys (:backends, :kind, :command, :path,
:title, :predicate) and :reason."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :group 'rata-agent-permissions)

(defcustom rata-agent-permissions-whitelist nil
  "User custom whitelist rules appended to the default whitelist.
Each entry is a plist with match keys (:backends, :kind, :command, :path,
:title, :predicate), :reason, and optional :mode (`allow_once' or
`allow_always')."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :group 'rata-agent-permissions)

(defcustom rata-agent-permissions-backend-rules nil
  "Per-backend permission overrides.
An alist of (BACKEND-IDENTIFIER . (:whitelist (...) :blacklist (...))).
BACKEND-IDENTIFIER is a symbol, e.g. `claude-code', `pi', `gemini-cli',
`antigravity', `codex', `opencode', `goose'.

Example:
  \\='((claude-code
     (:whitelist (((:kind \"execute\" :command \"^make\")))))
    (pi
     (:blacklist (((:kind \"execute\" :command \"^docker\"))))))"
  :type '(alist :key-type symbol :value-type (plist :key-type symbol :value-type sexp))
  :group 'rata-agent-permissions)

(defvar rata-agent-permissions-history nil
  "Recent permission evaluation decisions, most recent first.
Each entry is an alist with :timestamp, :decision, :reason, :backend,
:kind, :command, and :path.")

(defconst rata-agent-permissions-history-max 50
  "Maximum entries to retain in `rata-agent-permissions-history'.")

;;; ------------------------------------------------------------
;;; Context Normalization (pure data extraction)
;;; ------------------------------------------------------------

(defun rata-agent-permissions--path-in-project-p (ctx)
  "Return non-nil if CTX's :path is inside the project root."
  (let ((path (plist-get ctx :path))
        (project (plist-get ctx :project)))
    (cond
     ((or (null path) (string-empty-p path)) nil)
     ;; If path is relative and doesn't start with / or ~, it's inside the project
     ((not (file-name-absolute-p path))
      (not (string-prefix-p "~" path)))
     ((and project (stringp project) (not (string-empty-p project)))
      (string-prefix-p (expand-file-name project)
                       (expand-file-name path)))
     (t nil))))

(defun rata-agent-permissions--extract-command (tool-call raw-input title)
  "Extract normalized command string from TOOL-CALL, RAW-INPUT, or TITLE."
  (let ((cmd (or (map-elt tool-call :command)
                 (when raw-input
                   (or (map-elt raw-input 'command)
                       (map-elt raw-input :command))))))
    (cond
     ((stringp cmd) (string-trim cmd))
     ((vectorp cmd) (string-trim (combine-and-quote-strings (append cmd nil))))
     ((and (stringp title) (string-match "`\\([^`\n]+\\)`" title))
      (string-trim (match-string 1 title)))
     ((and (stringp title) (string-match "\\`\\(?:Bash\\|Execute\\|Run\\):?[[:space:]]+\\(.+\\)\\'" title))
      (string-trim (match-string 1 title)))
     (t nil))))

(defun rata-agent-permissions--extract-path (tool-call raw-input title)
  "Extract target file/directory path from TOOL-CALL, RAW-INPUT, or TITLE."
  (let ((p (or (when raw-input
                 (or (map-elt raw-input 'path)
                     (map-elt raw-input :path)
                     (map-elt raw-input 'file_path)
                     (map-elt raw-input :file_path)
                     (map-elt raw-input 'file)
                     (map-elt raw-input :file)))
               (car-safe (map-elt tool-call :locations)))))
    (cond
     ((stringp p) (string-trim p))
     ((and (stringp title)
           (string-match "\\`\\(?:Read\\|Edit\\|Write\\|Search\\)[[:space:]]+\\([^[:space:]\n]+\\)" title))
      (string-trim (match-string 1 title)))
     (t nil))))

(defun rata-agent-permissions--resolve-shell-buffer (tool-call-id)
  "Find the `agent-shell' buffer associated with TOOL-CALL-ID."
  (cond
   ((and (boundp 'agent-shell--state)
         (bound-and-true-p agent-shell--state)
         (or (null tool-call-id)
             (map-nested-elt agent-shell--state (list :tool-calls tool-call-id))))
    (current-buffer))
   ((and (fboundp 'agent-shell-buffers)
         (boundp 'agent-shell--state))
    (seq-find (lambda (buf)
                (when (buffer-live-p buf)
                  (let ((st (buffer-local-value 'agent-shell--state buf)))
                    (and st (or (null tool-call-id)
                                (map-nested-elt st (list :tool-calls tool-call-id)))))))
              (agent-shell-buffers)))
   (t (current-buffer))))

(defun rata-agent-permissions--context (permission)
  "Normalize PERMISSION alist into a clean context plist."
  (let* ((tool-call (map-elt permission :tool-call))
         (options (map-elt permission :options))
         (respond (map-elt permission :respond))
         (tool-call-id (or (map-elt tool-call :tool-call-id)
                           (map-elt tool-call 'toolCallId)))
         (kind (or (map-elt tool-call :kind)
                   (map-elt tool-call 'kind)
                   "other"))
         (title (or (map-elt tool-call :title)
                    (map-elt tool-call 'title)
                    ""))
         (raw-input (or (map-elt tool-call :raw-input)
                        (map-elt tool-call 'rawInput)))
         (buf (rata-agent-permissions--resolve-shell-buffer tool-call-id))
         (state (and (buffer-live-p buf)
                     (boundp 'agent-shell--state)
                     (buffer-local-value 'agent-shell--state buf)))
         (backend (or (and state (map-nested-elt state '(:agent-config :identifier)))
                      'unknown))
         (project (with-current-buffer (if (buffer-live-p buf) buf (current-buffer))
                    (or (and (fboundp 'projectile-project-root) (projectile-project-root))
                        (and (fboundp 'project-root)
                             (when-let* ((p (project-current)))
                               (project-root p)))
                        default-directory)))
         (command (rata-agent-permissions--extract-command tool-call raw-input title))
         (path (rata-agent-permissions--extract-path tool-call raw-input title)))
    (list :backend backend
          :kind kind
          :command command
          :path path
          :title title
          :raw-input raw-input
          :tool-call tool-call
          :options options
          :respond respond
          :buffer buf
          :project project)))

;;; ------------------------------------------------------------
;;; Rule Matching (pure pattern matching, zero side-effects)
;;; ------------------------------------------------------------

(defun rata-agent-permissions--match-backends-p (rule-backends backend)
  "Return non-nil if BACKEND matches RULE-BACKENDS."
  (cond
   ((or (null rule-backends) (eq rule-backends t) (eq rule-backends 'all)) t)
   ((listp rule-backends) (memq backend rule-backends))
   ((symbolp rule-backends) (eq backend rule-backends))
   (t nil)))

(defun rata-agent-permissions--match-kind-p (rule-kind kind)
  "Return non-nil if KIND matches RULE-KIND."
  (cond
   ((or (null rule-kind) (eq rule-kind t)) t)
   ((listp rule-kind) (member kind rule-kind))
   ((stringp rule-kind) (equal kind rule-kind))
   (t nil)))

(defun rata-agent-permissions--match-pattern-p (pattern target)
  "Return non-nil if TARGET matches PATTERN (regexp or predicate function)."
  (cond
   ((null pattern) t)
   ((or (null target) (string-empty-p target)) nil)
   ((stringp pattern) (string-match-p pattern target))
   ((functionp pattern) (funcall pattern target))
   (t nil)))

(defun rata-agent-permissions--match-rule-p (rule ctx)
  "Return non-nil if RULE matches the request context CTX."
  (let ((rule-backends (plist-get rule :backends))
        (rule-kind (plist-get rule :kind))
        (rule-cmd (plist-get rule :command))
        (rule-path (or (plist-get rule :path) (plist-get rule :file)))
        (rule-title (plist-get rule :title))
        (rule-pred (plist-get rule :predicate)))
    (and (rata-agent-permissions--match-backends-p rule-backends (plist-get ctx :backend))
         (rata-agent-permissions--match-kind-p rule-kind (plist-get ctx :kind))
         (rata-agent-permissions--match-pattern-p rule-cmd (plist-get ctx :command))
         (rata-agent-permissions--match-pattern-p rule-path (plist-get ctx :path))
         (rata-agent-permissions--match-pattern-p rule-title (plist-get ctx :title))
         (or (null rule-pred) (funcall rule-pred ctx)))))

;;; ------------------------------------------------------------
;;; Rule Evaluation Engine
;;; ------------------------------------------------------------

(defun rata-agent-permissions--get-backend-rules (backend key)
  "Get rules for BACKEND under KEY (`:whitelist' or `:blacklist')."
  (when-let* ((entry (assq backend rata-agent-permissions-backend-rules)))
    (let* ((props (cond
                   ((keywordp (cadr entry)) (cdr entry))
                   ((and (consp (cadr entry)) (keywordp (caadr entry))) (cadr entry))
                   (t (cdr entry))))
           (rules (plist-get props key)))
      (if (and (consp rules) (consp (car rules)) (consp (caar rules)))
          (car rules)
        rules))))

(defun rata-agent-permissions--evaluate (ctx)
  "Evaluate request context CTX against all active permission rules.
Returns a plist with (:decision <allow|deny|ask> :mode <mode>
:reason <string> :rule <rule>)."
  (let* ((backend (plist-get ctx :backend))
         ;; 1. Collect blacklist rules (backend-specific first, then custom, then defaults)
         (blacklist (append (rata-agent-permissions--get-backend-rules backend :blacklist)
                            rata-agent-permissions-blacklist
                            rata-agent-permissions-default-blacklist))
         ;; 2. Collect whitelist rules (backend-specific first, then custom, then defaults)
         (whitelist (append (rata-agent-permissions--get-backend-rules backend :whitelist)
                            rata-agent-permissions-whitelist
                            rata-agent-permissions-default-whitelist))
         (blacklisted-rule (seq-find (lambda (rule)
                                       (rata-agent-permissions--match-rule-p rule ctx))
                                     blacklist)))
    (if blacklisted-rule
        (list :decision 'deny
              :reason (or (plist-get blacklisted-rule :reason) "Blacklist rule match")
              :rule blacklisted-rule)
      (if-let* ((whitelisted-rule (seq-find (lambda (rule)
                                              (rata-agent-permissions--match-rule-p rule ctx))
                                            whitelist)))
          (list :decision 'allow
                :mode (or (plist-get whitelisted-rule :mode) 'allow_once)
                :reason (or (plist-get whitelisted-rule :reason) "Whitelist rule match")
                :rule whitelisted-rule)
        (list :decision rata-agent-permissions-default-action
              :reason (format "Default fallback (%s)" rata-agent-permissions-default-action)
              :rule nil)))))

;;; ------------------------------------------------------------
;;; Responder Hook & ACP Dispatcher
;;; ------------------------------------------------------------

(defun rata-agent-permissions--find-action (options kind-target)
  "Find action in OPTIONS matching KIND-TARGET."
  (or (seq-find (lambda (opt)
                  (equal (map-elt opt :kind) kind-target))
                options)
      (when (equal kind-target "reject_once")
        (seq-find (lambda (opt)
                    (let ((name (or (map-elt opt :name) (map-elt opt :option) "")))
                      (string-match-p "\\(?:Reject\\|Cancel\\|Deny\\)" name)))
                  options))))

(defun rata-agent-permissions--record-history (ctx decision reason)
  "Record evaluation decision for CTX in `rata-agent-permissions-history'."
  (let ((entry `((:timestamp . ,(current-time))
                 (:decision . ,decision)
                 (:reason . ,reason)
                 (:backend . ,(plist-get ctx :backend))
                 (:kind . ,(plist-get ctx :kind))
                 (:command . ,(plist-get ctx :command))
                 (:path . ,(plist-get ctx :path)))))
    (push entry rata-agent-permissions-history)
    (when (> (length rata-agent-permissions-history) rata-agent-permissions-history-max)
      (setq rata-agent-permissions-history
            (seq-take rata-agent-permissions-history rata-agent-permissions-history-max)))))

(defun rata-agent-permissions-responder (permission)
  "The entry point set as `agent-shell-permission-responder-function'.
Evaluates PERMISSION rules. Returns non-nil if handled programmatically,
or nil to fall back to the interactive UI dialog."
  (if (not rata-agent-permissions-enabled)
      nil
    (let* ((ctx (rata-agent-permissions--context permission))
           (eval-result (rata-agent-permissions--evaluate ctx))
           (decision (plist-get eval-result :decision))
           (reason (plist-get eval-result :reason))
           (respond (plist-get ctx :respond))
           (options (plist-get ctx :options))
           (subject (or (plist-get ctx :command)
                        (plist-get ctx :path)
                        (plist-get ctx :title)
                        "tool")))
      (rata-agent-permissions--record-history ctx decision reason)
      (pcase decision
        ('allow
         (let* ((mode (plist-get eval-result :mode))
                (opt (if (eq mode 'allow_always)
                         (or (rata-agent-permissions--find-action options "allow_always")
                             (rata-agent-permissions--find-action options "allow_once"))
                       (or (rata-agent-permissions--find-action options "allow_once")
                           (rata-agent-permissions--find-action options "allow_always")))))
           (if (and opt respond)
               (progn
                 (funcall respond (map-elt opt :option-id))
                 (when rata-agent-permissions-log
                   (message "agent-permissions [%s]: Allowed '%s' (%s)"
                            (plist-get ctx :backend) subject reason))
                 t)
             ;; If no allow option exists, fall back to interactive
             nil)))
        ('deny
         (let ((opt (rata-agent-permissions--find-action options "reject_once")))
           (if (and opt respond)
               (funcall respond (map-elt opt :option-id))
             ;; If no reject option-id, cancel directly
             (when (and (fboundp 'agent-shell--send-permission-response)
                        (plist-get ctx :buffer))
               (with-current-buffer (plist-get ctx :buffer)
                 (when-let* ((st (and (boundp 'agent-shell--state) agent-shell--state)))
                   (agent-shell--send-permission-response
                    :client (map-elt st :client)
                    :request-id (map-nested-elt permission '(:tool-call :permission-request-id))
                    :cancelled t
                    :state st
                    :tool-call-id (map-nested-elt permission '(:tool-call :tool-call-id)))))))
           (message "agent-permissions [%s]: DENIED '%s' (Reason: %s)"
                    (plist-get ctx :backend) subject reason)
           t))
        ('ask nil)
        (_ nil)))))

;;; ------------------------------------------------------------
;;; Interactive Commands
;;; ------------------------------------------------------------

;;;###autoload
(defun rata-agent-permissions-test (command-or-path &optional kind backend)
  "Test how COMMAND-OR-PATH would be evaluated by active permission rules.
Dry-run simulator: executes NO shell commands or OS processes."
  (interactive
   (list (read-string "Command or path to test: ")
         (intern (completing-read "Tool kind (default execute): "
                                  '("execute" "read" "edit" "search" "fetch")
                                  nil t nil nil "execute"))
         (intern (completing-read "Backend (default claude-code): "
                                  '("claude-code" "pi" "gemini-cli" "antigravity" "codex" "opencode")
                                  nil t nil "claude-code"))))
  (let* ((kind-str (if (symbolp kind) (symbol-name kind) (or kind "execute")))
         (is-exec (equal kind-str "execute"))
         (ctx (list :backend (or backend 'claude-code)
                    :kind kind-str
                    :command (when is-exec command-or-path)
                    :path (unless is-exec command-or-path)
                    :title command-or-path
                    :project (or (and (fboundp 'projectile-project-root) (projectile-project-root))
                                 default-directory)))
         (res (rata-agent-permissions--evaluate ctx))
         (decision (plist-get res :decision))
         (reason (plist-get res :reason)))
    (message "agent-permissions test [%s]: '%s' -> %s (Reason: %s)"
             (plist-get ctx :backend) command-or-path
             (upcase (symbol-name decision)) reason)))

;;;###autoload
(defun rata-agent-permissions-toggle ()
  "Toggle automatic permission management on or off."
  (interactive)
  (setq rata-agent-permissions-enabled (not rata-agent-permissions-enabled))
  (message "agent-permissions: %s"
           (if rata-agent-permissions-enabled "ENABLED" "DISABLED (all requests prompt)")))

;;;###autoload
(defun rata-agent-permissions-status ()
  "Display active agent-shell permission status and configuration in a buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Agent Permissions*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Agent Shell Permission Management\n\n")
        (insert (format "Status:         %s\n"
                        (if rata-agent-permissions-enabled "ENABLED" "DISABLED")))
        (insert (format "Default action: %s\n" rata-agent-permissions-default-action))
        (insert (format "Logging:        %s\n\n" (if rata-agent-permissions-log "ON" "OFF")))

        (insert "## Rule Counts\n")
        (insert (format "  Blacklist: %d default, %d custom\n"
                        (length rata-agent-permissions-default-blacklist)
                        (length rata-agent-permissions-blacklist)))
        (insert (format "  Whitelist: %d default, %d custom\n"
                        (length rata-agent-permissions-default-whitelist)
                        (length rata-agent-permissions-whitelist)))
        (insert (format "  Backend-specific overrides: %d\n\n"
                        (length rata-agent-permissions-backend-rules)))

        (insert "## Recent Decisions\n")
        (if (null rata-agent-permissions-history)
            (insert "  (No decisions recorded yet)\n")
          (dolist (item (seq-take rata-agent-permissions-history 15))
            (insert (format "  [%s] %-5s %-12s %s (%s)\n"
                            (format-time-string "%H:%M:%S" (map-elt item :timestamp))
                            (upcase (symbol-name (map-elt item :decision)))
                            (format "(%s)" (map-elt item :backend))
                            (or (map-elt item :command) (map-elt item :path) "-")
                            (map-elt item :reason)))))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)))

(provide 'init-agent-permissions)
;;; init-agent-permissions.el ends here
