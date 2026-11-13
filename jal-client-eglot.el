;;; jal-client-eglot.el --- Eglot integration for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

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

;; Integrate JAL directly with Eglot's resolved Java server contacts.
;; Plain Eglot and eglot-java use the same agent injection path.

;;; Code:

(require 'jal)
(require 'jal-vars)
(require 'jal-known-agents)
(require 'jal-client-common)

(declare-function eglot--project "eglot" (server))
(declare-function eglot-current-server "eglot" ())
(declare-function eglot--managed-buffers "eglot" (server))
(declare-function eglot-shutdown "eglot" (server &optional interactive timeout preserve-buffers))
(declare-function eglot "eglot" (managed-major-modes project class contact language-ids &optional interactive))

(defvar jal-eglot-java-mode)
(defvar eglot-java-eclipse-jdt-args)
(defvar eglot-connect-hook)
(defvar jal--eglot-project-contexts (make-hash-table :test 'equal :weakness 'key)
  "Map Java server projects to their initiating file buffer and directory.")

(defvar jal--eglot-project-java (make-hash-table :test 'equal :weakness 'key)
  "Map Java server projects to their launcher JVM.")
(defvar jal--eglot-start-buffer nil
  "File buffer for the dynamically scoped Java server startup, or nil.")
(defvar jal--eglot-start-java nil
  "Launcher JVM resolved during the dynamically scoped startup.")

(defun jal--eglot-java-contact-p (result)
  "Return non-nil when resolved contact RESULT represents a Java server."
  (let ((modes (nth 0 result)) (languages (nth 4 result)))
    (or (and (listp modes)
          (or (memq 'java-mode modes) (memq 'java-ts-mode modes)))
      (and (listp languages) (member "java" languages)))))

(defvar jal--eglot-unsupported-reasons nil
  "Reasons already reported for skipped Java contacts in this session.")

(defun jal--eglot-note-unsupported (reason)
  "Tell the user once per session that a Java contact was skipped for REASON."
  (unless (member reason jal--eglot-unsupported-reasons)
    (push reason jal--eglot-unsupported-reasons)
    (message "JAL: Eglot Java server not supported for agent injection (%s). Agents not injected."
      reason)))

(defun jal--eglot-launch-directory (project)
  "Return the directory Eglot launches PROJECT's server from."
  (file-name-as-directory (project-root project)))

(defun jal--eglot-guess-contact-advice (orig-fn &rest args)
  "Call ORIG-FN with ARGS and inject agents into a supported Java contact.
`eglot-java' builds its command with `nconc', which extends its argument
list in place. ORIG-FN therefore sees a copy of that list."
  (let ((result (if (boundp 'eglot-java-eclipse-jdt-args)
                  (let ((eglot-java-eclipse-jdt-args
                          (copy-sequence eglot-java-eclipse-jdt-args)))
                    (apply orig-fn args))
                  (apply orig-fn args))))
    (when (and (proper-list-p result) (>= (length result) 5)
            (jal--eglot-java-contact-p result))
      (let ((project (nth 1 result)) (contact (nth 3 result)))
        (remhash project jal--eglot-project-contexts)
        (remhash project jal--eglot-project-java)
        (when buffer-file-name (setq jal--client-java nil))
        (cond
          ((not buffer-file-name))
          ((or (file-remote-p (project-root project))
             (file-remote-p default-directory))
            (jal--eglot-note-unsupported "remote project"))
          ((not (and (proper-list-p contact) (stringp (car contact))))
            (jal--eglot-note-unsupported "contact is not a command list"))
          ((memq :autoport contact)
            (jal--eglot-note-unsupported ":autoport socket transport; only stdio is supported"))
          (t
            (let ((tail contact) (command nil))
              ;; Eglot appends keyword initargs after the executable arguments.
              (while (and tail (not (keywordp (car tail))))
                (push (pop tail) command))
              (setq command (nreverse command))
              (let ((kind (jal--client-command-kind command)))
                (if (not kind)
                  (jal--eglot-note-unsupported
                    "launcher is neither jdtls nor java -jar")
                  (setq jal--client-java
                    (jal--client-command-java
                      command kind (jal--eglot-launch-directory project)))
                  (puthash project (cons (current-buffer) default-directory)
                    jal--eglot-project-contexts)
                  (puthash project jal--client-java jal--eglot-project-java)
                  (let ((vmargs (let ((jal--eglot-start-buffer (current-buffer))
                                       (jal--eglot-start-java jal--client-java))
                                  (jal-get-vmargs-with-javaagents))))
                    (when vmargs
                      (setq result (copy-sequence result))
                      (setf (nth 3 result)
                        (append (jal--client-inject-vmargs
                                  command kind vmargs
                                  (jal--eglot-launch-directory project))
                          tail)))))))))))
    result))

(defun jal--eglot-current-java ()
  "Return the launcher JVM of the Java server serving this buffer.
A startup in progress wins, then the server attached to the buffer, so a
restarted server beats a stale selection. The buffer's own selection is the
last resort."
  (if (buffer-live-p jal--eglot-start-buffer)
    jal--eglot-start-java
    (or (let ((server (and (fboundp 'eglot-current-server)
                        (fboundp 'eglot--project)
                        (eglot-current-server))))
          (and server (gethash (eglot--project server) jal--eglot-project-java)))
      (jal--client-current-java))))

(defun jal--eglot-reconnect ()
  "Defer a fresh Eglot launch in the file buffer captured for this project.
Falls back to the current file buffer when the initiating buffer was killed."
  (let* ((context (gethash (project-current) jal--eglot-project-contexts))
          (buffer (cond ((and context (buffer-live-p (car context))) (car context))
                    (context (and buffer-file-name (current-buffer))))))
    (when buffer
      (jal--defer #'jal--eglot-reconnect-in-buffer buffer))))

(defun jal--eglot-reconnect-in-buffer (buffer)
  "Shut down and relaunch Eglot in BUFFER with freshly resolved arguments."
  (when (and jal-eglot-java-mode (buffer-live-p buffer)
          (fboundp 'eglot-current-server) (fboundp 'eglot-shutdown)
          (fboundp 'eglot))
    (with-current-buffer buffer
      (clrhash jal--configured-scopes)
      (let ((server (eglot-current-server)))
        (when server
          (condition-case err
            (eglot-shutdown server nil nil 'preserve-buffers)
            (error (message "JAL: Eglot shutdown failed: %s"
                     (error-message-string err))))))
      ;; eglot-reconnect would reuse saved arguments rather than re-read agents.
      (call-interactively #'eglot))))

(defvar jal--eglot-java-interface-warning-issued nil
  "Non-nil once JAL has warned about a missing Eglot startup interface.")

(defun jal--eglot-java-check-interface (&optional _server)
  "Warn once if Eglot's advised contact resolver is missing.
_SERVER is ignored when called from `eglot-connect-hook'."
  (unless (or (fboundp 'eglot--guess-contact)
            jal--eglot-java-interface-warning-issued)
    (setq jal--eglot-java-interface-warning-issued t)
    (jal--warn-interface-changed "eglot--guess-contact" "eglot")))

(defun jal--eglot-connect-hook-find-agents (server)
  "Defer agent discovery in the file buffer captured for SERVER's project."
  (let* ((project (eglot--project server))
          (context (gethash project jal--eglot-project-contexts))
          (buffer (and context
                    (if (buffer-live-p (car context))
                      (car context)
                      ;; Initiating buffer was killed: use any live file buffer.
                      (seq-find (lambda (b) (and (buffer-live-p b) (buffer-file-name b)))
                        (and (fboundp 'eglot--managed-buffers)
                          (eglot--managed-buffers server)))))))
    (when buffer
      (jal--client-defer-find-agents
        buffer (if (eq buffer (car context)) (cdr context)
                 (buffer-local-value 'default-directory buffer))
        'jal-eglot-java-mode
        (gethash project jal--eglot-project-java)))))

;;;###autoload
(define-minor-mode jal-eglot-java-mode
  "Toggle JAL integration with Java servers in Eglot (a global mode).
Enable once before starting Java servers. Works with plain Eglot and
eglot-java through the same resolved-command adapter. Users supply Java,
JDTLS and server configuration; JAL discovers and injects agents.
Disabling removes JAL's advice, hooks and captured Java state."
  :global t
  :group 'jal
  (if jal-eglot-java-mode
    (progn
      (setq jal-agents-config (jal--merge-agent-configs jal-additional-agents))
      (setq jal-current-java-key-function #'jal--eglot-current-java)
      (advice-add 'eglot--guess-contact :around #'jal--eglot-guess-contact-advice)
      (add-hook 'eglot-connect-hook #'jal--eglot-java-check-interface)
      (add-hook 'eglot-connect-hook #'jal--eglot-connect-hook-find-agents)
      (add-hook 'jal-agents-detected-hook #'jal--eglot-reconnect)
      (setq jal--eglot-java-interface-warning-issued nil
        jal--eglot-unsupported-reasons nil))
    (advice-remove 'eglot--guess-contact #'jal--eglot-guess-contact-advice)
    (remove-hook 'eglot-connect-hook #'jal--eglot-java-check-interface)
    (remove-hook 'eglot-connect-hook #'jal--eglot-connect-hook-find-agents)
    (remove-hook 'jal-agents-detected-hook #'jal--eglot-reconnect)
    (clrhash jal--eglot-project-contexts)
    (clrhash jal--eglot-project-java)
    (setq jal--eglot-unsupported-reasons nil)
    (jal--client-clear-java)
    (when (eq jal-current-java-key-function #'jal--eglot-current-java)
      (setq jal-current-java-key-function nil))))

(provide 'jal-client-eglot)
;;; jal-client-eglot.el ends here
