;;; jal.el --- Java Agent Loader for JDTLS -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (project "0.3.0"))
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/java-agent-loader

;;; Commentary:

;; This package manages the injection of -javaagent arguments for tools
;; like Lombok and JaCoCo into the JDT Language Server (JDTLS) process,
;; using a global cache to avoid slow Maven/Gradle lookups on every startup.

;;; Code:

(require 'project)
(require 'jal-vars)
(require 'jal-utils)
(require 'jal-build-maven)
(require 'jal-build-gradle)

(declare-function jal-lsp-java-setup  "jal-client-lsp")
(declare-function jal-eglot-java-setup "jal-client-eglot")

(with-eval-after-load 'lsp-java
  (require 'jal-client-lsp)
  (jal-lsp-java-setup))

(with-eval-after-load 'eglot-java
  (require 'jal-client-eglot)
  (jal-eglot-java-setup))

;; ====================================================================
;; Build System Specific Detection Helpers
;; ====================================================================

(defun jal--detect-build-system (project-root)
  "Detect the build system on the PROJECT-ROOT."
  (cond
    ((file-exists-p (expand-file-name "pom.xml" project-root)) 'maven)
    ((file-exists-p (expand-file-name "build.gradle" project-root)) 'gradle)
    ((file-exists-p (expand-file-name "build.gradle.kts" project-root)) 'gradle)
    (t nil)))

;; ====================================================================
;; Detection Progress
;; ====================================================================

(defvar jal--detection-in-progress nil
  "Non-nil while async agent detection is running.
Prevents duplicate detection processes from being launched concurrently.")

(defvar jal--configured-scopes (make-hash-table :test 'equal)
  "Hash-set of \"project-root|java-key\" strings already handled this session.
Prevents `jal-find-and-configure-agents' from re-running on the LSP restart
that JAL itself triggers after first-time detection.")

(defconst jal--spinner-frames ["-" "\\" "|" "/"]
  "Animation frames for the detection progress spinner.")

(defvar jal--spinner-timer nil
  "Active timer for the detection progress spinner, or nil when idle.")

(defun jal--spinner-start (msg)
  "Animate a spinner in the echo area prefixed with MSG while detection runs."
  (let ((i 0))
    (setq jal--spinner-timer
      (run-with-timer
        0 0.1
        (lambda ()
          (message "%s %s" msg
            (aref jal--spinner-frames
              (% i (length jal--spinner-frames))))
          (setq i (1+ i)))))))

(defun jal--spinner-stop ()
  "Cancel the detection spinner and clear the echo area."
  (when jal--spinner-timer
    (cancel-timer jal--spinner-timer)
    (setq jal--spinner-timer nil)
    (message nil)))

;; ====================================================================
;; Core Hook Function (Functional Injector)
;; ====================================================================

(defun jal-get-vmargs-with-javaagents ()
  "Return the current vm args with the java agents appended.
Reads configuration from the global cache file, filters for the current
project, and builds the javaagents arguments."

  (let* ((agent-config-list (jal--load-agent-configs-from-project))
          (agent-args '()))

    (when agent-config-list
      (dolist (agent-entry agent-config-list)
        (let* ((agent-id (car agent-entry))
                (agent-path (cadr agent-entry))
                (agent-params (caddr agent-entry))
                (agent-version (cadddr agent-entry))
                (agent-arg (concat "-javaagent:" agent-path
                             (if (not (string-empty-p agent-params))
                               (concat "=" agent-params)
                               ""))))

          (when (and (stringp agent-path) (file-exists-p agent-path))
            (message "JAL: Injecting -javaagent:%s (v%s) into JDTLS startup." agent-id agent-version)
            (push agent-arg agent-args)))))

    agent-args))


;; ====================================================================
;; Interactive Flow and Execution
;; ====================================================================

(defun jal--detect-agents-core-async (agent-ids-to-check callback)
  "Detect AGENT-IDS-TO-CHECK in the project asynchronously.
CALLBACK is called with the list of detected agent entries, or nil on failure."
  (if (not jal--feature-supported-p)
    (progn
      (message "JAL: Prerequisites (project) not met. Skipping operation.")
      (funcall callback nil))

    (let* ((project (project-current))
            (project-root (and project (project-root project)))
            (build-system (jal--detect-build-system project-root)))

      (cond
        ((not project-root)
          (message "JAL: Not in a recognized project. Skipping detection.")
          (funcall callback nil))

        ((not build-system)
          (message "JAL: No supported build system found. Skipping detection.")
          (funcall callback nil))

        (t
          (jal--spinner-start
            (format "JAL: Running %s dependency analysis" (symbol-name build-system)))
          (let ((wrapped-callback
                  (lambda (results)
                    (jal--spinner-stop)
                    (funcall callback results))))
            (pcase build-system
              ('maven  (jal--maven-detect-agents-async  project-root agent-ids-to-check wrapped-callback))
              ('gradle (jal--gradle-detect-agents-async project-root agent-ids-to-check wrapped-callback))
              (_ (jal--spinner-stop) (funcall callback nil)))))))))


;;;###autoload
(defun jal-detect-java-agents ()
  "Detect all known java agents in the project asynchronously.
Starts async detection and returns immediately; results are cached
and `jal-agents-detected-hook' is run once detection completes."
  (interactive)

  (let* ((project (and (fboundp 'project-current) (project-current)))
          (project-root (and project (file-name-as-directory (project-root project))))
          (cache-file (and project-root (jal--get-cache-file project-root))))

    (when cache-file
      (let* ((existing-config (and (file-exists-p cache-file)
                                (jal--read-project-config project-root)))
              (java-key (jal--current-java-key))
              (scope-exists (and (jal--config-scoped-p existing-config)
                              (assoc java-key existing-config))))
        (when (and scope-exists
                (not (y-or-n-p
                       (format "JAL: Agents already configured for Java at '%s'. Override? "
                         java-key))))
          (user-error "JAL: Detection cancelled"))))

    (if jal--detection-in-progress
      (message "JAL: Detection already in progress.")
      (setq jal--detection-in-progress t)
      (let ((agents-to-check (mapcar #'car jal-agents-config)))
        (jal--detect-agents-core-async
          agents-to-check
          (lambda (detection-results)
            (setq jal--detection-in-progress nil)
            (if (null detection-results)
              (message "JAL: No agents found in project dependencies.")
              (message "JAL: Detected agents: %S" (mapcar #'car detection-results))
              (dolist (agent-entry detection-results)
                (let* ((agent-id (car agent-entry))
                        (detected-path (cadr agent-entry))
                        (detected-version (caddr agent-entry))
                        (config (cdr (assoc agent-id jal-agents-config)))
                        (config-params (plist-get config :params))
                        (agent-params (cond
                                        ;; If params explicitly set (even if empty), use them
                                        ((plist-member config :params) config-params)
                                        ;; Otherwise, ask user
                                        (t (read-string
                                             (format "Params for %s (optional): " agent-id)
                                             "" nil nil)))))
                  (jal--cache-agent-config agent-id detected-path detected-version agent-params)))
              (run-hooks 'jal-agents-detected-hook))))))))

;;;###autoload
(defun jal-detect-agent-interactively (agent-id)
  "Detect the AGENT-ID in the current project asynchronously.
It uses the project build system (Maven or Gradle) to proceed,
caching the result. Used for single, non-batch detection."
  (interactive
    (list (completing-read "Agent artifactId: "
            (mapcar #'car jal-agents-config)
            nil nil nil nil "lombok")))

  (if jal--detection-in-progress
    (message "JAL: Detection already in progress.")
    (setq jal--detection-in-progress t)
    (jal--detect-agents-core-async
      (list agent-id)
      (lambda (detection-results)
        (setq jal--detection-in-progress nil)
        (if (null detection-results)
          (message "JAL: Agent '%s' not found in project dependencies." agent-id)
          (let* ((agent-entry (car detection-results))
                  (detected-path (cadr agent-entry))
                  (detected-version (caddr agent-entry))
                  (agent-params (read-string
                                  (format "Inform any parameters required by agent %s (optional, e.g., destfile=target/jacoco.exec): "
                                    agent-id)
                                  "" nil nil)))
            (message "JAL: Detected agent '%s' v%s. Caching setup." agent-id detected-version)
            (jal--cache-agent-config agent-id detected-path detected-version agent-params)))))))


;; ====================================================================
;; Main Execution Function (Reads from Global Cache)
;; ====================================================================

;;;###autoload
(defun jal-find-and-configure-agents ()
  "Search for agents in the current project, caching them when found.
The agents are added to the project only when found in the disk.
Returns the list of agent configurations found, or nil."

  (if jal--feature-supported-p
    (progn
      (let* ((project (project-current))
              (project-root (and project (file-name-as-directory (project-root project))))
              (java-key (jal--current-java-key))
              (scope-key (and project-root (concat project-root "|" java-key))))

        ;; Skip silently if we've already handled this project+JVM combo this
        ;; session (e.g. on the LSP restart that JAL itself triggers).
        (when (and scope-key
                (not (gethash scope-key jal--configured-scopes)))
          (puthash scope-key t jal--configured-scopes)

          (let ((agent-configs (jal--load-agent-configs-from-project)))

            (if (or (null agent-configs)
                  (not (proper-list-p agent-configs)))
              (let ((build-system (and project-root
                                    (jal--detect-build-system project-root))))
                (if (not build-system)
                  (message "JAL: Not a Maven/Gradle project, skipping agent setup.")
                  (if (or jal-auto-setup
                        (y-or-n-p "JAL: Do you want to setup java agents for this project? "))
                    (jal-detect-java-agents)
                    ;; User declined — forget this scope so the question is
                    ;; asked again on the next Emacs session.
                    (remhash scope-key jal--configured-scopes)
                    (message "JAL: Java agents configuration skipped for this session. Run M-x jal-detect-java-agents to do it later."))))

              (message "JAL: Found %d cached agent(s) for this project. Applying configurations."
                (length agent-configs))
              (dolist (agent-entry agent-configs)
                (let ((agent-id (car agent-entry))
                       (path (cadr agent-entry))
                       (version (cadddr agent-entry)))
                  (when (and (stringp path) (file-exists-p path))
                    (message "JAL: Agent %s (v%s) configured." agent-id version))))
              (message "JAL: Configuration complete.")
              agent-configs)))))

    (warn "JAL: Search for agents skipped. Prerequisites not met.")
    nil))

(provide 'jal)
;;; jal.el ends here
