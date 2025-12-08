;;; jal-client-eglot.el --- Eglot integration for JAL -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/java-agent-loader

;;; Commentary:
;; This module provides integration between jal and Eglot.

;;; Code:

(require 'eglot)
(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)

(defun jal--eglot-contact (original-contact)
  "Return the contact for Eglot, injecting java agents.
ORIGINAL-CONTACT is the original contact entry from `eglot-server-programs'."
  (let ((contact (if (functionp original-contact)
                     (funcall original-contact)
                   original-contact)))
    (if (listp contact)
        (append contact (jal-get-vmargs-with-javaagents))
      contact)))

(defun jal-eglot-java-setup (&optional agents)
  "Configures JAL for eglot with AGENTS list.
AGENTS is a list where each element is either:
- (ARTIFACT-ID . PROPS)
- (ARTIFACT-ID)

PROPS is a plist with keys :params and :jar-path.
User agents override known agents by artifact-id.
If AGENTS is nil, uses the default configuration.
This function should be called in the :init section for eglot."
  (when agents
    (setq jal-agents-config (jal--merge-agent-configs agents)))
  (add-hook 'eglot-connect-hook #'jal-find-and-configure-agents)
  (let ((entry (assoc '(java-mode jdtls-mode) eglot-server-programs)))
    (unless entry
      (setq entry (assoc 'java-mode eglot-server-programs)))

    (when entry
      (let ((original-contact (cdr entry)))
        (setcdr entry (lambda (&rest _args) (jal--eglot-contact original-contact)))))))

(provide 'jal-client-eglot)
;;; jal-client-eglot.el ends here
