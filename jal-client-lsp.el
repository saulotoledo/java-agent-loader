;;; jal-client-lsp.el --- LSP-Java integration for JAL -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/java-agent-loader

;;; Commentary:
;; This module provides integration between jal and lsp-java.

;;; Code:

(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)

(defvar lsp-java-vmargs)
(defvar lsp-after-initialize-hook)

;;;###autoload
(defun jal-lsp-java-setup (&optional agents)
  "Configures JAL for lsp-java with AGENTS list.
AGENTS is a list where each element is either:
- (ARTIFACT-ID . PROPS)
- (ARTIFACT-ID)

PROPS is a plist with keys :params and :jar-path.
User agents override known agents by artifact-id.
If AGENTS is nil, uses the default configuration.
This function should be called in the :init for lsp-java."
  (setq jal-agents-config (jal--merge-agent-configs (or agents '())))
  (setq lsp-java-vmargs (jal-get-vmargs-with-javaagents))
  (add-hook 'lsp-after-initialize-hook #'jal-find-and-configure-agents))

(provide 'jal-client-lsp)
;;; jal-client-lsp.el ends here
