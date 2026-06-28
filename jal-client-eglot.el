;;; jal-client-eglot.el --- eglot-java integration for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

;; This program is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.

;; This program is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License along with
;; this program. If not, see <https://www.gnu.org/licenses/>.

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:

;; This module provides integration between Java Agent Loader (JAL) and
;; `eglot-java'. It installs an around advice on
;; `eglot-java--eclipse-jdt-contact' that dynamically extends
;; `eglot-java-eclipse-jdt-args' with the javaagent arguments for the current
;; project on every JDTLS startup.

;;; Code:

(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)

(defvar eglot-java-eclipse-jdt-args)

(defun jal--eglot-java-contact-advice (orig-fn &rest args)
  "Around advice for `eglot-java--eclipse-jdt-contact' to inject JAL vmargs.
Dynamically extends `eglot-java-eclipse-jdt-args' with the javaagent
arguments for the current project, leaving the variable itself unchanged.
ORIG-FN is the original function being advised.
&REST ARGS contains the arguments passed to the advised function."
  (let ((eglot-java-eclipse-jdt-args
          (append eglot-java-eclipse-jdt-args (jal-get-vmargs-with-javaagents))))
    (apply orig-fn args)))

(defun jal--eglot-current-java-key ()
  "Return the java binary path active for the current eglot-java session.
Uses `eglot-java--find-java-program-from-alternatives' when available,
falling back to the first `java' on PATH."
  (if (fboundp 'eglot-java--find-java-program-from-alternatives)
    (condition-case nil
      (eglot-java--find-java-program-from-alternatives)
      (error (executable-find "java")))
    (executable-find "java")))

(defun jal--eglot-reconnect ()
  "Reconnect eglot if active."
  (when (and (bound-and-true-p eglot-managed-mode)
          (fboundp 'eglot-reconnect)
          (fboundp 'eglot-current-server))
    (let ((server (eglot-current-server)))
      (when server
        ;; Clear the session guard so the post-reconnect hook re-runs and picks
        ;; up the freshly written cache instead of skipping silently.
        (clrhash jal--configured-scopes)
        (eglot-reconnect server)))))

(defvar jal--eglot-java-interface-warning-issued nil
  "Non-nil once JAL has already warned about a missing eglot-java interface.
Reset to nil on Emacs restart, so a warning is re-issued after a package
update that changes eglot-java's internal functions.")

(defun jal--eglot-java-check-interface ()
  "Warn if `eglot-java--eclipse-jdt-contact' has disappeared since JAL was set up.
Runs on `eglot-connect-hook' so a package update that removes or renames
the function is caught on the next server connection.
Warns at most once per Emacs session to avoid repeat messages on reconnects."
  (unless (or (fboundp 'eglot-java--eclipse-jdt-contact)
            jal--eglot-java-interface-warning-issued)
    (setq jal--eglot-java-interface-warning-issued t)
    (jal--warn-interface-changed "eglot-java--eclipse-jdt-contact" "eglot-java")))

(defun jal--eglot-connect-hook-check-interface (_server)
  "Hook wrapper: call `jal--eglot-java-check-interface' from `eglot-connect-hook'.
Accepts the SERVER argument passed by the hook."
  (jal--eglot-java-check-interface))

(defun jal--eglot-connect-hook-find-agents (_server)
  "Hook wrapper: call `jal-find-and-configure-agents' from `eglot-connect-hook'.
Accepts the SERVER argument passed by the hook."
  (jal-find-and-configure-agents))

;;;###autoload
(defun jal-eglot-java-setup ()
  "Configure JAL for eglot-java.
Merges `jal-additional-agents' with the known-agents registry and installs
an around advice on `eglot-java--eclipse-jdt-contact' that dynamically
appends the javaagent vmargs for the current project on every JDTLS startup.
This function is called automatically when eglot-java is loaded."
  (setq jal-agents-config (jal--merge-agent-configs jal-additional-agents))
  (setq jal-current-java-key-function #'jal--eglot-current-java-key)
  (advice-add 'eglot-java--eclipse-jdt-contact :around #'jal--eglot-java-contact-advice)
  (add-hook 'eglot-connect-hook #'jal--eglot-connect-hook-check-interface)
  (add-hook 'eglot-connect-hook #'jal--eglot-connect-hook-find-agents)
  (add-hook 'jal-agents-detected-hook #'jal--eglot-reconnect)
  (setq jal--eglot-java-interface-warning-issued nil))

(provide 'jal-client-eglot)
;;; jal-client-eglot.el ends here
