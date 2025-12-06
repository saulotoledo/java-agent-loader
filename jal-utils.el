;;; jal-utils.el --- Utilities for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/jal

;;; Commentary:
;; Utility functions for jal.

;;; Code:

(require 'jal-vars)
(require 'jal-known-agents)
(require 'project)
(require 'format-spec)

(declare-function jal--detect-build-system "jal")

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
  "Cache the AGENT-ID's config containing PATH, VERSION and PARAMS.
The cache is saved on the current project's local cache file."
  (let* ((project (project-current))
         (project-root (and project (file-name-as-directory (project-root project)))))
    (when project-root
      (let* ((current-config (or (jal--read-project-config project-root) '()))
             (new-agent-entry (list agent-id path params version))
             (updated-config (cons new-agent-entry (delq (assoc agent-id current-config) current-config))))

        (jal--write-project-config project-root updated-config)
        (message "Agent '%s' v%s cached for project." agent-id version)))))

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
  "Read agent configurations from the project-local cache file."
  (let* ((project (and (fboundp 'project-current) (project-current)))
         (project-root (and project (file-name-as-directory (project-root project)))))
    (when project-root
      (jal--read-project-config project-root))))

(provide 'jal-utils)
;;; jal-utils.el ends here
