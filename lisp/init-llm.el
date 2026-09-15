;;; -*- lexical-binding: t; -*-
;;; init-llm.el --- LLM integrations (gptel, ellama, aidermacs, agent-shell)

(require 'url-parse)

;; --- Where the models live: one provider list, three consumers (D-022) ---
;;
;; gptel, ellama and aidermacs each have their own notion of a backend, and
;; each used to be configured by hand with a hostname and a model list of its
;; own.  That works for one machine and fails for two: at home the models are
;; local Ollama; at work they sit behind a LiteLLM proxy whose hostname is
;; corporate identity and may not reach the public remote.
;;
;; So the endpoint and the models are data -- `rata-llm-providers', set per
;; machine in the gitignored `local.el' (D-012) -- and the three tools derive
;; their own configuration from it through the pure functions below.  The
;; tracked default is Ollama on localhost with the models this config has
;; always used, so a machine with no `local.el' entry behaves as before.  API
;; keys are never in either file: an `openai' provider reads its key from
;; ~/.authinfo.gpg through `rata-auth-get', at request time, never at load.

(defcustom rata-llm-providers
  '((:name "Ollama"
     :protocol ollama
     :url "http://localhost:11434"
     :models ("qwen3.5-coder:9b-32k" "mistral:latest")
     :embedding-model "nomic-embed-text"))
  "LLM providers that gptel, ellama and aidermacs are configured from.
Each entry is a plist:

  :name             String.  gptel's backend name, ellama's provider name.
  :protocol         `ollama' for Ollama's native API, or `openai' for any
                    OpenAI-compatible chat-completions server (LiteLLM,
                    vLLM, OpenRouter, ...).
  :url              Base URL.  For `ollama': scheme://host:port, no path.
                    For `openai': everything up to but excluding
                    /chat/completions -- what OPENAI_API_BASE would be,
                    e.g. \"https://litellm.example.com/v1\".
  :models           Non-empty list of model-name strings.  The first is
                    the default for all three tools; gptel and ellama
                    offer the rest for switching.
  :embedding-model  Optional string; ellama's embedding model.
  :auth-host        The `machine' in ~/.authinfo.gpg whose password is the
                    API key.  Defaults to the URL's host for `openai' and
                    to nil (no key) for `ollama'.  Set it to nil explicitly
                    for a keyless OpenAI-compatible server.

The first entry is the default everywhere: gptel registers every entry
and starts on the first (`gptel-menu' switches), ellama puts them all in
`ellama-providers' and starts on the first, aidermacs takes one model and
uses the first.

Set this in `local.el' (D-012); `local.el.example' carries a LiteLLM
entry to copy.  The tracked default is Ollama on localhost, which is not
identity, so an unconfigured machine keeps working."
  :type '(repeat plist)
  :group 'rata)

(defconst rata-llm-protocols '(ollama openai)
  "Values `rata-llm-providers' accepts for :protocol.")

(defun rata-llm-provider-problems (providers)
  "Return a list of strings describing what is wrong with PROVIDERS, or nil.
Pure.  Run once at load so a typo in `local.el' is a warning naming the
entry, rather than a `wrong-type-argument' from inside gptel later."
  (if (not (listp providers))
      (list "rata-llm-providers is not a list")
    (let ((index 0) problems)
      (dolist (provider providers)
        (let ((label (format "entry %d (%s)" index
                             (or (and (listp provider) (plist-get provider :name))
                                 "unnamed"))))
          (if (not (and (listp provider) (stringp (plist-get provider :name))))
              (push (format "%s: not a plist with a string :name" label) problems)
            (unless (memq (plist-get provider :protocol) rata-llm-protocols)
              (push (format "%s: :protocol must be one of %s" label rata-llm-protocols)
                    problems))
            (let* ((url (plist-get provider :url))
                   (parsed (and (stringp url) (url-generic-parse-url url))))
              (unless (and parsed (url-type parsed) (url-host parsed)
                           (not (string-empty-p (url-host parsed))))
                (push (format "%s: :url must be a URL with a scheme and a host" label)
                      problems)))
            (let ((models (plist-get provider :models)))
              (unless (and (consp models) (cl-every #'stringp models))
                (push (format "%s: :models must be a non-empty list of strings" label)
                      problems)))))
        (setq index (1+ index)))
      (nreverse problems))))

(defun rata-llm-default-provider ()
  "The provider all three tools start on: the first in `rata-llm-providers'."
  (car rata-llm-providers))

(defun rata-llm--url (provider)
  "PROVIDER's :url parsed, with any trailing slash dropped first."
  (url-generic-parse-url (string-remove-suffix "/" (plist-get provider :url))))

(defun rata-llm--host-with-port (url)
  "\"host\" or \"host:port\" for gptel -- the port only when URL spelled one."
  (if (url-portspec url)
      (format "%s:%d" (url-host url) (url-portspec url))
    (url-host url)))

(defun rata-llm-auth-host (provider)
  "The auth-source `machine' holding PROVIDER's API key, or nil for no key.
An explicit :auth-host wins, even nil; otherwise an `openai' provider is
keyed on its URL host and an `ollama' one is not keyed."
  (cond ((plist-member provider :auth-host) (plist-get provider :auth-host))
        ((eq (plist-get provider :protocol) 'openai)
         (url-host (rata-llm--url provider)))
        (t nil)))

(defun rata-llm--key-function (provider)
  "A closure reading PROVIDER's key from auth-source, or nil when it has none.
gptel and llm both accept a function here and call it at request time,
which is what keeps ~/.authinfo.gpg out of startup and out of `tests/'."
  (when-let* ((host (rata-llm-auth-host provider)))
    (lambda () (rata-auth-get host))))

;; gptel

(defun rata-llm-gptel-backend-spec (provider)
  "Return (CONSTRUCTOR NAME . KEYWORD-ARGS) that registers PROVIDER with gptel.
Pure; the caller does (apply (car spec) (cdr spec)) once gptel is loaded.
Model names are bare tags for both protocols: gptel speaks each API
directly, so no aider-style `ollama_chat/' routing prefix belongs here."
  (let* ((url (rata-llm--url provider))
         (path (url-filename url))
         (common (list :host (rata-llm--host-with-port url)
                       :protocol (url-type url)
                       :models (mapcar #'intern (plist-get provider :models))
                       :stream t)))
    (pcase (plist-get provider :protocol)
      ('ollama `(gptel-make-ollama ,(plist-get provider :name)
                 ,@common :endpoint ,(concat path "/api/chat")))
      ('openai `(gptel-make-openai ,(plist-get provider :name)
                 ,@common :endpoint ,(concat path "/chat/completions")
                 :key ,(rata-llm--key-function provider))))))

(defun rata-llm-gptel-default-model (provider)
  "PROVIDER's first model as the symbol `gptel-model' wants."
  (intern (car (plist-get provider :models))))

;; ellama (through the llm library)

(defun rata-llm-ellama-provider-spec (provider)
  "Return (CONSTRUCTOR . KEYWORD-ARGS) building PROVIDER's llm struct.
Pure; the caller applies it once `llm-ollama' and `llm-openai' are loaded.
An `ollama' URL's path is not carried over: `llm-ollama' has scheme, host
and port and nothing else."
  (let* ((url (rata-llm--url provider))
         (common (list :chat-model (car (plist-get provider :models)))))
    (when-let* ((embedding (plist-get provider :embedding-model)))
      (setq common (append common (list :embedding-model embedding))))
    (pcase (plist-get provider :protocol)
      ('ollama `(make-llm-ollama :scheme ,(url-type url) :host ,(url-host url)
                                 :port ,(url-port url) ,@common))
      ('openai `(make-llm-openai-compatible
                 :url ,(concat (url-recreate-url url) "/")
                 :key ,(rata-llm--key-function provider) ,@common)))))

;; aidermacs

(defun rata-llm-aider-model (provider)
  "aider's name for PROVIDER's default model.
aider routes through litellm, which needs a provider prefix: `ollama_chat/'
for Ollama's chat API, `openai/' for anything OpenAI-compatible."
  (format "%s/%s"
          (pcase (plist-get provider :protocol)
            ('ollama "ollama_chat")
            ('openai "openai"))
          (car (plist-get provider :models))))

(defun rata-llm-aider-environment (provider key)
  "Environment entries (\"VAR=value\") aider needs to reach PROVIDER.
KEY is the API key string or nil.  It is a parameter rather than looked up
here so this stays pure and no test ever touches auth-source."
  (let ((base (url-recreate-url (rata-llm--url provider))))
    (pcase (plist-get provider :protocol)
      ('ollama (list (concat "OLLAMA_API_BASE=" base)))
      ('openai (delq nil (list (concat "OPENAI_API_BASE=" base)
                               (and key (concat "OPENAI_API_KEY=" key))))))))

(defun rata-llm-aider-set-environment ()
  "Put the default provider's endpoint and key into aider's environment.
Runs from `aidermacs-before-run-backend-hook', which aidermacs calls inside
a `let' of `process-environment' made for exactly this
\(aidermacs-backends.el:91) -- so the key reaches the aider child and no
other process Emacs spawns.  The key is read from auth-source here, at
spawn time, never at load."
  (when-let* ((provider (rata-llm-default-provider)))
    (let ((host (rata-llm-auth-host provider)))
      (dolist (entry (rata-llm-aider-environment
                      provider (and host (rata-auth-get host))))
        (push entry process-environment)))))

;; Validate once, loudly, at load.  `display-warning' rather than `user-error'
;; so the leader keys below still exist and `just batch-strict' turns a
;; malformed `local.el' entry into a failing verification.
(let ((problems (rata-llm-provider-problems rata-llm-providers)))
  (when problems
    (display-warning
     'init-llm
     (format "rata-llm-providers is malformed, see local.el.example: %s"
             (string-join problems "; ")))))

;; --- gptel ---
(use-package gptel
  :after general
  :config
  (let ((backends (mapcar (lambda (provider)
                            (let ((spec (rata-llm-gptel-backend-spec provider)))
                              (apply (car spec) (cdr spec))))
                          rata-llm-providers)))
    (when backends
      (setq gptel-backend (car backends)
            gptel-model (rata-llm-gptel-default-model (rata-llm-default-provider)))))
  (setq gptel-default-mode 'org-mode))

;; --- ellama ---
(use-package ellama
  :after general
  :commands (ellama-chat ellama-ask-about ellama-enhance-code)
  :config
  (require 'llm-ollama)
  (require 'llm-openai)
  (let ((providers (mapcar (lambda (provider)
                             (let ((spec (rata-llm-ellama-provider-spec provider)))
                               (cons (plist-get provider :name)
                                     (apply (car spec) (cdr spec)))))
                           rata-llm-providers)))
    (setq ellama-providers providers)
    (when providers
      (setq ellama-provider (cdar providers)))))

;; --- aidermacs ---
;; The model is a `defcustom' aidermacs reads at spawn.  :custom records the
;; value under use-package's theme and Custom applies it when the `defcustom'
;; runs -- i.e. the variable is void until `aidermacs' loads and correct from
;; then on, which is before anything can spawn aider (the ACP adapter pins
;; below work the same way).  The hook is added at top level (L-011 / L-039):
;; it is aidermacs that runs it, and `add-hook' on a not-yet-defined hook
;; variable is fine -- the later `defcustom' keeps an existing value.
(use-package aidermacs
  :after general
  :commands (aidermacs-transient-menu aidermacs-open)
  :custom
  (aidermacs-default-model (rata-llm-aider-model (rata-llm-default-provider))))

(add-hook 'aidermacs-before-run-backend-hook #'rata-llm-aider-set-environment)

;; --- agent-shell (Claude Code and Pi, both over ACP) ---
;; Neither agent is spawned directly: agent-shell speaks ACP, and each CLI is
;; reached through an adapter binary that must be on `exec-path'.
;;   claude-agent-acp -- Claude Code (web login, no API key here)
;;                       (bun install -g @agentclientprotocol/claude-agent-acp)
;;   pi-acp           -- Pi; spawns `pi --mode rpc' and bridges it to ACP
;;                       (bun install -g pi-acp; needs pi >= 0.80.4)
;; Both values are agent-shell's own current defaults, spelled out so a rename
;; shows up in a diff -- which only helps because
;; `rata-test-acp-adapter-commands-match-upstream' checks they still agree.  The
;; Claude adapter used to be `claude-code-acp' (@zed-industries, dead since
;; 2026-03) and this pin outlived the rename by five months, leaving `SPC a i c c'
;; dead on any host that had not installed the old name: see L-033 / FAIL-0014.
(use-package agent-shell
  :after general
  ;; None of the context senders below carry an `;;;###autoload' cookie
  ;; upstream, so a bound key resolves to nothing until the symbol is listed
  ;; here.  `agent-shell-file-completion-enabled' is deliberately absent: `@'
  ;; completion inside the shell is already on by default.
  :commands (agent-shell
             agent-shell-anthropic-start-claude-code
             agent-shell-pi-start-agent
             agent-shell-send-file
             agent-shell-send-file-to
             agent-shell-send-region
             agent-shell-send-region-to
             agent-shell-send-dwim
             agent-shell-toggle
             agent-shell-switch-buffer)
  :custom
  (agent-shell-anthropic-claude-acp-command '("claude-agent-acp"))
  (agent-shell-pi-acp-command '("pi-acp")))

;; Declared, never required: these modules load as source, so a
;; `eval-when-compile' require would run on every startup (FAIL-0012 / L-028).
(eval-when-compile
  (defvar agent-shell-ui-fragment-map))

(declare-function agent-shell-shell-buffer "agent-shell")
(declare-function agent-shell-send-file "agent-shell")

;; Make the GUI Enter key fold agent-shell's `> ...' sections.
;;
;; agent-shell puts `agent-shell-ui-fragment-map' on the fold chrome as a
;; `keymap' TEXT PROPERTY, and that map binds only `RET' (i.e. ?\r) and
;; `mouse-1'.  A text-property keymap outranks every emulation map, so evil does
;; not shadow it -- `RET' on the chrome already resolves to the toggle.  What
;; breaks is key TRANSLATION, not precedence: a GUI frame delivers `<return>',
;; and Emacs only falls back to translating `<return>' -> `RET' when *nothing*
;; binds `<return>'.  evil-collection's `repl-submit' / `repl-newline' themes
;; bind the key list ("RET" "<return>" "C-m") on `shell-maker-mode-map' and
;; `comint-mode-map', which `agent-shell-mode-map' inherits -- so `<return>' is
;; consumed as submit/newline and the chrome's `RET' entry is unreachable.
;; Terminal frames were never affected; a TTY sends `RET' directly.
;;
;; Binding `<return>' into the fragment map is the extension point upstream
;; documents, and it must be `define-key' rather than `setq': already rendered
;; text holds on to this keymap object.  Because the map covers only the chrome,
;; Enter still submits at the prompt and still inserts a newline in insert state
;; -- the binding is position-sensitive, which an `agent-shell-mode-map' binding
;; could not be.  Both halves are pinned:
;; `rata-test-agent-shell-fold-chrome-answers-gui-return' asserts Enter folds on
;; the chrome, `rata-test-agent-shell-return-still-submits-off-chrome' asserts it
;; does not fold anywhere else.  See L-035.
;;
;; The map exists upstream since 2026-08-14; before that each fold carried its
;; own anonymous keymap and there is nothing to extend.  Guarded, because an
;; `eval-after-load' body that signals turns the first `agent-shell' of the
;; session into a `void-variable' error -- which is what this did on a
;; checkout whose agent-shell predates the map (FAIL-0019).  Without the map
;; the GUI Enter bug is simply still present; the fix is to update agent-shell.
(with-eval-after-load 'agent-shell-ui
  (if (boundp 'agent-shell-ui-fragment-map)
      (define-key agent-shell-ui-fragment-map (kbd "<return>")
                  #'agent-shell-ui-toggle-fragment)
    (message "init-llm: agent-shell predates `agent-shell-ui-fragment-map'; GUI Enter will not fold sections until it is updated (FAIL-0019)")))

(defun rata-agent-shell-send-file (&optional prompt-for-file)
  "Send the current file to an agent shell as an `@' context mention.
Start a shell first when the project has none: `agent-shell-send-file'
resolves its target with `:no-create t' and would otherwise only report
that no shell is available -- where `agent-shell-send-dwim' creates one.
Inserting into a shell whose ACP session is not ready yet is safe; the
insert path replays itself on agent-shell's `prompt-ready' event.
With prefix PROMPT-FOR-FILE, pick a project file instead of this one."
  (interactive "P")
  (unless (agent-shell-shell-buffer :no-error t :no-create t)
    (agent-shell))
  (agent-shell-send-file prompt-for-file))

;; All AI leader keys at top level so they are live from startup (FAIL-0009);
;; commands autoload from their packages via each :commands list.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "ai"    '(:ignore t :which-key "AI")
    "aig"   '(:ignore t :which-key "gptel")
    "aigg"  '(gptel           :which-key "gptel chat")
    "aigs"  '(gptel-send      :which-key "send to gptel")
    "aigr"  '(gptel-rewrite   :which-key "rewrite with gptel")
    "aigm"  '(gptel-menu      :which-key "gptel menu")
    "aie"   '(:ignore t :which-key "ellama")
    "aiee"  '(ellama-chat         :which-key "ellama chat")
    "aiea"  '(ellama-ask-about    :which-key "ask about region")
    "aiec"  '(ellama-enhance-code :which-key "enhance code")
    "aia"   '(:ignore t :which-key "aider")
    "aiaa"  '(aidermacs-transient-menu :which-key "aider menu")
    "aiao"  '(aidermacs-open           :which-key "open aider")
    ;; `aicl' is claude-loop's subtree, bound from init-claude-loop.el off this
    ;; same prefix -- do not add a plain `aicl' leaf here.
    "aic"   '(:ignore t :which-key "agent shell")
    "aics"  '(agent-shell                              :which-key "agent shell")
    "aicc"  '(agent-shell-anthropic-start-claude-code   :which-key "claude code")
    "aicp"  '(agent-shell-pi-start-agent                :which-key "pi")
    ;; The `-to' variants need their own keys rather than a prefix argument:
    ;; `agent-shell-send-file' spends its "P" on prompting for a file, and
    ;; `agent-shell-send-region' never reads the prefix at all.
    "aicf"  '(rata-agent-shell-send-file                :which-key "send current file")
    "aicF"  '(agent-shell-send-file-to                  :which-key "send file -> pick shell")
    "aicr"  '(agent-shell-send-region                   :which-key "send region")
    "aicR"  '(agent-shell-send-region-to                :which-key "send region -> pick shell")
    "aicd"  '(agent-shell-send-dwim                     :which-key "send dwim")
    "aict"  '(agent-shell-toggle                        :which-key "toggle shell")
    "aicb"  '(agent-shell-switch-buffer                 :which-key "switch shell")))

(provide 'init-llm)
