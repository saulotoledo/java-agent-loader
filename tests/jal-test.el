;;; jal-test.el --- ERT tests for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; ERT test suite for jal.

;;; Code:

(require 'ert)

;; ---------------------------------------------------------------------------
;; Test helpers
;; ---------------------------------------------------------------------------

(defmacro jal-test--with-temp-project (build-file contents &rest body)
  "Execute BODY inside a temp directory containing BUILD-FILE with CONTENTS."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "jal-test-project" t))
           (bf  (expand-file-name ,build-file dir)))
     (unwind-protect
       (progn
         (with-temp-file bf (insert ,contents))
         (let ((default-directory dir))
           ,@body))
       (delete-directory dir t))))

;; ---------------------------------------------------------------------------
;; jal-vars
;; ---------------------------------------------------------------------------

(require 'jal-vars)

(ert-deftest jal-test/vars-defaults ()
  "Core defcustoms start at sensible defaults."
  (let ((jal-agents-config nil)
         (jal-additional-agents nil)
         (jal-current-java-key-function nil))
    (should (null jal-agents-config))
    (should (null jal-additional-agents))
    (should (stringp jal-project-cache-filename))
    (should (null jal-current-java-key-function))))

;; ---------------------------------------------------------------------------
;; jal-known-agents
;; ---------------------------------------------------------------------------

(require 'jal-known-agents)

(ert-deftest jal-test/known-agents-not-empty ()
  "`jal-known-agents' contains at least the bundled agents."
  (should (assoc "lombok" jal-known-agents))
  (should (assoc "org.jacoco.agent" jal-known-agents)))

;; ---------------------------------------------------------------------------
;; jal-utils / jal--merge-agent-configs
;; ---------------------------------------------------------------------------

(require 'jal-utils)

(ert-deftest jal-test/merge-empty-user-agents ()
  "Merging nil user agents returns known agents unchanged."
  (let ((result (jal--merge-agent-configs nil)))
    (should (equal result jal-known-agents))))

(ert-deftest jal-test/merge-adds-new-agent ()
  "A new agent not in known-agents is appended."
  (let* ((user-agents '(("my-agent" :jar-path "/opt/my-agent.jar")))
          (result (jal--merge-agent-configs user-agents)))
    (should (assoc "my-agent" result))
    ;; Still contains known agents
    (should (assoc "lombok" result))))

(ert-deftest jal-test/merge-overrides-known-agent ()
  "User entries override matching known agents."
  (let* ((user-agents '(("lombok" :params "myparams")))
          (result (jal--merge-agent-configs user-agents))
          (entry  (assoc "lombok" result)))
    (should entry)
    (should (equal "myparams" (plist-get (cdr entry) :params)))))

(ert-deftest jal-test/merge-does-not-duplicate ()
  "Overriding a known agent does not produce duplicate entries."
  (let* ((result (jal--merge-agent-configs '(("lombok"))))
          (count  (length (seq-filter (lambda (e) (equal "lombok" (car e))) result))))
    (should (= count 1))))

;; ---------------------------------------------------------------------------
;; jal--detect-build-system
;; ---------------------------------------------------------------------------

(require 'jal)

(ert-deftest jal-test/detect-build-system-maven ()
  "Detects Maven when pom.xml is present."
  (jal-test--with-temp-project "pom.xml" "<project/>"
    (should (eq 'maven (jal--detect-build-system default-directory)))))

(ert-deftest jal-test/detect-build-system-gradle-groovy ()
  "Detects Gradle when build.gradle is present."
  (jal-test--with-temp-project "build.gradle" "// empty"
    (should (eq 'gradle (jal--detect-build-system default-directory)))))

(ert-deftest jal-test/detect-build-system-gradle-kotlin ()
  "Detects Gradle when build.gradle.kts is present."
  (jal-test--with-temp-project "build.gradle.kts" "// empty"
    (should (eq 'gradle (jal--detect-build-system default-directory)))))

(ert-deftest jal-test/detect-build-system-none ()
  "Returns nil for directories with no recognised build file."
  (let ((dir (make-temp-file "jal-test-empty" t)))
    (unwind-protect
      (should (null (jal--detect-build-system dir)))
      (delete-directory dir t))))

;; ---------------------------------------------------------------------------
;; jal-utils / cache helpers
;; ---------------------------------------------------------------------------

(ert-deftest jal-test/config-scoped-p-true ()
  "`jal--config-scoped-p' returns t for scoped format."
  (let ((cfg '(("/usr/bin/java" (("lombok" "/path/lombok.jar" "" "1.18.30"))))))
    (should (jal--config-scoped-p cfg))))

(ert-deftest jal-test/config-scoped-p-false ()
  "`jal--config-scoped-p' returns nil for flat (legacy) format."
  (let ((cfg '(("lombok" "/path/lombok.jar" "" "1.18.30"))))
    (should (null (jal--config-scoped-p cfg)))))

;; ---------------------------------------------------------------------------
;; jal-client-lsp advice installation
;; ---------------------------------------------------------------------------

(load (expand-file-name "jal-client-test.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest jal-test/detect-finalize-is-deferred ()
  "Detection completion schedules finalize via `jal--defer-in-buffer'."
  (let ((deferred-fn nil)
         (deferred-args nil)
         (jal--detection-in-progress nil)
         (jal-agents-config '(("lombok" :params "")))
         (results '(("lombok" "/tmp/lombok.jar" "1.18.30"))))
    (cl-letf (((symbol-function 'jal--defer-in-buffer)
                (lambda (_buf _dir fn &rest args)
                  (setq deferred-fn fn)
                  (setq deferred-args args)))
               ((symbol-function 'jal--detect-agents-core-async)
                 (lambda (_ids callback)
                   (funcall callback results))))
      (jal-detect-java-agents)
      (should (functionp deferred-fn))
      (should (equal deferred-args (list results)))
      ;; Lock held until deferred finalize runs.
      (should jal--detection-in-progress))))

(ert-deftest jal-test/detect-finalize-keeps-java-key-from-start ()
  "Results are finalized under the JVM active when detection started."
  (let* ((jal--detection-in-progress nil)
          (jal-agents-config '(("lombok" :params "")))
          (current "/jdk-first/java")
          (jal-current-java-key-function (lambda () current))
          (deferred nil) (seen nil))
    (cl-letf (((symbol-function 'jal--defer-in-buffer)
                (lambda (_b _d fn &rest args) (setq deferred (cons fn args))))
               ((symbol-function 'jal--detect-agents-core-async)
                 (lambda (_ids callback) (funcall callback nil)))
               ((symbol-function 'jal--finalize-detected-agents)
                 (lambda (_r) (setq seen (jal--current-java-key)))))
      (jal-detect-java-agents)
      (setq current "/jdk-second/java")
      (apply (car deferred) (cdr deferred))
      (should (string-suffix-p "jdk-first/java" seen))
      (should (string-suffix-p "jdk-second/java" (jal--current-java-key))))))

(ert-deftest jal-test/finalize-detected-agents-clears-lock ()
  "`jal--finalize-detected-agents' clears the in-progress lock."
  (let ((jal--detection-in-progress t)
         (jal-agents-config '(("lombok" :params "")))
         (cached nil)
         (hook-ran nil))
    (cl-letf (((symbol-function 'jal--cache-agent-config)
                (lambda (&rest args) (setq cached args)))
               ((symbol-function 'run-hooks)
                 (lambda (_hook) (setq hook-ran t))))
      (jal--finalize-detected-agents
        '(("lombok" "/tmp/lombok.jar" "1.18.30")))
      (should-not jal--detection-in-progress)
      (should cached)
      (should hook-ran))))

(ert-deftest jal-test/call-in-buffer-uses-directory-when-buffer-dead ()
  "`jal--call-in-buffer' still applies DIRECTORY if BUFFER is dead."
  (let* ((dir (make-temp-file "jal-dir" t))
          (seen nil))
    (unwind-protect
      (progn
        (jal--call-in-buffer nil dir
          (lambda ()
            (setq seen default-directory)))
        (should (equal (file-name-as-directory seen)
                  (file-name-as-directory dir))))
      (delete-directory dir t))))

;; ---------------------------------------------------------------------------
;; jal-client-eglot advice installation
;; ---------------------------------------------------------------------------

(load (expand-file-name "jal-eglot-test.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;; ---------------------------------------------------------------------------
;; jal-build-gradle helpers
;; ---------------------------------------------------------------------------

(require 'jal-build-gradle)

(ert-deftest jal-test/gradle-parse-empty-output ()
  "Parsing empty Gradle init output returns nil."
  (should (null (jal--gradle-parse-init-output ""))))

(ert-deftest jal-test/gradle-parse-single-artifact ()
  "Parsing a single JAL_ARTIFACT line returns correct entry."
  (let* ((line "JAL_ARTIFACT\torg.projectlombok\tlombok\t1.18.30\t/repo/lombok-1.18.30.jar")
          (result (jal--gradle-parse-init-output line)))
    (should (= 1 (length result)))
    (let ((entry (car result)))
      (should (equal "lombok"                   (nth 0 entry)))
      (should (equal "org.projectlombok"        (nth 1 entry)))
      (should (equal "1.18.30"                  (nth 2 entry)))
      (should (equal "/repo/lombok-1.18.30.jar" (nth 3 entry))))))

(ert-deftest jal-test/gradle-parse-ignores-noise ()
  "Lines not starting with JAL_ARTIFACT are ignored."
  (let* ((output "Downloading gradle...\nJAL_ARTIFACT\tg\ta\t1.0\t/p/a.jar\nBUILD SUCCESSFUL")
          (result (jal--gradle-parse-init-output output)))
    (should (= 1 (length result)))))

(ert-deftest jal-test/gradle-init-script-contains-agents ()
  "The generated init script contains all requested agent names."
  (let* ((agents '("lombok" "org.jacoco.agent"))
          (script-file (jal--gradle-write-init-script agents))
          (content (with-temp-buffer
                     (insert-file-contents script-file)
                     (buffer-string))))
    (delete-file script-file)
    (should (string-match-p "\"lombok\"" content))
    (should (string-match-p "\"org.jacoco.agent\"" content))
    (should (string-match-p "JAL_ARTIFACT" content))))

;; ---------------------------------------------------------------------------
;; jal-build-maven helpers
;; ---------------------------------------------------------------------------

(require 'jal-build-maven)

(ert-deftest jal-test/maven-extract-version-3-parts ()
  "Extracts version from 3-part G:A:V coordinate."
  (should (equal "1.18.30"
            (jal--maven-extract-version "org.projectlombok:lombok:1.18.30"))))

(ert-deftest jal-test/maven-extract-version-5-parts ()
  "Extracts version from 5-part G:A:P:V:S coordinate."
  (should (equal "1.18.30"
            (jal--maven-extract-version "org.projectlombok:lombok:jar:1.18.30:provided"))))

(ert-deftest jal-test/maven-extract-version-6-parts ()
  "Extracts version from 6-part G:A:P:C:V:S coordinate."
  (should (equal "0.8.11"
            (jal--maven-extract-version "org.jacoco:org.jacoco.agent:jar:runtime:0.8.11:test"))))

(ert-deftest jal-test/maven-extract-agent-dependency-info ()
  "Extracts the matching coordinate from multi-line mvn output."
  (let ((output "[INFO]    org.projectlombok:lombok:jar:1.18.30:provided\n[INFO] BUILD SUCCESS"))
    (should (equal "org.projectlombok:lombok:jar:1.18.30:provided"
              (jal--maven-extract-agent-dependency-info output "lombok")))))

(ert-deftest jal-test/maven-extract-agent-dependency-info-nil-when-absent ()
  "Returns nil when the agent is not in the mvn output."
  (let ((output "[INFO] BUILD SUCCESS\n[INFO] BUILD SUCCESS"))
    (should (null (jal--maven-extract-agent-dependency-info output "lombok")))))

(provide 'jal-test)
;;; jal-test.el ends here
