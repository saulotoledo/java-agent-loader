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

;; Stub out lsp-java symbols so the file can be loaded without lsp-java.
(defvar lsp-java-vmargs '("-Xmx1G"))
(defvar lsp-java-java-path "java")
(defvar lsp-java-configuration-runtimes nil)
(defvar lsp-after-initialize-hook nil)

(defun lsp-java--ls-command ()
  "Return the list of command-line arguments to start JDTLS."
  '("java" "-jar" "jdtls.jar"))

(require 'jal-client-lsp)

(ert-deftest jal-test/lsp-setup-installs-advice ()
  "`jal-lsp-java-setup' installs the around advice on lsp-java--ls-command."
  (jal-lsp-java-setup)
  (should (advice-member-p #'jal--lsp-java-ls-command-advice 'lsp-java--ls-command))
  ;; Clean up
  (advice-remove 'lsp-java--ls-command #'jal--lsp-java-ls-command-advice))

(ert-deftest jal-test/lsp-setup-does-not-warn-when-function-missing ()
  "`jal-lsp-java-setup' does not warn at setup time; warning is deferred to the hook."
  (cl-letf (((symbol-function 'lsp-java--ls-command) nil))
    (let ((warned nil))
      (cl-letf (((symbol-function 'display-warning)
                  (lambda (_type msg &rest _) (setq warned msg))))
        (jal-lsp-java-setup))
      ;; No warning should be emitted during setup itself.
      (should (null warned))
      (should (memq #'jal--lsp-java-check-interface lsp-after-initialize-hook))))
  (remove-hook 'lsp-after-initialize-hook #'jal-find-and-configure-agents)
  (remove-hook 'lsp-after-initialize-hook #'jal--lsp-java-check-interface)
  (advice-remove 'lsp-java--ls-command #'jal--lsp-java-ls-command-advice))

(ert-deftest jal-test/lsp-check-interface-warns-when-function-missing ()
  "`jal--lsp-java-check-interface' warns when lsp-java--ls-command is not defined."
  (let ((jal--lsp-java-interface-warning-issued nil))
    (cl-letf (((symbol-function 'lsp-java--ls-command) nil))
      (let ((warned nil))
        (cl-letf (((symbol-function 'display-warning)
                    (lambda (_type msg &rest _) (setq warned msg))))
          (jal--lsp-java-check-interface))
        (should warned)
        (should (string-match-p "lsp-java--ls-command" warned))))))

(ert-deftest jal-test/lsp-check-interface-silent-when-function-present ()
  "`jal--lsp-java-check-interface' is silent when lsp-java--ls-command exists."
  (let ((jal--lsp-java-interface-warning-issued nil)
         (warned nil))
    (cl-letf (((symbol-function 'display-warning)
                (lambda (_type msg &rest _) (setq warned msg))))
      (jal--lsp-java-check-interface))
    (should (null warned))))

(ert-deftest jal-test/lsp-check-interface-warns-only-once ()
  "`jal--lsp-java-check-interface' warns at most once per session."
  (let ((jal--lsp-java-interface-warning-issued nil)
         (warn-count 0))
    (cl-letf (((symbol-function 'lsp-java--ls-command) nil)
               ((symbol-function 'display-warning)
                 (lambda (_type _msg &rest _) (cl-incf warn-count))))
      (jal--lsp-java-check-interface)
      (jal--lsp-java-check-interface)
      (jal--lsp-java-check-interface))
    (should (= 1 warn-count))))

(ert-deftest jal-test/lsp-advice-does-not-mutate-vmargs ()
  "The lsp-java advice does not permanently modify lsp-java-vmargs."
  (let ((original-vmargs (copy-sequence lsp-java-vmargs)))
    (advice-add 'lsp-java--ls-command :around #'jal--lsp-java-ls-command-advice)
    ;; Calling the advised function should not change the outer variable.
    (lsp-java--ls-command)
    (should (equal original-vmargs lsp-java-vmargs))
    (advice-remove 'lsp-java--ls-command #'jal--lsp-java-ls-command-advice)))

;; ---------------------------------------------------------------------------
;; jal-client-eglot advice installation
;; ---------------------------------------------------------------------------

;; Stub out eglot-java symbols.
(defvar eglot-java-eclipse-jdt-args '("-Xmx1G"))

(defun eglot-java--eclipse-jdt-contact (_interactive)
  "Return the contact specification for connecting to the JDTLS server with Eglot.
The return value is a cons cell as expected by Eglot’s server connection logic."
  (cons 'eglot-java-eclipse-jdt '("java" "-jar" "jdtls.jar")))

(defun eglot-java--find-java-program-from-alternatives ()
  "Find the path to the 'java' executable.
Returns the first matching executable in the current PATH."
  (executable-find "java"))

(require 'jal-client-eglot)

(ert-deftest jal-test/eglot-setup-installs-advice ()
  "`jal-eglot-java-setup' installs the around advice on eglot-java--eclipse-jdt-contact."
  (jal-eglot-java-setup)
  (should (advice-member-p #'jal--eglot-java-contact-advice 'eglot-java--eclipse-jdt-contact))
  (advice-remove 'eglot-java--eclipse-jdt-contact #'jal--eglot-java-contact-advice))

(ert-deftest jal-test/eglot-setup-does-not-warn-when-function-missing ()
  "`jal-eglot-java-setup' does not warn at setup time; warning is deferred to the hook."
  (cl-letf (((symbol-function 'eglot-java--eclipse-jdt-contact) nil))
    (let ((warned nil))
      (cl-letf (((symbol-function 'display-warning)
                  (lambda (_type msg &rest _) (setq warned msg))))
        (jal-eglot-java-setup))
      ;; No warning should be emitted during setup itself.
      (should (null warned))
      (should (memq #'jal--eglot-connect-hook-check-interface eglot-connect-hook))))
  (remove-hook 'eglot-connect-hook #'jal--eglot-connect-hook-find-agents)
  (remove-hook 'eglot-connect-hook #'jal--eglot-connect-hook-check-interface)
  (advice-remove 'eglot-java--eclipse-jdt-contact #'jal--eglot-java-contact-advice))

(ert-deftest jal-test/eglot-check-interface-warns-when-function-missing ()
  "`jal--eglot-java-check-interface' warns when eglot-java--eclipse-jdt-contact is not defined."
  (let ((jal--eglot-java-interface-warning-issued nil))
    (cl-letf (((symbol-function 'eglot-java--eclipse-jdt-contact) nil))
      (let ((warned nil))
        (cl-letf (((symbol-function 'display-warning)
                    (lambda (_type msg &rest _) (setq warned msg))))
          (jal--eglot-java-check-interface))
        (should warned)
        (should (string-match-p "eglot-java--eclipse-jdt-contact" warned))))))

(ert-deftest jal-test/eglot-check-interface-silent-when-function-present ()
  "`jal--eglot-java-check-interface' is silent when eglot-java--eclipse-jdt-contact exists."
  (let ((jal--eglot-java-interface-warning-issued nil)
         (warned nil))
    (cl-letf (((symbol-function 'display-warning)
                (lambda (_type msg &rest _) (setq warned msg))))
      (jal--eglot-java-check-interface))
    (should (null warned))))

(ert-deftest jal-test/eglot-check-interface-warns-only-once ()
  "`jal--eglot-java-check-interface' warns at most once per session."
  (let ((jal--eglot-java-interface-warning-issued nil)
         (warn-count 0))
    (cl-letf (((symbol-function 'eglot-java--eclipse-jdt-contact) nil)
               ((symbol-function 'display-warning)
                 (lambda (_type _msg &rest _) (cl-incf warn-count))))
      (jal--eglot-java-check-interface)
      (jal--eglot-java-check-interface)
      (jal--eglot-java-check-interface))
    (should (= 1 warn-count))))

(ert-deftest jal-test/eglot-advice-does-not-mutate-args ()
  "The eglot-java advice does not permanently modify eglot-java-eclipse-jdt-args."
  (let ((original-args (copy-sequence eglot-java-eclipse-jdt-args)))
    (advice-add 'eglot-java--eclipse-jdt-contact :around #'jal--eglot-java-contact-advice)
    (eglot-java--eclipse-jdt-contact nil)
    (should (equal original-args eglot-java-eclipse-jdt-args))
    (advice-remove 'eglot-java--eclipse-jdt-contact #'jal--eglot-java-contact-advice)))

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
      (should (equal "lombok"                      (nth 0 entry)))
      (should (equal "org.projectlombok"            (nth 1 entry)))
      (should (equal "1.18.30"                      (nth 2 entry)))
      (should (equal "/repo/lombok-1.18.30.jar"     (nth 3 entry))))))

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
