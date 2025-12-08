;;; jal-build-gradle.el --- Gradle detection for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; Gradle detection logic for JAL.

;;; Code:

(require 'jal-utils)

(defun jal--gradle-detect-agents (project-root agents-list)
  "Run Gradle detection for AGENTS-LIST on PROJECT-ROOT.
Returns list of (agent-id path version)."
  (jal--check-executable "gradle" "JAL: Gradle executable not found in your PATH")

  (let ((default-directory (or project-root default-directory))
        (found-agents '()))
    (message "JAL: Running Gradle dependency analysis for %s agents..." (length agents-list))

    ;; 1. Get Maven Repository Path (Gradle often uses the Maven cache for standard artifacts)
    (let* ((mvn-repo-cmd "mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>/dev/null")
           (repo-path (condition-case err
                          (string-trim (with-output-to-string (call-process-shell-command mvn-repo-cmd nil standard-output nil)))
                        (error
                         (warn "JAL Maven Error: Failed to execute 'mvn help:evaluate'. Error: %S" err)
                         ""))))

      (if (string-empty-p repo-path)
          (progn
            (warn "Maven local repository path not found. Cannot construct Gradle artifact path reliably.")
            nil)

        ;; 2. Determine Gradle executable
        (let ((gradle-cmd (if (file-exists-p (expand-file-name "gradlew" project-root)) "./gradlew" "gradle")))

          ;; 3. Iterate through each known agent
          (dolist (agent-id agents-list)
            ;; Command to resolve the path directly
            (let* ((gradle-list-cmd (format "%s dependencies --configuration runtimeClasspath -q 2>/dev/null | grep %s" gradle-cmd agent-id))
                   (output (condition-case err
                               (with-output-to-string (call-process-shell-command gradle-list-cmd nil standard-output nil))
                             (error
                              (warn "JAL Gradle Error: Failed to execute '%s'. Error: %S" gradle-list-cmd err)
                              "")))
                   ;; Parse the line: format often looks like: org.projectlombok:lombok:1.18.30
                   (agent-line (car (split-string output "\n" t)))
                   (agent-version (when agent-line
                                    (string-trim (car (last (split-string agent-line ":")))))))

              (when (and agent-version (not (string-empty-p agent-version)))

                ;; Attempt to parse GroupId and ArtifactId (complicated due to dependency notation)
                (let* ((parts (split-string agent-line ":"))
                       (group-id (car parts))
                       (artifact-id (cadr parts)))

                  (when (and group-id artifact-id)
                    (let ((agent-path (jal--resolve-agent-path repo-path group-id artifact-id agent-version)))
                      (when agent-path
                        (setq found-agents (cons (list agent-id agent-path agent-version) found-agents))))))))))
        (nreverse found-agents)))))

(provide 'jal-build-gradle)
;;; jal-build-gradle.el ends here
