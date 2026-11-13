;;; jal-client-lsp.el --- lsp-mode integration for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

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

;; Integrate JAL with local JDTLS stdio clients in lsp-mode. The same startup
;; path handles user-registered clients and clients supplied by lsp-java.

;;; Code:

(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)
(require 'jal-client-common)

(declare-function lsp--client-server-id "lsp-mode" (client))
(declare-function lsp--workspace-server-id "lsp-mode" (workspace))
(declare-function lsp--workspace-root "lsp-mode" (workspace))
(declare-function lsp--workspace-buffers "lsp-mode" (workspace))
(declare-function lsp-resolve-value "lsp-mode" (value))
(declare-function lsp-workspaces "lsp-mode" ())
(declare-function lsp-session "lsp-mode" ())
(declare-function lsp--session-workspaces "lsp-mode" (session))
(declare-function lsp-workspace-restart "lsp-mode" (workspace))

(defvar jal-lsp-java-mode)
(defvar lsp-after-initialize-hook)
(defvar lsp--cur-workspace)
(defvar jal--lsp-start-buffer nil
  "File buffer for the dynamically scoped JDTLS startup, or nil.")
(defvar jal--lsp-supported-start nil
  "Non-nil when this startup resolved a supported launcher.")
(defvar jal--lsp-start-java nil
  "Launcher JVM resolved during the dynamically scoped JDTLS startup.")
(defvar jal--lsp-workspace-contexts (make-hash-table :test 'eq :weakness 'key)
  "Map started JDTLS workspaces to their initiating buffer and directory.")
(defvar jal--lsp-workspace-java (make-hash-table :test 'eq :weakness 'key)
  "Map started JDTLS workspaces to their launcher JVM.")

(defun jal--lsp-start-workspace-advice (orig-fn session client root &rest args)
  "Call ORIG-FN with SESSION, CLIENT, ROOT and ARGS in a scoped startup.
Only local JDTLS clients may inject agents."
  (let* ((jal--lsp-start-buffer
           (and (memq (lsp--client-server-id client) jal-lsp-server-ids)
             (not (file-remote-p root))
             buffer-file-name (current-buffer)))
          (jal--lsp-supported-start nil)
          (jal--lsp-start-java nil)
          (directory default-directory)
          (workspace (apply orig-fn session client root args)))
    (when (and jal--lsp-supported-start (buffer-live-p jal--lsp-start-buffer))
      (puthash workspace (cons jal--lsp-start-buffer directory)
        jal--lsp-workspace-contexts)
      (puthash workspace jal--lsp-start-java jal--lsp-workspace-java))
    workspace))

(defun jal--lsp-resolve-command-advice (orig-fn command &optional test?)
  "Resolve COMMAND using ORIG-FN, injecting only during a scoped startup.
Executable probes with TEST? set are left unchanged."
  (if (or test? (not (buffer-live-p jal--lsp-start-buffer))
        (file-remote-p default-directory))
    (funcall orig-fn command test?)
    (let* ((resolved
            (funcall orig-fn
                     (lambda ()
                       (let ((value (lsp-resolve-value command)))
                         ;; Own the list: lsp-mode removes nils destructively.
                         (if (consp value) (copy-sequence value) value)))
                     test?))
           (kind (jal--client-command-kind resolved)))
      ;; Remote commands were excluded above, so resolution leaves a plain
      ;; argument list. Let lsp-mode handle validation and normalization.
      (with-current-buffer jal--lsp-start-buffer
        ;; The JVM is selected from Emacs's environment, not the client's
        ;; `:environment-fn', which lsp-mode applies later and per transport.
        (setq jal--lsp-start-java (jal--client-command-java resolved kind))
        (setq jal--client-java jal--lsp-start-java)
        (when kind (setq jal--lsp-supported-start t))
        (if kind
            (jal--client-inject-vmargs
             resolved kind (jal-get-vmargs-with-javaagents))
          resolved)))))

(defun jal--lsp-jdtls-workspace-p (workspace)
  "Return non-nil for a local JDTLS WORKSPACE."
  (and (fboundp 'lsp--workspace-server-id)
    (memq (lsp--workspace-server-id workspace) jal-lsp-server-ids)
    (not (file-remote-p (lsp--workspace-root workspace)))))

(defun jal--lsp-java-workspaces ()
  "Return local JDTLS workspaces, falling back to the session list."
  (let ((candidates (or (and (fboundp 'lsp-workspaces) (lsp-workspaces))
                      (and (fboundp 'lsp-session)
                        (fboundp 'lsp--session-workspaces)
                        (lsp--session-workspaces (lsp-session)))))
         (result nil))
    (dolist (workspace candidates (nreverse result))
      (when (jal--lsp-jdtls-workspace-p workspace) (push workspace result)))))

(defun jal--lsp-current-java ()
  "Return the launcher JVM of the JDTLS workspace serving this buffer.
Prefers the workspaces attached to the buffer, so a restarted server wins.
Falls back to the buffer's own selection, as set when a startup resolves."
  (if (buffer-live-p jal--lsp-start-buffer)
    ;; A startup in progress wins over workspaces attached to this buffer.
    jal--lsp-start-java
    (or (let ((found nil))
          (dolist (workspace (and (fboundp 'lsp-workspaces) (lsp-workspaces)))
            (unless found
              (setq found (and (jal--lsp-jdtls-workspace-p workspace)
                            (gethash workspace jal--lsp-workspace-java)))))
          found)
      (jal--client-current-java))))

(defun jal--lsp-java-restart ()
  "Capture JDTLS workspaces now and defer their restart."
  (let ((workspaces (jal--lsp-java-workspaces)))
    (when workspaces
      (jal--defer #'jal--lsp-java-restart-now workspaces))))

(defun jal--lsp-java-restart-now (workspaces)
  "Restart captured WORKSPACES and clear the session scope guard."
  (when (and jal-lsp-java-mode (fboundp 'lsp-workspace-restart))
    (let ((targets nil))
      (dolist (workspace workspaces)
        (when (jal--lsp-jdtls-workspace-p workspace) (push workspace targets)))
      (when targets
        (clrhash jal--configured-scopes)
        (dolist (workspace (nreverse targets))
          (lsp-workspace-restart workspace))))))

(defvar jal--lsp-java-interface-warning-issued nil
  "Non-nil once JAL has warned about a missing lsp-mode startup interface.")

(defun jal--lsp-java-check-interface ()
  "Warn once if either advised lsp-mode startup interface is missing."
  (unless jal--lsp-java-interface-warning-issued
    (let ((missing nil))
      (dolist (fn '(lsp--start-workspace lsp-resolve-final-command))
        (unless (fboundp fn) (push (symbol-name fn) missing)))
      (when missing
        (setq jal--lsp-java-interface-warning-issued t)
        (jal--warn-interface-changed (mapconcat #'identity (nreverse missing) ", ")
          "lsp-mode")))))

(defun jal--lsp-after-initialize-find-agents ()
  "Defer discovery in the file buffer captured for this JDTLS workspace."
  (let* ((workspace (and (boundp 'lsp--cur-workspace) lsp--cur-workspace))
          (context (and workspace (gethash workspace jal--lsp-workspace-contexts)))
          (buffer (and context
                    (if (buffer-live-p (car context))
                      (car context)
                      ;; Initiating buffer was killed: use any live file buffer.
                      (seq-find (lambda (b) (and (buffer-live-p b) (buffer-file-name b)))
                        (and (fboundp 'lsp--workspace-buffers)
                          (lsp--workspace-buffers workspace)))))))
    (when (and buffer (jal--lsp-jdtls-workspace-p workspace))
      (progn
        (jal--defer-in-buffer
          buffer (if (eq buffer (car context)) (cdr context)
                   (buffer-local-value 'default-directory buffer))
          (lambda ()
            (when (and jal-lsp-java-mode (buffer-live-p buffer))
              ;; Fix the initializing workspace's JVM for this operation. The
              ;; detection captures it for its asynchronous cache writes.
              (let* ((java (gethash workspace jal--lsp-workspace-java))
                      (jal--java-key-override (and java (file-truename java))))
                (jal-find-and-configure-agents)))))))))

;;;###autoload
(define-minor-mode jal-lsp-java-mode
  "Toggle JAL integration with JDTLS in lsp-mode (a global mode).
Enable once before starting Java servers. Works with user-registered
JDTLS stdio clients and lsp-java, using the same command injection path.
Users supply Java, JDTLS and client registration; JAL discovers agents
and injects their JVM arguments automatically. Disabling removes JAL's
advice and hooks."
  :global t
  :group 'jal
  (if jal-lsp-java-mode
    (progn
      (setq jal-agents-config (jal--merge-agent-configs jal-additional-agents))
      (setq jal-current-java-key-function #'jal--lsp-current-java)
      (advice-add 'lsp--start-workspace :around #'jal--lsp-start-workspace-advice)
      (advice-add 'lsp-resolve-final-command :around #'jal--lsp-resolve-command-advice)
      (add-hook 'lsp-after-initialize-hook #'jal--lsp-java-check-interface)
      (add-hook 'lsp-after-initialize-hook #'jal--lsp-after-initialize-find-agents)
      (add-hook 'jal-agents-detected-hook #'jal--lsp-java-restart)
      (setq jal--lsp-java-interface-warning-issued nil))
    (advice-remove 'lsp--start-workspace #'jal--lsp-start-workspace-advice)
    (advice-remove 'lsp-resolve-final-command #'jal--lsp-resolve-command-advice)
    (remove-hook 'lsp-after-initialize-hook #'jal--lsp-java-check-interface)
    (remove-hook 'lsp-after-initialize-hook #'jal--lsp-after-initialize-find-agents)
    (remove-hook 'jal-agents-detected-hook #'jal--lsp-java-restart)
    (clrhash jal--lsp-workspace-contexts)
    (clrhash jal--lsp-workspace-java)
    (jal--client-clear-java)
    (when (eq jal-current-java-key-function #'jal--lsp-current-java)
      (setq jal-current-java-key-function nil))))

(provide 'jal-client-lsp)
;;; jal-client-lsp.el ends here
