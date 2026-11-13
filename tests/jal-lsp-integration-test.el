;;; jal-lsp-integration-test.el --- Tests with installed lsp-mode -*- lexical-binding: t; -*-

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;; Author: Saulo Toledo <saulotoledo@gmail.com>


;; Run separately from the dependency-free suite, with lsp-mode on load-path.
;; No JDTLS download or Java process is required.

(require 'ert)
(require 'jal-client-lsp)
(load (expand-file-name "jal-test-functions.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;; Exercise enabling before lsp-mode defines the advised functions.
(jal-lsp-java-mode 1)
(require 'lsp-mode)

(ert-deftest jal-integration/enable-before-framework-load ()
  (should (advice-member-p #'jal--lsp-start-workspace-advice 'lsp--start-workspace))
  (should (advice-member-p #'jal--lsp-resolve-command-advice 'lsp-resolve-final-command))
  (should-not (featurep 'lsp-java)))

(ert-deftest jal-integration/real-resolver ()
  (unwind-protect
    (progn
      (jal-lsp-java-mode 1)
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/agent.jar"))))
        (with-temp-buffer
          (setq buffer-file-name "/tmp/Main.java")
          (let ((jal--lsp-start-buffer (current-buffer))
                 (command '("jdtls" nil "-data" "/tmp/ws"))
                 (calls 0))
            (should (equal '("jdtls" "-data" "/tmp/ws" "--jvm-arg=-javaagent:/agent.jar")
                      (lsp-resolve-final-command command)))
            (should (equal '("jdtls" nil "-data" "/tmp/ws") command))
            (should (equal '("java" "-Xmx1G" "-javaagent:/agent.jar" "-jar" "x")
                      (lsp-resolve-final-command
                        (lambda () (setq calls (1+ calls))
                          '("java" "-Xmx1G" "-jar" "x")))))
            (should (= calls 1))
            (should (equal '("jdtls") (lsp-resolve-final-command "jdtls" t)))
            (should-error (lsp-resolve-final-command '("jdtls" 3)))
            (should-error (lsp-resolve-final-command (lambda () (error "failed"))))))))
    (jal-lsp-java-mode -1)))

(ert-deftest jal-integration/real-startup-and-stdio-transports ()
  (let ((directory (make-temp-file "jal-lsp-integration-" t))
         (original-make-process (symbol-function 'make-process))
         (processes nil))
    (unwind-protect
      (progn
        (jal-lsp-java-mode 1)
        (jal-test--with-functions
          ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/agent.jar")))
            (lsp--spinner-start #'ignore)
            ;; Initialization stays pending: we are checking actual startup
            ;; and command transport, not implementing a fake Java server.
            (lsp-request-async (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "Main.java" directory))
            (setq default-directory (file-name-as-directory directory))
            (dolist (native '(nil t))
              (let* ((seen nil)
                      (client (make-lsp-client
                                :server-id 'jdtls
                                :new-connection (lsp-stdio-connection '("jdtls"))))
                      (session (make-lsp-session)))
                (jal-test--with-functions
                  ((json-rpc-connection (and native #'ignore))
                    (lsp-json-rpc-connection
                      (lambda (_workspace command)
                        (setq seen command)
                        (cons 'native-process 'native-process)))
                    (make-process
                      (lambda (&rest args)
                        (setq seen (plist-get args :command))
                        ;; Exercise the ordinary transport's real process and
                        ;; stderr handling using cat instead of launching Java.
                        (let ((proc (apply original-make-process
                                      (plist-put args :command '("cat")))))
                          (push proc processes)
                          proc))))
                  (let ((workspace (lsp--start-workspace session client default-directory)))
                    (should (equal '("jdtls" "--jvm-arg=-javaagent:/agent.jar") seen))
                    (should (eq (car (gethash workspace jal--lsp-workspace-contexts))
                              (current-buffer)))
                    (should (eq 'jdtls (lsp--workspace-server-id workspace))))))))))
      (jal-lsp-java-mode -1)
      (dolist (proc processes)
        (set-process-sentinel proc #'ignore)
        (when (process-live-p proc) (delete-process proc)))
      (dolist (buffer (buffer-list))
        (when (string-prefix-p "*jdtls" (buffer-name buffer)) (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest jal-integration/z-lsp-java-command-compatibility ()
  (skip-unless (locate-library "lsp-java"))
  (require 'lsp-java)
  (let* ((directory (make-temp-file "jal-lsp-java-test-" t))
          (lsp-java-server-install-dir directory)
          (lsp-java-server-config-dir directory)
          (lsp-java-workspace-dir (expand-file-name "workspace" directory))
          (lsp-java-java-path "java")
          (lsp-java-vmargs '("-Xmx1G")))
    (unwind-protect
      (progn
        (make-directory (expand-file-name "plugins" directory))
        (with-temp-file (expand-file-name "plugins/org.eclipse.equinox.launcher_1.jar" directory))
        (make-directory (expand-file-name "bin" directory))
        (let ((launcher (expand-file-name "bin/jdtls" directory)))
          (with-temp-file launcher (insert "#!/bin/sh\n"))
          (set-file-modes launcher #o755))
        (jal-lsp-java-mode 1)
        (jal-test--with-functions
          ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/agent.jar")))
            (lsp-java--java-9-plus-p (lambda () nil)))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "Main.java" directory))
            (let ((jal--lsp-start-buffer (current-buffer)))
              (dolist (native '(nil t))
                (let* ((lsp-java-jdt-ls-prefer-native-command native)
                        (command (lsp-resolve-final-command #'lsp-java--ls-command)))
                  (should (member (if native "--jvm-arg=-javaagent:/agent.jar"
                                    "-javaagent:/agent.jar") command))
                  (should (equal '("-Xmx1G") lsp-java-vmargs))))))))
      (jal-lsp-java-mode -1)
      (delete-directory directory t))))

;;; jal-lsp-integration-test.el ends here
