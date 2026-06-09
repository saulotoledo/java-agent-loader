;;; jal-client-lsp.el --- LSP-Java integration for JAL -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; This module provides integration between JAL and lsp-java.

;;; Code:

(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)

(defvar lsp-java-vmargs)
(defvar lsp-java-java-path)
(defvar lsp-java-configuration-runtimes)
(defvar lsp-after-initialize-hook)

(defun jal--lsp-java-current-java-key ()
  "Return the java binary path configured for lsp-java.
Reads `lsp-java-java-path'; falls back to the first `java' on PATH
when it is unset or set to the bare string `java'."
  (let ((configured (and
                      (bound-and-true-p lsp-java-java-path)
                      (not (string= lsp-java-java-path "java"))
                      lsp-java-java-path)))
    (or configured (executable-find "java"))))

(defun jal--lsp-java-ls-command-advice (orig-fn &rest args)
  "Around advice for `lsp-java--ls-command' to inject JAL javaagent vmargs.
Dynamically extends `lsp-java-vmargs' with the javaagent arguments for the
current project, leaving the variable itself unchanged after the call.
ORIG-FN is the original function being advised.
&REST ARGS contains the arguments passed to the advised function."
  (let ((lsp-java-vmargs (append lsp-java-vmargs (jal-get-vmargs-with-javaagents))))
    (apply orig-fn args)))

(defun jal--lsp-java-restart ()
  "Restart lsp-java workspace if active."
  (when (and
          (bound-and-true-p lsp-mode)
          (fboundp 'lsp-workspace-restart)
          (fboundp 'lsp-workspaces))
    ;; Clear the session guard so the post-restart hook re-runs and picks up
    ;; the freshly written cache instead of skipping silently.
    (clrhash jal--configured-scopes)
    (dolist (workspace (lsp-workspaces))
      (lsp-workspace-restart workspace))))

(defvar jal--lsp-java-interface-warning-issued nil
  "Non-nil once JAL has already warned about a missing lsp-java interface.
Reset to nil on Emacs restart, so a warning is re-issued after a package
update that changes lsp-java's internal functions.")

(defun jal--lsp-java-check-interface ()
  "Warn if `lsp-java--ls-command' has disappeared since JAL was set up.
Runs on `lsp-after-initialize-hook' so a package update that removes or
renames the function is caught on the next server start.
Warns at most once per Emacs session to avoid repeat messages on restarts."
  (unless (or (fboundp 'lsp-java--ls-command)
            jal--lsp-java-interface-warning-issued)
    (setq jal--lsp-java-interface-warning-issued t)
    (jal--warn-interface-changed "lsp-java--ls-command" "lsp-java")))

;;;###autoload
(defun jal-lsp-java-setup ()
  "Configure JAL for lsp-java.
Merges `jal-additional-agents' with the known-agents registry and installs
an around advice on `lsp-java--ls-command' that dynamically appends the
javaagent vmargs for the current project on every JDTLS startup.
This function is called automatically when lsp-java is loaded."
  (setq jal-agents-config (jal--merge-agent-configs jal-additional-agents))
  (setq jal-current-java-key-function #'jal--lsp-java-current-java-key)
  (advice-add 'lsp-java--ls-command :around #'jal--lsp-java-ls-command-advice)
  (add-hook 'lsp-after-initialize-hook #'jal--lsp-java-check-interface)
  (add-hook 'lsp-after-initialize-hook #'jal-find-and-configure-agents)
  (add-hook 'jal-agents-detected-hook #'jal--lsp-java-restart))

(provide 'jal-client-lsp)
;;; jal-client-lsp.el ends here
