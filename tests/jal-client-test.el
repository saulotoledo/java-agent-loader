;;; jal-client-test.el --- Client adapter tests -*- lexical-binding: t; -*-

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


(require 'ert)
(require 'jal-client-lsp)

(load (expand-file-name "jal-test-functions.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;; Minimal framework stubs keep the main suite independent of lsp-mode.
;; Actual lsp-mode transport paths are covered in jal-lsp-integration-test.el.
(defvar lsp--cur-workspace nil)
(defun lsp-resolve-value (value)
  (if (functionp value) (funcall value) value))
(defun lsp-resolve-final-command (command &optional _test)
  (let ((value (lsp-resolve-value command)))
    (cond ((stringp value) (list value))
      ((and (listp value) (proper-list-p value))
        (setq value (delq nil value))
        (dolist (arg value) (unless (stringp arg) (error "Invalid command")))
        value)
      (t (error "Invalid command")))))
(defun lsp--client-server-id (client) client)
(defun lsp--workspace-server-id (workspace) (plist-get workspace :server))
(defun lsp--workspace-root (workspace) (plist-get workspace :root))
(defun lsp--start-workspace (_session client root &optional command)
  (let ((default-directory root))
    (list :server client :root root
      :command (lsp-resolve-final-command command))))

(defmacro jal-test--with-lsp (&rest body)
  "Run BODY with JAL's lsp-mode adapter enabled and clean it up."
  (declare (indent 0))
  `(unwind-protect
     (progn (jal-lsp-java-mode 1) ,@body)
     (jal-lsp-java-mode -1)))

(ert-deftest jal-test/client-command-kinds ()
  (dolist (program '("jdtls" "/opt/bin/jdtls.py" "C:\\bin\\jdtls.cmd" "jdtls.exe"))
    (should (eq 'jdtls (jal--client-command-kind (list program)))))
  (should (eq 'java (jal--client-command-kind '("/jdk/bin/java" "-jar" "jdtls.jar"))))
  (should (eq 'java (jal--client-command-kind '("C:\\jdk\\java.exe" "-jar" "jdtls.jar"))))
  (dolist (command '(nil "jdtls" ("host" 123) ("java" "Main")
                      ("unknown" "-jar" "jdtls.jar") ("wrapper") ("jdtls" nil)))
    (should-not (jal--client-command-kind command))))

(ert-deftest jal-test/client-injection-is-pure ()
  (let ((agents '("-javaagent:/a.jar" "-javaagent:/b.jar=x")))
    (dolist (command '(("jdtls" "-data" "/tmp/ws")
                        ("java" "-Xmx1G" "-jar" "jdtls.jar" "-data" "/tmp/ws")))
      (let* ((original (copy-sequence command))
              (kind (jal--client-command-kind command))
              (result (jal--client-inject-vmargs command kind agents)))
        (should (equal original command))
        (should (equal result
                  (if (eq kind 'jdtls)
                    '("jdtls" "-data" "/tmp/ws" "--jvm-arg=-javaagent:/a.jar"
                       "--jvm-arg=-javaagent:/b.jar=x")
                    '("java" "-Xmx1G" "-javaagent:/a.jar" "-javaagent:/b.jar=x"
                       "-jar" "jdtls.jar" "-data" "/tmp/ws"))))
        (should (eq command (jal--client-inject-vmargs command kind nil)))))
    (should (equal '("unknown") (jal--client-inject-vmargs '("unknown") nil agents)))))

(ert-deftest jal-test/client-injection-skips-agents-already-present ()
  (let ((agents '("-javaagent:/a.jar" "-javaagent:/b.jar=x" "-Dflag=1")))
    ;; JDTLS wrapper form, with params on the existing agent.
    (should (equal '("jdtls" "--jvm-arg=-javaagent:/a.jar=p"
                      "--jvm-arg=-javaagent:/b.jar=x" "--jvm-arg=-Dflag=1")
              (jal--client-inject-vmargs
                '("jdtls" "--jvm-arg=-javaagent:/a.jar=p") 'jdtls agents)))
    ;; Plain JVM form.
    (should (equal '("java" "-javaagent:/b.jar" "-javaagent:/a.jar" "-Dflag=1" "-jar" "x.jar")
              (jal--client-inject-vmargs
                '("java" "-javaagent:/b.jar" "-jar" "x.jar")
                'java '("-javaagent:/a.jar" "-javaagent:/b.jar=x" "-Dflag=1"))))
    ;; Everything present: command is returned unchanged.
    (let ((command '("jdtls" "--jvm-arg=-javaagent:/a.jar" "--jvm-arg=-javaagent:/b.jar")))
      (should (eq command (jal--client-inject-vmargs
                            command 'jdtls '("-javaagent:/a.jar" "-javaagent:/b.jar=x")))))
    ;; Different jar path is not treated as present.
    (should (equal '("jdtls" "--jvm-arg=-javaagent:/other/a.jar" "--jvm-arg=-javaagent:/a.jar")
              (jal--client-inject-vmargs
                '("jdtls" "--jvm-arg=-javaagent:/other/a.jar") 'jdtls '("-javaagent:/a.jar"))))))

(ert-deftest jal-test/client-looks-through-lsp-booster-wrapper ()
  (let ((agents '("-javaagent:/a.jar")))
    ;; Wrapper form produced by the emacs-lsp-booster README advice.
    (let ((command '("emacs-lsp-booster" "/usr/bin/jdtls" "-data" "/ws")))
      (should (eq 'jdtls (jal--client-command-kind command)))
      (should (equal '("emacs-lsp-booster" "/usr/bin/jdtls" "-data" "/ws"
                        "--jvm-arg=-javaagent:/a.jar")
                (jal--client-inject-vmargs command 'jdtls agents))))
    ;; Wrapper with flags terminated by `--', around a direct java launch.
    (let ((command '("/bin/emacs-lsp-booster" "--verbose" "--" "java" "-jar" "j.jar")))
      (should (eq 'java (jal--client-command-kind command)))
      (should (equal '("/bin/emacs-lsp-booster" "--verbose" "--" "java"
                        "-javaagent:/a.jar" "-jar" "j.jar")
                (jal--client-inject-vmargs command 'java agents))))
    ;; The wrapped command's explicit JVM is the selected one.
    (should (equal "/jdk/bin/java"
              (jal--client-command-java
                '("emacs-lsp-booster" "jdtls" "--java-executable=/jdk/bin/java") 'jdtls)))
    ;; Agent already present inside the wrapped command: nothing added.
    (let ((command '("emacs-lsp-booster" "jdtls" "--jvm-arg=-javaagent:/a.jar")))
      (should (eq command (jal--client-inject-vmargs command 'jdtls agents))))
    ;; Unrecognized wrapper forms and wrapped unknown programs stay unsupported.
    (dolist (command '(("emacs-lsp-booster" "--flag" "jdtls")
                        ("emacs-lsp-booster" "unknown")
                        ("emacs-lsp-booster")))
      (should-not (jal--client-command-kind command)))
    (should-not (jal--client-command-java nil nil))
    (should-not (jal--client-command-java "jdtls" nil))))

(ert-deftest jal-test/client-java-precedence ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "JAVA_HOME" "/jdk-home")
    (jal-test--with-functions
      ((file-executable-p (lambda (path) (equal path "/jdk-home/bin/java")))
        (executable-find (lambda (program) (concat "/path/" program))))
      (should (equal "/jdk-home/bin/java" (jal--client-command-java '("jdtls") 'jdtls)))
      (should (equal "/explicit/java" (jal--client-command-java
                                        '("jdtls" "--java-executable=/explicit/java") 'jdtls)))
      (should (equal "/path/custom-java" (jal--client-command-java
                                           '("jdtls" "--java-executable" "custom-java") 'jdtls)))
      (should (equal "/path/java" (jal--client-command-java '("java" "-jar" "x") 'java)))
      (should (equal "/direct/java" (jal--client-command-java
                                      '("/direct/java" "-jar" "x") 'java)))
      (setenv "JAVA_HOME" "/missing")
      (should (equal "/path/java" (jal--client-command-java '("jdtls") 'jdtls)))
      (let ((system-type 'windows-nt))
        (jal-test--with-functions ((file-executable-p (lambda (path)
                                                        (equal path "/missing/bin/java.exe"))))
          (should (equal "/missing/bin/java.exe"
                    (jal--client-command-java '("jdtls.exe") 'jdtls))))))))

(ert-deftest jal-test/lsp-mode-lifecycle ()
  (should-not jal-lsp-java-mode)
  (jal-test--with-lsp
    (jal-lsp-java-mode 1)
    (should (advice-member-p #'jal--lsp-start-workspace-advice 'lsp--start-workspace))
    (should (advice-member-p #'jal--lsp-resolve-command-advice 'lsp-resolve-final-command))
    (should (= 1 (length (delq nil (mapcar
                                     (lambda (fn) (eq fn #'jal--lsp-after-initialize-find-agents))
                                     lsp-after-initialize-hook)))))
    (with-temp-buffer
      (setq jal--client-java "/jdk/java")
      (jal-lsp-java-mode -1)
      (should-not (jal--client-current-java))))
  (should-not (advice-member-p #'jal--lsp-start-workspace-advice 'lsp--start-workspace))
  (should-not (advice-member-p #'jal--lsp-resolve-command-advice 'lsp-resolve-final-command))
  (should-not (memq #'jal--lsp-after-initialize-find-agents lsp-after-initialize-hook))
  (should-not (memq #'jal--lsp-java-restart jal-agents-detected-hook))
  (should (equal '("jdtls") (lsp-resolve-final-command '("jdtls")))))

(ert-deftest jal-test/lsp-injects-resolved-commands-once ()
  (let ((calls 0) (discoveries 0) (command '("jdtls" nil "-data" "/tmp/ws")))
    (jal-test--with-functions
      ((jal-get-vmargs-with-javaagents
         (lambda () (setq discoveries (1+ discoveries)) '("-javaagent:/a.jar"))))
      (jal-test--with-lsp
        (with-temp-buffer
          (setq buffer-file-name "/tmp/Main.java")
          (dolist (value (list "jdtls" command
                           (lambda () (setq calls (1+ calls)) '("java" "-jar" "x"))))
            (let ((result (lsp--start-workspace nil 'jdtls default-directory value)))
              (should (member (if (functionp value) "-javaagent:/a.jar"
                                "--jvm-arg=-javaagent:/a.jar")
                        (plist-get result :command)))))
          (should (= calls 1))
          (should (= discoveries 3))
          (should (equal command '("jdtls" nil "-data" "/tmp/ws")))
          (should-error (lsp--start-workspace nil 'jdtls default-directory
                          (lambda () (error "command failed"))))
          (should-error (lsp--start-workspace nil 'jdtls default-directory '("jdtls" 3)))
          (should (= discoveries 3)))))))

(ert-deftest jal-test/lsp-loads-cached-agents-with-the-selected-jvm ()
  (jal-test--with-temp-project "pom.xml" "<project/>"
    (let* ((root (file-name-as-directory dir))
            (jar (expand-file-name "agent.jar" root))
            (java (expand-file-name "java" root))
            (project-find-functions
              (list (lambda (_directory) (cons 'transient root)))))
      (with-temp-file jar)
      (with-temp-file (expand-file-name jal-project-cache-filename root)
        (prin1 (list (list java (list (list "lombok" jar "" "test"))))
          (current-buffer)))
      (jal-test--with-lsp
        (with-temp-buffer
          (setq buffer-file-name (expand-file-name "Main.java" root))
          (let* ((command (list java "-jar" "jdtls.jar"))
                  (workspace (lsp--start-workspace nil 'jdtls root command)))
            (should (member (concat "-javaagent:" jar) (plist-get workspace :command)))
            (should (equal java (jal--current-java-key)))))))))

(ert-deftest jal-test/lsp-skips-unrelated-launches-and-probes ()
  (jal-test--with-functions
    ((jal-get-vmargs-with-javaagents (lambda () (ert-fail "Unexpected injection"))))
    (jal-test--with-lsp
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (lsp--start-workspace nil 'python default-directory '("jdtls"))
        (lsp--start-workspace nil 'jdtls "/ssh:host:/project/" '("jdtls"))
        (dolist (command '(("unknown") ("java" "Main")))
          (lsp--start-workspace nil 'jdtls default-directory command))
        (let ((jal--lsp-start-buffer (current-buffer)))
          (should (equal '("jdtls") (lsp-resolve-final-command '("jdtls") t))))))))

(ert-deftest jal-test/lsp-honors-custom-server-ids ()
  (jal-test--with-functions
    ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar"))))
    (jal-test--with-lsp
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (let ((jal-lsp-server-ids '(jdtls my-jdtls)))
          (let ((workspace (lsp--start-workspace
                             nil 'my-jdtls default-directory '("jdtls"))))
            (should (gethash workspace jal--lsp-workspace-contexts))))
        (let ((jal-lsp-server-ids '(jdtls)))
          (let ((workspace (lsp--start-workspace
                             nil 'my-jdtls default-directory '("jdtls"))))
            (should-not (gethash workspace jal--lsp-workspace-contexts))))))))

(ert-deftest jal-test/lsp-retains-buffer-and-java-for-deferred-detection ()
  (let ((first (generate-new-buffer " *jal-first*"))
         (second (generate-new-buffer " *jal-second*"))
         (contexts nil))
    (unwind-protect
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () nil)))
        (jal-test--with-lsp
          (dolist (entry (list (cons first "/jdk-one/java") (cons second "/jdk-two/java")))
            (with-current-buffer (car entry)
              (setq buffer-file-name "/tmp/Main.java")
              (let ((workspace (lsp--start-workspace
                                 nil 'jdtls default-directory (list (cdr entry) "-jar" "x"))))
                (push (cons workspace (car entry)) contexts))))
          (with-temp-buffer
            (dolist (entry contexts)
              (let ((lsp--cur-workspace (car entry)))
                (jal-test--with-functions
                  ((jal--defer-in-buffer
                     (lambda (buffer directory fn &rest _)
                       (should (eq buffer (cdr entry)))
                       (should (equal directory (buffer-local-value 'default-directory buffer)))
                       (with-current-buffer buffer
                         (should (equal (jal--client-current-java)
                                   (if (eq buffer first) "/jdk-one/java" "/jdk-two/java"))))
                       (let ((called nil))
                         (jal-test--with-functions
                           ((jal-find-and-configure-agents (lambda () (setq called t))))
                           (funcall fn))
                         (should called)))))
                  (jal--lsp-after-initialize-find-agents)))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest jal-test/lsp-java-key-follows-workspace-not-buffer ()
  (let ((first (generate-new-buffer "A.java"))
         (second (generate-new-buffer "B.java")))
    (unwind-protect
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () nil)))
        (jal-test--with-lsp
          (with-current-buffer first
            (setq buffer-file-name "/tmp/A.java")
            (let ((workspace (lsp--start-workspace
                               nil 'jdtls default-directory
                               (list "/jdk-one/java" "-jar" "x"))))
              (jal-test--with-functions
                ((lsp-workspaces (lambda () (list workspace))))
                (should (equal (jal--lsp-current-java) "/jdk-one/java"))
                ;; Another buffer attached to the same workspace.
                (with-current-buffer second
                  (should (equal (jal--lsp-current-java) "/jdk-one/java")))
                ;; Initiating buffer's local state gone.
                (kill-local-variable 'jal--client-java)
                (should (equal (jal--lsp-current-java) "/jdk-one/java")))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest jal-test/lsp-java-key-prefers-startup-over-workspace ()
  (let ((workspace (list :ws))
         (jal--lsp-start-buffer (current-buffer))
         (jal--lsp-start-java "/new-jdk/bin/java"))
    (puthash workspace "/old-jdk/bin/java" jal--lsp-workspace-java)
    (jal-test--with-functions
      ((lsp-workspaces (lambda () (list workspace)))
        (jal--lsp-jdtls-workspace-p (lambda (_) t)))
      (should (equal (jal--lsp-current-java) "/new-jdk/bin/java"))
      (let ((jal--lsp-start-buffer nil))
        (should (equal (jal--lsp-current-java) "/old-jdk/bin/java"))))))

(ert-deftest jal-test/lsp-deferred-discovery-uses-initializing-workspace-jvm ()
  (let ((buffer (generate-new-buffer "A.java")))
    (unwind-protect
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () nil)))
        (jal-test--with-lsp
          (with-current-buffer buffer
            (setq buffer-file-name "/tmp/A.java")
            (let* ((first (lsp--start-workspace
                            nil 'jdtls default-directory
                            (list "/jdk-first/java" "-jar" "x")))
                    (second (lsp--start-workspace
                              nil 'jdtls default-directory
                              (list "/jdk-second/java" "-jar" "x")))
                    (lsp--cur-workspace first)
                    (seen nil))
              (ignore second)
              (jal-test--with-functions
                ((lsp-workspaces (lambda () (list second first)))
                  (jal--defer-in-buffer
                    (lambda (b _d fn &rest _)
                      (with-current-buffer b (funcall fn))))
                  (jal-find-and-configure-agents
                    (lambda () (setq seen (jal--current-java-key)))))
                (jal--lsp-after-initialize-find-agents))
              (should (string-suffix-p "jdk-first/java" seen))))))
      (kill-buffer buffer))))

(ert-deftest jal-test/lsp-java-key-prefers-attached-workspace-over-stale-buffer ()
  (let ((workspace (list :ws)))
    (puthash workspace "/new-jdk/bin/java" jal--lsp-workspace-java)
    (setq-local jal--client-java "/old-jdk/bin/java")
    (unwind-protect
      (jal-test--with-functions
        ((lsp-workspaces (lambda () (list workspace)))
          (jal--lsp-jdtls-workspace-p (lambda (_) t)))
        (should (equal (jal--lsp-current-java) "/new-jdk/bin/java")))
      (kill-local-variable 'jal--client-java))))

(ert-deftest jal-test/lsp-resolves-relative-paths-from-workspace-root ()
  (let* ((root (file-name-as-directory (make-temp-file "jal-lsp-root-" t)))
          (java (expand-file-name "tools/java" root))
          (agent (expand-file-name "agents/a.jar" root))
          (buffer (generate-new-buffer "Main.java"))
          (result nil))
    (unwind-protect
      (progn
        (make-directory (file-name-directory java) t)
        (with-temp-file java (insert "#!/bin/sh\n"))
        (set-file-modes java #o755)
        (jal-test--with-functions
          ((jal-get-vmargs-with-javaagents
             (lambda () (list (concat "-javaagent:" agent)))))
          (jal-test--with-lsp
            (with-current-buffer buffer
              (setq buffer-file-name (expand-file-name "src/Main.java" root)
                default-directory (expand-file-name "src/" root))
              (let ((workspace (lsp--start-workspace
                                 nil 'jdtls root
                                 (list "./tools/java" "-jar" "x"
                                   "-javaagent:agents/a.jar"))))
                (setq result (gethash workspace jal--lsp-workspace-java)))))
          (should (equal java result))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest jal-test/lsp-restart-filters-session-and-defers ()
  (let* ((java (list :server 'jdtls :root "/tmp/"))
          (other (list :server 'python :root "/tmp/"))
          (remote (list :server 'jdtls :root "/ssh:host:/tmp/"))
          (restarted nil) (scheduled nil)
          (jal--configured-scopes (make-hash-table :test 'equal)))
    (jal-test--with-functions
      ((lsp-workspaces (lambda () nil))
        (lsp-session (lambda () 'session))
        (lsp--session-workspaces (lambda (_) (list java other remote)))
        (lsp-workspace-restart (lambda (ws) (push ws restarted)))
        (jal--defer (lambda (fn &rest args) (setq scheduled (cons fn args)))))
      (jal-test--with-lsp
        (should (equal (list java) (jal--lsp-java-workspaces)))
        (jal--lsp-java-restart)
        (should (eq (car scheduled) #'jal--lsp-java-restart-now))
        (should (equal (cdr scheduled) (list (list java))))
        (should-not restarted)
        (puthash "scope" t jal--configured-scopes)
        (jal--lsp-java-restart-now (list java other remote))
        (should (equal restarted (list java)))
        (should (= 0 (hash-table-count jal--configured-scopes)))))))

(ert-deftest jal-test/lsp-interface-warning-is-deferred-and-once ()
  (let ((warnings nil))
    (jal-test--with-functions
      ((lsp--start-workspace nil)
        (display-warning (lambda (_type message &rest _) (push message warnings))))
      (jal-test--with-lsp
        (should-not warnings)
        ;; Simulate removal by a dependency update after advice was installed.
        (fset 'lsp--start-workspace nil)
        (jal--lsp-java-check-interface)
        (jal--lsp-java-check-interface)
        (should (= 1 (length warnings)))
        (should (string-match-p "lsp--start-workspace" (car warnings)))))))

(ert-deftest jal-test/lsp-pending-discovery-cancels-on-disable ()
  (let ((deferred nil)
         (workspace (list :server 'jdtls :root "/tmp/")))
    (jal-test--with-lsp
      (with-temp-buffer
        (puthash workspace (cons (current-buffer) default-directory)
          jal--lsp-workspace-contexts)
        (let ((lsp--cur-workspace workspace))
          (jal-test--with-functions
            ((jal--defer-in-buffer (lambda (_buffer _directory fn &rest _)
                                     (setq deferred fn))))
            (jal--lsp-after-initialize-find-agents)))
        (should deferred)
        (jal-lsp-java-mode -1)
        (jal-test--with-functions
          ((jal-find-and-configure-agents (lambda () (ert-fail "Mode disabled"))))
          (funcall deferred))))))

(load (expand-file-name "../dev/env/init-common.el"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest jal-test/dev-jdtls-lookup-and-cached-install ()
  (let ((directory (make-temp-file "jal-jdtls-test-" t)))
    (unwind-protect
      (progn
        (jal-test--with-functions ((executable-find (lambda (_) "/path/jdtls")))
          (should (equal "/path/jdtls" (jal-dev/ensure-jdtls directory))))
        (make-directory (expand-file-name "bin" directory))
        (make-directory (expand-file-name "plugins" directory))
        (let ((launcher (expand-file-name "bin/jdtls" directory)))
          (with-temp-file launcher (insert "#!/bin/sh\n"))
          (set-file-modes launcher #o755)
          (jal-test--with-functions ((executable-find (lambda (_) "/path/jdtls")))
            (should (equal launcher (jal-dev/ensure-jdtls directory t))))
          (jal-test--with-functions ((executable-find (lambda (_) nil)))
            (should (equal launcher (jal-dev/ensure-jdtls directory))))))
      (delete-directory directory t))))

(ert-deftest jal-test/dev-jdtls-download-cleans-archive-on-error ()
  (require 'url-handlers)
  (let ((directory (make-temp-file "jal-jdtls-test-" t)) (archive nil))
    (unwind-protect
      (jal-test--with-functions
        ((executable-find (lambda (program) (and (equal program "tar") "/bin/tar")))
          (url-copy-file (lambda (_url file &rest _)
                           (setq archive file) (error "download failed"))))
        (should-error (jal-dev/ensure-jdtls directory))
        (should archive)
        (should-not (file-exists-p archive)))
      (delete-directory directory t))))

(ert-deftest jal-test/dev-jdtls-data-dir-is-per-project-and-stable ()
  (let ((base "/tmp/ws/"))
    (should (equal (jal-dev/jdtls-data-dir base "/a/app/")
              (jal-dev/jdtls-data-dir base "/a/app/")))
    (should-not (equal (jal-dev/jdtls-data-dir base "/a/app/")
                  (jal-dev/jdtls-data-dir base "/b/app/")))
    (should (string-prefix-p base (jal-dev/jdtls-data-dir base "/a/app/")))))

(ert-deftest jal-test/dev-jdtls-fresh-data-dir-resets-once-per-session ()
  (let* ((base (file-name-as-directory (make-temp-file "jal-fresh-test-" t)))
          (jal-dev--fresh-data-dirs (make-hash-table :test 'equal))
          (data (jal-dev/jdtls-data-dir base "/proj/"))
          (marker (expand-file-name "stale" data)))
    (unwind-protect
      (progn
        (make-directory data t)
        (with-temp-file marker (insert "x"))
        (should (equal data (jal-dev/jdtls-fresh-data-dir base "/proj/")))
        (should-not (file-exists-p marker))
        (make-directory data t)
        (with-temp-file marker (insert "x"))
        (jal-dev/jdtls-fresh-data-dir base "/proj/")
        (should (file-exists-p marker)))
      (delete-directory base t))))

(ert-deftest jal-test/dev-jdtls-workspaces-distinguish-equal-project-names ()
  (let ((directory (make-temp-file "jal-data-test-" t)))
    (unwind-protect
      (let ((first (jal-dev/jdtls-command "/bin/jdtls" directory "/first/service/"))
             (second (jal-dev/jdtls-command "/bin/jdtls" directory "/second/service/")))
        (should (equal (butlast first) '("/bin/jdtls" "-data")))
        (should-not (equal first second))
        (should (file-directory-p (nth 2 first)))
        (should (file-directory-p (nth 2 second)))
        (should (equal first (jal-dev/jdtls-command "/bin/jdtls" directory "/first/service/"))))
      (delete-directory directory t))))

(provide 'jal-client-test)
;;; jal-client-test.el ends here
