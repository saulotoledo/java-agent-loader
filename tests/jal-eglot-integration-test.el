;;; jal-eglot-integration-test.el --- Tests with real Eglot -*- lexical-binding: t; -*-

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


(require 'ert)
(require 'jal-client-eglot)
(load (expand-file-name "jal-test-functions.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;; Cover enabling JAL before Eglot defines the advised function.
(jal-eglot-java-mode 1)
(require 'eglot)

(ert-deftest jal-eglot-integration/enable-before-framework-load ()
  (should (advice-member-p #'jal--eglot-guess-contact-advice 'eglot--guess-contact))
  (should-not (featurep 'eglot-java)))

(defmacro jal-eglot-integration--with-project (&rest body)
  "Run BODY in a Java file buffer with an isolated project."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "jal-eglot-integration-" t))
           (project (cons 'transient (file-name-as-directory directory)))
           (project-find-functions (list (lambda (_) project))))
     (unwind-protect
       (progn
         (jal-eglot-java-mode 1)
         (with-temp-buffer
           (setq buffer-file-name (expand-file-name "Main.java" directory)
             default-directory (file-name-as-directory directory)
             major-mode 'java-mode)
           ,@body))
       (jal-eglot-java-mode -1)
       (delete-directory directory t))))

(ert-deftest jal-eglot-integration/real-contact-resolution ()
  (jal-eglot-integration--with-project
    (let ((calls 0)
           (command '("jdtls" :initializationOptions (:setting t))))
      (let ((eglot-server-programs
              (list (cons '(java-mode java-ts-mode)
                      (lambda (&rest _) (setq calls (1+ calls)) command)))))
        (jal-test--with-functions
          ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar"))))
          (let ((result (eglot--guess-contact)))
            (should (= calls 1))
            (should (equal '("jdtls" "--jvm-arg=-javaagent:/a.jar"
                              :initializationOptions (:setting t)) (nth 3 result)))
            (should (equal command '("jdtls" :initializationOptions (:setting t))))
            (should (equal project (nth 1 result)))))))))

(ert-deftest jal-eglot-integration/real-stdio-launch-and-project-context ()
  (jal-eglot-integration--with-project
    (let ((eglot-server-programs '(((java-mode java-ts-mode) . ("jdtls"))))
           (eglot-sync-connect nil)
           (original-make-process (symbol-function 'make-process))
           (server nil) (process nil) (seen nil) (scheduled nil))
      (let ((eglot-server-initialized-hook (list (lambda (s) (setq server s)))))
        (unwind-protect
          (jal-test--with-functions
            ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar")))
              ;; Test the real transport without launching Java or running a
              ;; fake language server. Leave initialization pending.
              (jsonrpc-async-request (lambda (&rest _) nil))
              (make-process
                (lambda (&rest args)
                  (setq seen (plist-get args :command))
                  (setq process (apply original-make-process
                                  (plist-put args :command '("cat"))))))
              (jal--defer-in-buffer
                (lambda (buffer directory _fn &rest _)
                  (setq scheduled (cons buffer directory)))))
            (apply #'eglot--connect (eglot--guess-contact))
            (should (equal '("jdtls" "--jvm-arg=-javaagent:/a.jar") seen))
            (should (equal project (eglot--project server)))
            (let ((origin (current-buffer)))
              (with-temp-buffer (jal--eglot-connect-hook-find-agents server))
              (should (eq origin (car scheduled))))
            (should (equal default-directory (cdr scheduled))))
          (when server (ignore-errors (jsonrpc-shutdown server)))
          (when (processp process)
            (set-process-sentinel process #'ignore)
            (when (process-live-p process) (delete-process process))))))))

(ert-deftest jal-eglot-integration/z-eglot-java-command-compatibility ()
  (skip-unless (locate-library "eglot-java"))
  (require 'eglot-java)
  (jal-eglot-integration--with-project
    (let* ((jar (expand-file-name "org.eclipse.equinox.launcher_1.jar" directory))
            (process-environment (copy-sequence process-environment))
            (eglot-java-java-program "/jdk/java")
            (eglot-java-eclipse-jdt-config-directory directory)
            (eglot-java-eclipse-jdt-cache-directory (expand-file-name "cache" directory))
            (eglot-java-eclipse-jdt-args '("-Xmx1G"))
            (eglot-server-programs
              '(((java-mode java-ts-mode) . eglot-java--eclipse-jdt-contact))))
      (with-temp-file jar)
      (setenv "CLASSPATH" jar)
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar"))))
        (let* ((result (eglot--guess-contact)) (command (nth 3 result)))
          (should (eq 'eglot-java-eclipse-jdt (nth 2 result)))
          (should (equal "-jar" (cadr (member "-javaagent:/a.jar" command))))
          (should (equal '("-Xmx1G") eglot-java-eclipse-jdt-args))
          (should (equal "/jdk/java" jal--client-java)))))))

;;; jal-eglot-integration-test.el ends here
