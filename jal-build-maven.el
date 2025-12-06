;;; jal-build-maven.el --- Maven detection for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/java-agent-loader

;;; Commentary:
;; Maven detection logic for jal.

;;; Code:

(require 'jal-utils)

(defun jal--maven-extract-agent-dependency-info (mvn-output agent-id)
  "Extract the maven agent AGENT-ID from MVN-OUTPUT.
Returns nil if the artifact is not found."

  (let* (
         (agent-line-filtering-regex (concat ":" (regexp-quote agent-id) ":"))
         (raw-agent-line (car (seq-filter (lambda (line) (string-match agent-line-filtering-regex line))
                                          (split-string mvn-output "\n" t)))))

    (if raw-agent-line
        (let* (
               (tabs-to-spaces (replace-regexp-in-string "\t" " " raw-agent-line))
               (single-space-line (replace-regexp-in-string " +" " " tabs-to-spaces))
               (tokens (split-string single-space-line " " t))
               (mvn-agent-info (car (seq-filter (lambda (token) (string-match ":" token)) tokens))))
          mvn-agent-info)

      nil)))

(defun jal--maven-run-command (cmd context-id)
  "Return the output of CMD as a string, using CONTEXT-ID to identify it.
Returns nil on failure, while logging the error using context-id."

  (let ((mvn-output nil))
    (condition-case err
        (setq mvn-output (with-output-to-string
                           (call-process-shell-command cmd nil standard-output nil)))
      (error
       (warn "JAL Maven Error: Failed to execute command for %s. Error: %S" context-id err)
       (setq mvn-output nil)))

    mvn-output))

(defun jal--maven-extract-version (coordinate-string)
  "Extract the version string from the Maven COORDINATE-STRING.
Handles G:A:V (3), G:A:P:V:S (5), and G:A:P:C:V:S (6) formats."
  (when coordinate-string
    (let* ((trimmed-string (string-trim coordinate-string))
           (components (split-string trimmed-string ":"))
           (count (length components)))
      (cond
       ;; Full G:A:P:C:V:S string (6 components)
       ((= count 6)
        (nth 4 components)) ; Version is the 5th element (index 4)

       ;; G:A:P:V:S string (5 components)
       ((= count 5)
        (nth 3 components))

       ;; Simple G:A:V string (3 components)
       ((= count 3)
        (nth 2 components))

       ;; Default case or error handling
       (t
        (error "Unexpected Maven coordinate format with %d components: %s"
               count
               coordinate-string))))))

(defun jal--maven-detect-agents (project-root agents-list)
  "Run Maven detection for AGENTS-LIST on PROJECT-ROOT.
Returns list of (agent-id path version)."
  (jal--check-executable "mvn" "JAL: Maven executable not found in your PATH")

  (let ((default-directory (or project-root default-directory))
        (found-agents '()))
    (message "JAL: Running Maven dependency analysis for %s agents..." (length agents-list))

    (let* ((mvn-repo-cmd "mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>/dev/null")
           (repo-path (jal--maven-run-command mvn-repo-cmd "local-repo-lookup")))

      (if (or (null repo-path) (string-empty-p repo-path))
          (progn
            (warn "Maven local repository path not found via 'settings.localRepository'. Cannot proceed.")
            nil)

        (let* ((all-agent-ids (mapconcat #'identity agents-list ","))
               (mvn-list-cmd (format "mvn dependency:list -DincludeArtifactIds=%s 2>/dev/null" all-agent-ids))

               (full-mvn-output (jal--maven-run-command mvn-list-cmd "dependency-list")))

          (if (not full-mvn-output)
              (progn
                (warn "Maven failed to run or returned no output.")
                nil)

            (dolist (agent-id agents-list)
              (let* (
                     (agent-info (jal--maven-extract-agent-dependency-info full-mvn-output agent-id))
                     (agent-version (jal--maven-extract-version (when agent-info (string-trim agent-info)))))

                (when (and agent-version (not (string-empty-p agent-version)))
                  (let* ((parts (split-string agent-info ":"))
                         (group-id (nth 0 parts)))

                    (let ((agent-path (jal--resolve-agent-path repo-path group-id agent-id agent-version)))
                      (when agent-path
                        (setq found-agents (cons (list agent-id agent-path agent-version) found-agents))))))))
            (nreverse found-agents)))))))

(provide 'jal-build-maven)
;;; jal-build-maven.el ends here
