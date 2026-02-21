;;; -*- lexical-binding: t; -*-
;;; init-llm.el --- LLM integrations (gptel, ellama, aidermacs)

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
    :states '(normal visual insert emacs)
    "ai"   '(:ignore t :which-key "AI")
    "aig"  '(gptel           :which-key "gptel chat")
    "ais"  '(gptel-send      :which-key "send to gptel")
    "air"  '(gptel-rewrite   :which-key "rewrite with gptel")
    "aim"  '(gptel-menu      :which-key "gptel menu")))

;; --- ellama (Ollama local) ---
(use-package ellama
  :after general
  :config
  (require 'llm-ollama)
  (setq ellama-provider
        (make-llm-ollama :chat-model "mistral:latest" :embedding-model "nomic-embed-text"))
  (rata-leader
    :states '(normal visual insert emacs)
    "aic"  '(ellama-chat         :which-key "ellama chat")
    "aik"  '(ellama-ask-about    :which-key "ask about region")
    "aie"  '(ellama-enhance-code :which-key "enhance code")))

;; --- aidermacs (Anthropic Claude) ---
(use-package aidermacs
  :after general
  :config
  (setq aidermacs-default-model "claude-sonnet-4-5")
  (rata-leader
    :states '(normal visual insert emacs)
    "aiA"  '(aidermacs-transient-menu :which-key "aider menu")
    "aio"  '(aidermacs-open           :which-key "open aider")))

(provide 'init-llm)
