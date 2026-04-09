;;; jal-utils.el --- Utilities for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; Utility functions for jal.

;;; Code:

(require 'jal-vars)
(require 'jal-known-agents)
(require 'project)
(require 'format-spec)

(declare-function jal--detect-build-system "jal")

(defun jal--warn-interface-changed (fn-name package-name)
  "Warn that FN-NAME from PACKAGE-NAME is missing, suggesting to file an issue."
  (let ((msg (format (concat "JAL: `%s' is not defined. "
                             "%s may have changed its internal interface. "
                             "JAL will not inject javaagent arguments into JDTLS. "
                             "Please file an issue at "
                             "https://github.com/saulotoledo/java-agent-loader "
                             "including your %s package version.")
                     fn-name package-name package-name)))
    (display-warning 'jal msg :warning)))

(defun jal--current-java-key ()
  "Return a canonical key identifying the currently active JVM.
Calls `jal-current-java-key-function' (set by the active client module)
to obtain the raw java binary path, then resolves it through all symlinks
so the key is stable regardless of how Java was invoked.  Falls back to
the first `java' found on PATH when no client function is registered.
This key is used to scope per-JVM entries inside the project cache file."
  (let* ((java-bin (if jal-current-java-key-function
                       (funcall jal-current-java-key-function)
                     (executable-find "java")))
         (resolved (and java-bin (file-truename java-bin))))
    (or resolved java-bin "java")))

(defun jal--config-scoped-p (config)
  "Return non-nil when CONFIG uses the scoped (per-JVM) format.
In the scoped format the top-level alist is keyed by the resolved java
binary path and each value is the list of agent entries for that JVM.
In the legacy flat format the top-level list is the agent entries
directly, so `(cadr (car config))' is a string (the JAR path)."
  (and (consp config)
       (consp (car config))
       (listp (cadr (car config)))))

(defun jal--merge-agent-configs (user-agents)
  "Merges USER-AGENTS with known agents, returning the merged list.
User properties override known properties by artifact-id."
  (let ((merged-agents (copy-sequence jal-known-agents)))
    (dolist (user-agent user-agents)
      (let* ((agent-id (if (consp user-agent) (car user-agent) user-agent))
             (user-props (and (consp user-agent) (cdr user-agent)))
             (existing (assoc agent-id merged-agents)))
        (if existing
            ;; Merge properties: user props override known props
            (when user-props
              (let ((known-props (cdr existing)))
                (setcdr existing (append user-props known-props))))
          ;; New agent: add as-is
          (setq merged-agents (append merged-agents (list user-agent))))))
    merged-agents))

(defun jal--get-cache-file (project-root)
  "Return the path to the project-local cache file for PROJECT-ROOT."
  (expand-file-name jal-project-cache-filename project-root))

(defun jal--read-project-config (project-root)
  "Read the project configuration from the local cache file for PROJECT-ROOT."
  (let ((cache-file (jal--get-cache-file project-root)))
    (if (file-exists-p cache-file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents cache-file)
              (goto-char (point-min))
              (read (current-buffer)))
          (error
           (warn "JAL: Failed to read config file (%s). Error: %S" cache-file err)
           nil))
      nil)))

(defun jal--write-project-config (project-root config)
  "Write the CONFIG list to the PROJECT-ROOT's local cache file."
  (let ((cache-file (jal--get-cache-file project-root)))
    (with-temp-file cache-file
      (let ((print-level nil)
            (print-length nil))
        (pp config (current-buffer))))
    (message "JAL: Configuration cached to %s." cache-file)))

(defun jal--cache-agent-config (agent-id path version params)
  "Cache AGENT-ID's config (PATH, VERSION, PARAMS) scoped to the current JVM.
The entry is stored under the resolved java binary path so each JVM
version maintains an independent set of agents in the project cache file."
  (let* ((project (project-current))
         (project-root (and project (file-name-as-directory (project-root project)))))
    (when project-root
      (let* ((java-key (jal--current-java-key))
             (full-config (jal--read-project-config project-root))
             ;; Discard legacy flat-format data — it will be re-detected.
             (full-config (if (jal--config-scoped-p full-config) full-config '()))
             ;; Retrieve or create the agent list for this JVM.
             (scope-agents (copy-sequence
                            (or (cadr (assoc java-key full-config)) '())))
             (new-agent-entry (list agent-id path params version))
             ;; Replace the existing entry for this agent-id within the scope.
             (updated-scope (cons new-agent-entry
                                  (delq (assoc agent-id scope-agents) scope-agents)))
             ;; Replace the scope entry in the top-level config.
             (updated-config (cons (list java-key updated-scope)
                                   (assoc-delete-all java-key full-config))))
        (jal--write-project-config project-root updated-config)
        (message "JAL: Agent '%s' v%s cached for Java at '%s'."
                 agent-id version java-key)))))

(defun jal--check-executable (program error-message)
  "Check if PROGRAM is executable on the system path. Throws ERROR-MESSAGE if not."
  (unless (executable-find program)
    (error error-message)))

(defun jal--resolve-agent-path (repo-path group-id artifact-id version)
  "Resolve path to agent JAR using REPO-PATH, GROUP-ID, ARTIFACT-ID and VERSION.
Returns the path if found, otherwise returns nil and warns."
  (let* ((config (cdr (assoc artifact-id jal-agents-config)))
         (jar-pattern (or (plist-get config :jar-path) "%a-%v.jar"))
         ;; Replace placeholders
         (jar-path (format-spec jar-pattern
                                `((?a . ,artifact-id)
                                  (?v . ,version)
                                  (?g . ,group-id))))
         (agent-path (if (string-prefix-p "/" jar-path)
                         ;; Absolute path - use as-is
                         jar-path
                       ;; Relative path - prepend repo-path
                       (concat repo-path "/" jar-path))))

    (if (file-exists-p agent-path)
        agent-path
      ;; Warning message depends on path type
      (if (string-prefix-p "/" jar-path)
          (warn "Agent JAR (v%s) not found at absolute path: %s" version agent-path)
        ;; Detect build system for helpful message
        (let* ((project (and (fboundp 'project-current) (project-current)))
               (project-root (and project (project-root project)))
               (build-system-sym (and project-root (jal--detect-build-system project-root)))
               (build-system-install-cmd (pcase build-system-sym
                                           ('maven "mvn clean install")
                                           ('gradle "gradle clean build")
                                           (_ "maven/gradle"))))
          (warn "Agent JAR (v%s) not found at: %s. Check '%s' to build it." version agent-path build-system-install-cmd)))
      nil)))

(defun jal--load-agent-configs-from-project ()
  "Read agent configurations for the current JVM from the project cache.
Returns the list of agent entries scoped to the active Java binary, or
nil when no entry exists for this JVM (which triggers re-detection).
Legacy flat-format configs are treated as missing so they are re-detected
in the new scoped format."
  (let* ((project (and (fboundp 'project-current) (project-current)))
         (project-root (and project (file-name-as-directory (project-root project)))))
    (when project-root
      (let* ((full-config (jal--read-project-config project-root))
             (java-key (jal--current-java-key)))
        (when (jal--config-scoped-p full-config)
          (cadr (assoc java-key full-config)))))))

(provide 'jal-utils)
;;; jal-utils.el ends here
