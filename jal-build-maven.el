;;; jal-build-maven.el --- Maven detection for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; Maven detection logic for JAL.

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

(defun jal--maven-run-command-async (cmd project-root context-id callback)
  "Run CMD asynchronously with PROJECT-ROOT as working directory.
CONTEXT-ID identifies the command for error reporting.
CALLBACK is called with the output string on success, or nil on failure."
  (let ((output-buffer (generate-new-buffer (format " *jal-maven-%s*" context-id)))
         (default-directory (or project-root default-directory)))
    (make-process
      :name (format "jal-maven-%s" context-id)
      :buffer output-buffer
      :command (list shell-file-name shell-command-switch cmd)
      :sentinel
      (lambda (proc _event)
        (when (memq (process-status proc) '(exit signal))
          (let* ((exit-code (process-exit-status proc))
                  (raw-output (with-current-buffer (process-buffer proc)
                                (buffer-string)))
                  (output (when (= 0 exit-code) raw-output)))
            (when (buffer-live-p (process-buffer proc))
              (kill-buffer (process-buffer proc)))
            (unless (= 0 exit-code)
              (let* ((error-lines (seq-filter
                                    (lambda (l) (string-match-p "^\\[ERROR\\]" l))
                                    (split-string raw-output "\n" t)))
                      (error-summary (if error-lines
                                       (mapconcat #'identity error-lines "\n")
                                       raw-output)))
                (jal--debug-log "Maven command failed for %s (exit %d):\n%s"
                  context-id exit-code error-summary))
              (warn "JAL Maven Error: Command failed for %s (exit %d). Check the buffer %s for details." context-id exit-code jal--debug-buffer-name)
              (jal-show-debug-log))
            (funcall callback output)))))))

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

(defun jal--maven-detect-agents-async (project-root agents-list callback)
  "Detect AGENTS-LIST in PROJECT-ROOT using Maven asynchronously.
Calls CALLBACK with a list of (agent-id path version) entries, or nil on failure."
  (if (not (executable-find "mvn"))
    (progn
      (warn "JAL: Maven executable not found in your PATH")
      (funcall callback nil))
    ;; Step 1: resolve the local Maven repository path
    (jal--maven-run-command-async
      "mvn -B help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>/dev/null"
      project-root
      "local-repo-lookup"
      (lambda (repo-path)
        (if (or (null repo-path) (string-empty-p (string-trim repo-path)))
          (progn
            (warn "Maven local repository path not found via 'settings.localRepository'. Cannot proceed.")
            (funcall callback nil))
          ;; Strip ANSI escape sequences and trim whitespace
          (let* ((repo-path (replace-regexp-in-string "\033\\[[0-9;]*m" "" (string-trim repo-path)))
                  ;; Build the dependency list command
                  (all-agent-ids (mapconcat #'identity agents-list ","))
                  (mvn-list-cmd (format "mvn -B dependency:list -DincludeArtifactIds=%s 2>/dev/null"
                                  all-agent-ids)))
            (jal--maven-run-command-async
              mvn-list-cmd
              project-root
              "dependency-list"
              (lambda (full-mvn-output)
                (if (not full-mvn-output)
                  (progn
                    (jal--debug-log "Maven failed to run or returned no output. Command: %s" mvn-list-cmd)
                    (warn "Maven failed to run or returned no output.")
                    (funcall callback nil))
                  (let ((found-agents '()))
                    (dolist (agent-id agents-list)
                      (let* ((agent-info (jal--maven-extract-agent-dependency-info
                                           full-mvn-output agent-id))
                              (agent-version (jal--maven-extract-version
                                               (when agent-info (string-trim agent-info)))))
                        (when (and agent-version (not (string-empty-p agent-version)))
                          (let* ((parts (split-string agent-info ":"))
                                  (group-id (nth 0 parts))
                                  (agent-path (jal--resolve-agent-path
                                                repo-path group-id agent-id agent-version)))
                            (when agent-path
                              (push (list agent-id agent-path agent-version) found-agents))))))
                    (funcall callback (nreverse found-agents))))))))))))


(provide 'jal-build-maven)
;;; jal-build-maven.el ends here
