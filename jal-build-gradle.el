;;; jal-build-gradle.el --- Gradle detection for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

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

;; Gradle detection logic for Java Agent Loader (JAL).

;;; Code:

(require 'jal-utils)

(defun jal--gradle-write-init-script (agents-list)
  "Write a Gradle init script that lists resolved jars for AGENTS-LIST.
Returns the path to the created temp file. The script emits one line per
resolved artifact in the format:
  JAL_ARTIFACT\\tGROUP\\tARTIFACT\\tVERSION\\tFILE_PATH

Deduplication uses `gradle.ext.jalFoundArtifacts', an ExtraPropertiesExtension
map that is visible across all project closures in an init script. Resolution
runs inside `afterEvaluate' to comply with Gradle 9's exclusive lock
requirements for configuration resolution. Configurations are queried in
runtime-first order so Gradle's own conflict-resolved runtime version always
wins over compile-only variants."
  (let* ((quoted-agents
           (mapconcat (lambda (id) (format "\"%s\"" id)) agents-list ", "))
          (init-file (make-temp-file "jal-gradle-init" nil ".gradle")))
    (with-temp-file init-file
      (insert (format
                "// gradle.ext is an ExtraPropertiesExtension visible across all project
// closures in an init script.
gradle.ext.jalFoundArtifacts = [:]

// Resolution must occur inside afterEvaluate (or during task execution) to
// hold the project's exclusive lock, preventing Gradle 9 thread-safety errors.
allprojects {
  afterEvaluate { proj ->
    def targets = [%s] as Set
    // runtimeClasspath is listed first so its conflict-resolved version
    // takes precedence over compileClasspath or test variants.
    ['runtimeClasspath', 'testRuntimeClasspath', 'compileClasspath',
     'annotationProcessor', 'testCompileClasspath'].each { cfgName ->
      def cfg = proj.configurations.findByName(cfgName)
      // canBeResolved was added in Gradle 3.3; older versions lack the
      // property, so we default to true and let the catch handle failures.
      def resolvable = cfg != null && (cfg.hasProperty('canBeResolved') ? cfg.canBeResolved : true)
      if (resolvable) {
        try {
          cfg.resolvedConfiguration.resolvedArtifacts
            .findAll { targets.contains(it.name) && !gradle.ext.jalFoundArtifacts.containsKey(it.name) }
            .each { art ->
              gradle.ext.jalFoundArtifacts[art.name] = true
              println \"JAL_ARTIFACT\\t${art.moduleVersion.id.group}\\t${art.name}\\t${art.moduleVersion.id.version}\\t${art.file.absolutePath}\"
            }
        } catch (Exception e) {
          System.err.println(\"JAL: resolution failed for ${cfgName} in ${proj.name}: ${e.message}\")
        }
      }
    }
  }
}
" quoted-agents)))
    init-file))

(defun jal--gradle-parse-init-output (output)
  "Parse OUTPUT from the JAL Gradle init script.
Returns a list of (artifact-id group version absolute-path) entries.
Deduplication must have been handled beforehand, with each artifact appearing
only once in OUTPUT."
  (let ((results '()))
    (dolist (line (split-string output "\n" t))
      (when (string-prefix-p "JAL_ARTIFACT\t" line)
        (let* ((parts     (split-string line "\t" t))
                (group    (nth 1 parts))
                (artifact (nth 2 parts))
                (version  (nth 3 parts))
                (path     (nth 4 parts)))
          (when (and group artifact version path)
            (push (list artifact group version path) results)))))
    (nreverse results)))

(defun jal--gradle-detect-agents-async (project-root agents-list callback)
  "Detect AGENTS-LIST in PROJECT-ROOT using Gradle asynchronously.
Calls CALLBACK with a list of (agent-id path version) entries,
or nil on failure."
  (let* ((gradle-cmd (cond
                       ((file-executable-p (expand-file-name "gradlew" project-root)) "./gradlew")
                       ((executable-find "gradle") "gradle")
                       (t (warn "JAL: Neither ./gradlew nor gradle found") nil)))
          (default-directory (or project-root default-directory)))
    (if (not gradle-cmd)
      (funcall callback nil)
      (let* ((init-file (jal--gradle-write-init-script agents-list))
              (cmd (format "%s --no-daemon -q -I %s 2>&1" gradle-cmd init-file))
              (output-buffer (generate-new-buffer " *jal-gradle-detection*")))
        (make-process
          :name "jal-gradle-detection"
          :buffer output-buffer
          :command (list shell-file-name shell-command-switch cmd)
          :sentinel
          (lambda (proc _event)
            (when (memq (process-status proc) '(exit signal))
              (let* ((exit-code (process-exit-status proc))
                      (output (with-current-buffer (process-buffer proc)
                                (buffer-string)))
                      (found-agents '()))
                (when (buffer-live-p (process-buffer proc))
                  (kill-buffer (process-buffer proc)))
                (when (file-exists-p init-file)
                  (delete-file init-file))
                (if (not (= 0 exit-code))
                  (progn
                    (jal--debug-log "Gradle command failed (exit %d):\n%s"
                      exit-code output)
                    (warn "JAL Gradle Error: Command failed (exit %d). Check the buffer %s for details." exit-code jal--debug-buffer-name)
                    (jal-show-debug-log)
                    (funcall callback nil))
                  (let ((parsed (jal--gradle-parse-init-output output)))
                    (dolist (entry parsed)
                      (let* ((artifact-id (nth 0 entry))
                              (group-id    (nth 1 entry))
                              (version     (nth 2 entry))
                              (abs-path    (nth 3 entry)))
                        ;; Prefer the absolute path the init script gives us; fall back to
                        ;; jal--resolve-agent-path so custom :jar-path patterns still work.
                        (let ((agent-path
                                (if (and abs-path (file-exists-p abs-path))
                                  abs-path
                                  (when abs-path
                                    (jal--resolve-agent-path
                                      (file-name-directory abs-path)
                                      group-id artifact-id version)))))
                          (when agent-path
                            (push (list artifact-id agent-path version) found-agents)))))
                    (when (null found-agents)
                      (message "JAL: No agents found in Gradle dependencies."))
                    (funcall callback (nreverse found-agents))))))))))))


(provide 'jal-build-gradle)
;;; jal-build-gradle.el ends here
