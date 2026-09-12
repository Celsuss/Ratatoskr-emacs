;;; -*- lexical-binding: t; -*-
;;; init-llm.el --- LLM integrations (gptel, ellama, aidermacs, agent-shell)

;; --- gptel (Ollama local) ---
(use-package gptel
  :after general
  :config
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    ;; Bare Ollama tags -- gptel talks to Ollama's API directly, so no
    ;; `ollama_chat/' litellm routing prefix (that is only correct for aider).
    :models '("qwen3.5-coder:9b-32k" "mistral:latest")
    :stream t)
  (setq gptel-default-mode 'org-mode))

;; --- ellama (Ollama local) ---
(use-package ellama
  :after general
  :commands (ellama-chat ellama-ask-about ellama-enhance-code)
  :config
  (require 'llm-ollama)
  (setq ellama-provider
        (make-llm-ollama :chat-model "mistral:latest" :embedding-model "nomic-embed-text")))

;; --- aidermacs (Ollama local) ---
(use-package aidermacs
  :after general
  :commands (aidermacs-transient-menu aidermacs-open)
  :config
  (setq aidermacs-default-model "ollama_chat/qwen3.5-coder:9b-32k"))

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
(with-eval-after-load 'agent-shell-ui
  (define-key agent-shell-ui-fragment-map (kbd "<return>")
              #'agent-shell-ui-toggle-fragment))

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
