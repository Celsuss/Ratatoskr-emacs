;;; -*- lexical-binding: t; -*-
;;; init-llm.el --- LLM integrations (gptel, ellama, aidermacs, agent-shell)

;; --- gptel (Ollama local) ---
(use-package gptel
  :after general
  :config
  (gptel-make-ollama "Ollama"
    :host "localhost:11434"
    :models '("deepseek-coder:latest" "mistral:latest")
    :stream t)
  (setq gptel-default-mode 'org-mode)
  (rata-leader
    :states '(normal visual)
    "ai"    '(:ignore t :which-key "AI")
    "aig"   '(:ignore t :which-key "gptel")
    "aigg"  '(gptel           :which-key "gptel chat")
    "aigs"  '(gptel-send      :which-key "send to gptel")
    "aigr"  '(gptel-rewrite   :which-key "rewrite with gptel")
    "aigm"  '(gptel-menu      :which-key "gptel menu")))

;; --- ellama (Ollama local) ---
(use-package ellama
  :after general
  :commands (ellama-chat ellama-ask-about ellama-enhance-code)
  :config
  (require 'llm-ollama)
  (setq ellama-provider
        (make-llm-ollama :chat-model "mistral:latest" :embedding-model "nomic-embed-text"))
  (rata-leader
    :states '(normal visual)
    "aie"   '(:ignore t :which-key "ellama")
    "aiee"  '(ellama-chat         :which-key "ellama chat")
    "aiea"  '(ellama-ask-about    :which-key "ask about region")
    "aiec"  '(ellama-enhance-code :which-key "enhance code")))

;; --- aidermacs (Ollama local) ---
(use-package aidermacs
  :after general
  :commands (aidermacs-transient-menu aidermacs-open)
  :config
  (setq aidermacs-default-model "ollama_chat/deepseek-coder:latest")
  (rata-leader
    :states '(normal visual)
    "aia"   '(:ignore t :which-key "aider")
    "aiaa"  '(aidermacs-transient-menu :which-key "aider menu")
    "aiao"  '(aidermacs-open           :which-key "open aider")))

;; --- agent-shell (Claude Code via web login) ---
(use-package agent-shell
  :after general
  :custom
  (agent-shell-anthropic-claude-acp-command '("claude-code-acp"))
  :config
  (rata-leader
    :states '(normal visual)
    "aic"   '(:ignore t :which-key "claude")
    "aics"  '(agent-shell                             :which-key "agent shell")
    "aicc"  '(agent-shell-anthropic-start-claude-code  :which-key "claude code")))

(provide 'init-llm)
