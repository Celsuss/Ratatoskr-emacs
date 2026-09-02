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
;;   claude-code-acp -- Claude Code (web login, no API key here)
;;   pi-acp          -- Pi; spawns `pi --mode rpc' and bridges it to ACP
;;                      (bun install -g pi-acp; needs pi >= 0.80.4)
;; Both values are agent-shell's own defaults; they are spelled out because the
;; adapter name is the one thing that breaks when an upstream renames it.
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
  (agent-shell-anthropic-claude-acp-command '("claude-code-acp"))
  (agent-shell-pi-acp-command '("pi-acp")))

;; Declared, never required: these modules load as source, so a
;; `eval-when-compile' require would run on every startup (FAIL-0012 / L-028).
(declare-function agent-shell-shell-buffer "agent-shell")
(declare-function agent-shell-send-file "agent-shell")

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
