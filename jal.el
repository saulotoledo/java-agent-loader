;;; jal.el --- Java Agent Loader for JDTLS -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
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

(autoload 'jal-lsp-java-setup "jal-client-lsp" "Configures JAL for lsp-java.")
(autoload 'jal-eglot-java-setup "jal-client-eglot" "Configures JAL for eglot.")

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

(defun jal--detect-agents-core (agent-ids-to-check)
  "Detect AGENT-IDS-TO-CHECK in the project.
This is an internal helper to run project and build system checks,
detecting agents. It returns the list of detected agent entries, or nil
on any failure (after reporting)."
  (if (not jal--feature-supported-p)
      (progn
        (message "JAL: Prerequisites (project) not met. Skipping operation.")
        nil)

    (let* ((project (project-current))
           (project-root (and project (project-root project)))
           (build-system (jal--detect-build-system project-root)))

      (cond
       ((not project-root)
        (message "JAL: Not in a recognized project. Skipping detection.")
        nil)

       ((not build-system)
        (message "JAL: No supported build system found. Skipping detection.")
        nil)

       (t
        (let ((agents-list (pcase build-system
                             ('maven (jal--maven-detect-agents project-root agent-ids-to-check))
                             ('gradle (jal--gradle-detect-agents project-root agent-ids-to-check))
                             (_ nil))))

          (if (null agents-list)
              (progn
                (message "JAL: No agents found in project dependencies.")
                nil)

            agents-list)))))))

;;;###autoload
(defun jal-detect-java-agents ()
  "Detects all known java agents in the project.
It skips execution and returns nil if prerequisites were not met."
  (interactive)

  (let* ((project (and (fboundp 'project-current) (project-current)))
         (project-root (and project (file-name-as-directory (project-root project))))
         (cache-file (and project-root (jal--get-cache-file project-root))))

    (when (and cache-file
               (file-exists-p cache-file)
               (not (y-or-n-p "JAL cache file exists. Override it? ")))
      (user-error "JAL: Detection cancelled"))

    (let* ((agents-to-check (mapcar #'car jal-agents-config))
           (detection-results (jal--detect-agents-core agents-to-check)))
      (when detection-results
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
                                (t (read-string (format "Params for %s (optional): " agent-id) "" nil nil)))))

            (jal--cache-agent-config agent-id detected-path detected-version agent-params)))

        (not detection-results)))))

;;;###autoload
(defun jal-detect-agent-interactively (agent-id)
  "Detect the AGENT-ID in the current project.
It uses the project build system (Maven or Gradle) to proceed,
caching the result. Used for single, non-batch detection."
  (interactive
   (list (completing-read "Agent artifactId: "
                          (mapcar #'car jal-agents-config)
                          nil nil nil nil "lombok")))

  (let ((detection-results (jal--detect-agents-core (list agent-id))))

    (when detection-results
      (let* ((agent-entry (car detection-results))
             (detected-path (cadr agent-entry))
             (detected-version (caddr agent-entry))
             (agent-params nil))

        (setq agent-params (read-string (format "Inform any parameters required by agent %s (optional, e.g., destfile=target/jacoco.exec): " agent-id) "" nil nil))
        (message "JAL: Detected agent '%s' v%s. Caching setup." agent-id detected-version)
        (jal--cache-agent-config agent-id detected-path detected-version agent-params)))))


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
        (let ((agent-configs (jal--load-agent-configs-from-project)))

          (if (or (null agent-configs)
                  (not (proper-list-p agent-configs)))
              (if (y-or-n-p (format "JAL: do you want to setup java agents for this project? "))
                  (jal-detect-java-agents)
                (message "JAL: Java agents configuration skipped for this session. Run M-x jal-detect-java-agents to do it later."))

            (message "JAL: Found %d cached agent(s) for this project. Applying configurations." (length agent-configs))

            (dolist (agent-entry agent-configs)
              (let ((agent-id (car agent-entry))
                    (path (cadr agent-entry))
                    (version (cadddr agent-entry)))

                (when (and (stringp path) (file-exists-p path))
                  (message "JAL: Agent %s (v%s) configured." agent-id version))))
            (message "agent-configs %s" agent-configs)
            (message "JAL configuration complete.")
            agent-configs)))

    (warn "JAL: Search for agents skipped. Prerequisites not met.")
    nil))

(provide 'jal)
;;; jal.el ends here
