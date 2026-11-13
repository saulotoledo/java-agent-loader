;;; jal-eglot-test.el --- Eglot adapter tests -*- lexical-binding: t; -*-

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

;; Minimal stubs: real Eglot is exercised separately by the integration suite.
(defun eglot--guess-contact (&optional result) result)
(defun eglot--project (server) (plist-get server :project))

(defun jal-test--eglot-result (contact &optional project modes languages)
  "Make a resolved Eglot CONTACT with optional PROJECT, MODES and LANGUAGES."
  (list (or modes '(java-mode java-ts-mode))
    (or project '(transient . "/tmp/")) 'eglot-lsp-server
    contact (or languages '("java" "java"))))

(defmacro jal-test--with-eglot (&rest body)
  "Run BODY with the global Eglot adapter enabled and clean up afterwards."
  (declare (indent 0))
  `(unwind-protect
     (progn (jal-eglot-java-mode 1) ,@body)
     (jal-eglot-java-mode -1)))

(ert-deftest jal-test/eglot-mode-lifecycle ()
  (should-not jal-eglot-java-mode)
  (jal-test--with-eglot
    (jal-eglot-java-mode 1)
    (should (advice-member-p #'jal--eglot-guess-contact-advice 'eglot--guess-contact))
    (should (= 1 (length (delq nil (mapcar
                                     (lambda (fn) (eq fn #'jal--eglot-connect-hook-find-agents))
                                     eglot-connect-hook)))))
    (with-temp-buffer
      (setq jal--client-java "/jdk/java")
      (jal-eglot-java-mode -1)
      (should-not jal--client-java)))
  (should-not (advice-member-p #'jal--eglot-guess-contact-advice 'eglot--guess-contact))
  (should-not (memq #'jal--eglot-java-check-interface eglot-connect-hook))
  (should-not (memq #'jal--eglot-connect-hook-find-agents eglot-connect-hook))
  (should-not (memq #'jal--eglot-reconnect jal-agents-detected-hook))
  (should (= 0 (hash-table-count jal--eglot-project-contexts)))
  (let ((result (jal-test--eglot-result '("jdtls"))))
    (should (eq result (eglot--guess-contact result)))))

(ert-deftest jal-test/eglot-wrapper-preserves-contact-fields-and-initargs ()
  (let* ((contact '("jdtls" "-data" "/tmp/ws" :initializationOptions (:test 1)))
          (result (append (jal-test--eglot-result contact) '(future-field)))
          (original (copy-tree result)) (calls 0))
    (jal-test--with-functions
      ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar" "-javaagent:/b.jar")))
        (eglot--guess-contact (lambda (&rest _) (setq calls (1+ calls)) result)))
      (jal-test--with-eglot
        (with-temp-buffer
          (setq buffer-file-name "/tmp/Main.java")
          (let ((injected (eglot--guess-contact)))
            (should (= calls 1))
            (should (equal original result))
            (should (equal (nth 3 injected)
                      '("jdtls" "-data" "/tmp/ws" "--jvm-arg=-javaagent:/a.jar"
                         "--jvm-arg=-javaagent:/b.jar" :initializationOptions (:test 1))))
            (dolist (index '(0 1 2 4 5))
              (should (eq (nth index result) (nth index injected))))))))))

(ert-deftest jal-test/eglot-java-modes-and-language-id ()
  (jal-test--with-functions
    ((jal-get-vmargs-with-javaagents (lambda () '("-javaagent:/a.jar")))
      (eglot-java--find-java-program-from-alternatives
        (lambda () (ert-fail "Package-specific Java lookup must not be called"))))
    (jal-test--with-eglot
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (dolist (identity '(((java-mode) ("java")) ((java-ts-mode) ("java"))
                             ((custom-java-mode) ("java"))))
          (let* ((result (jal-test--eglot-result
                           '("/jdk/java" "-Xmx1G" "-jar" "jdtls.jar") nil
                           (car identity) (cadr identity)))
                  (injected (eglot--guess-contact result)))
            (should (equal '("/jdk/java" "-Xmx1G" "-javaagent:/a.jar" "-jar" "jdtls.jar")
                      (nth 3 injected)))
            (should (equal "/jdk/java" (jal--client-current-java)))))))))

(ert-deftest jal-test/eglot-empty-agents-still-capture-context ()
  (jal-test--with-functions ((jal-get-vmargs-with-javaagents (lambda () nil)))
    (jal-test--with-eglot
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (let ((result (jal-test--eglot-result '("jdtls" "--java-executable=/jdk/java"))))
          (should (eq result (eglot--guess-contact result)))
          (should (equal "/jdk/java" (jal--client-current-java)))
          (should (eq (current-buffer) (car (gethash (nth 1 result)
                                              jal--eglot-project-contexts)))))))))

(ert-deftest jal-test/eglot-skips-unsupported-contacts-and-clears-stale-state ()
  (jal-test--with-functions
    ((jal-get-vmargs-with-javaagents (lambda () (ert-fail "Unexpected injection"))))
    (jal-test--with-eglot
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (dolist (contact (list '("host" 1234) '("unknown") '("java" "Main")
                           '("jdtls" :autoport) '(:process custom-process)
                           (lambda () '("jdtls"))))
          (let ((result (jal-test--eglot-result contact)))
            (setq jal--client-java "/stale/java")
            (puthash (nth 1 result) (cons (current-buffer) default-directory)
              jal--eglot-project-contexts)
            (should (eq result (eglot--guess-contact result)))
            (should-not jal--client-java)
            (should-not (gethash (nth 1 result) jal--eglot-project-contexts))))
        (dolist (result (list nil '(changed-interface)
                          (jal-test--eglot-result '("python") nil '(python-mode) '("python"))
                          (jal-test--eglot-result '("jdtls") '(transient . "/ssh:host:/project/"))))
          (should (eq result (eglot--guess-contact result)))))
      (with-temp-buffer
        (let ((result (jal-test--eglot-result '("jdtls"))))
          (should (eq result (eglot--guess-contact result))))))))

(ert-deftest jal-test/eglot-reports-unsupported-java-contacts-once ()
  (jal-test--with-functions
    ((jal-get-vmargs-with-javaagents (lambda () (ert-fail "Unexpected injection"))))
    (jal-test--with-eglot
      (with-temp-buffer
        (setq buffer-file-name "/tmp/Main.java")
        (let ((messages nil))
          (cl-letf (((symbol-function 'message)
                      (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
            (dotimes (_ 2)
              (eglot--guess-contact (jal-test--eglot-result '("jdtls" :autoport)))
              (eglot--guess-contact (jal-test--eglot-result '("unknown"))))
            (eglot--guess-contact (jal-test--eglot-result '("python") nil '(python-mode) '("python"))))
          (should (= 2 (length messages)))
          (should (cl-some (lambda (m) (string-match-p ":autoport" m)) messages))
          (should (cl-every (lambda (m) (string-match-p "not injected" m)) messages))
          (jal-eglot-java-mode -1)
          (should-not jal--eglot-unsupported-reasons))))))

(ert-deftest jal-test/eglot-deferred-discovery-keeps-project-buffers ()
  (let ((first (generate-new-buffer " *jal-eglot-first*"))
         (second (generate-new-buffer " *jal-eglot-second*"))
         (scheduled nil) (found nil))
    (unwind-protect
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () nil))
          (jal--defer (lambda (fn &rest args) (push (cons fn args) scheduled)))
          (jal-find-and-configure-agents
            (lambda () (push (cons (current-buffer) (jal--current-java-key)) found))))
        (jal-test--with-eglot
          (dolist (entry (list (list first "/first/" "/jdk-one/java")
                           (list second "/second/" "/jdk-two/java")))
            (with-current-buffer (car entry)
              (setq buffer-file-name (concat (cadr entry) "Main.java"))
              (setq default-directory (cadr entry))
              (eglot--guess-contact
                (jal-test--eglot-result (list (nth 2 entry) "-jar" "jdtls.jar")
                  (cons 'transient (cadr entry))))))
          ;; Connect callbacks run after both guesses, in an unrelated buffer.
          (with-temp-buffer
            (dolist (root '("/first/" "/second/"))
              (jal--eglot-connect-hook-find-agents
                (list :project (cons 'transient root)))))
          (should (= 2 (length scheduled)))
          (dolist (call scheduled) (apply (car call) (cdr call)))
          (should (string-suffix-p "jdk-one/java" (cdr (assq first found))))
          (should (string-suffix-p "jdk-two/java" (cdr (assq second found))))
          ;; Disabling cancels already queued discovery.
          (setq found nil)
          (jal-eglot-java-mode -1)
          (dolist (call scheduled) (apply (car call) (cdr call)))
          (should-not found)))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest jal-test/eglot-java-key-prefers-startup-then-server-then-buffer ()
  (let ((project '(transient . "/tmp/")))
    (puthash project "/new-jdk/java" jal--eglot-project-java)
    (unwind-protect
      (with-temp-buffer
        (setq-local jal--client-java "/old-jdk/java")
        (jal-test--with-functions
          ((eglot-current-server (lambda () (list :project project))))
          ;; Restarted server beats the stale buffer selection.
          (should (equal "/new-jdk/java" (jal--eglot-current-java)))
          ;; A startup in progress beats the attached server.
          (let ((jal--eglot-start-buffer (current-buffer))
                 (jal--eglot-start-java "/startup/java"))
            (should (equal "/startup/java" (jal--eglot-current-java)))))
        ;; Without a server the buffer's own selection remains.
        (should (equal "/old-jdk/java" (jal--eglot-current-java))))
      (remhash project jal--eglot-project-java))))

(ert-deftest jal-test/eglot-second-buffer-and-killed-initiator-share-server-jvm ()
  (let ((first (generate-new-buffer " *jal-eglot-a*"))
         (second (generate-new-buffer " *jal-eglot-b*"))
         (scheduled nil) (seen nil)
         (project '(transient . "/proj/")))
    (unwind-protect
      (jal-test--with-functions
        ((jal-get-vmargs-with-javaagents (lambda () nil))
          (jal--defer (lambda (fn &rest args) (push (cons fn args) scheduled)))
          (eglot--managed-buffers (lambda (_) (list second)))
          (jal-find-and-configure-agents
            (lambda () (push (jal--current-java-key) seen))))
        (jal-test--with-eglot
          (with-current-buffer first
            (setq buffer-file-name "/proj/A.java" default-directory "/proj/")
            (eglot--guess-contact
              (jal-test--eglot-result '("/jdk-one/java" "-jar" "x") project)))
          (with-current-buffer second
            (setq buffer-file-name "/proj/B.java" default-directory "/proj/")
            (jal-test--with-functions
              ((eglot-current-server (lambda () (list :project project))))
              (should (equal "/jdk-one/java" (jal--eglot-current-java)))))
          ;; Initiating buffer dies before the connection completes.
          (kill-buffer first)
          (jal--eglot-connect-hook-find-agents (list :project project))
          (should (= 1 (length scheduled)))
          (dolist (call scheduled) (apply (car call) (cdr call)))
          (should (string-suffix-p "jdk-one/java" (car seen)))))
      (dolist (b (list first second)) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest jal-test/eglot-keeps-eglot-java-args-unmodified ()
  (defvar eglot-java-eclipse-jdt-args)
  (let ((eglot-java-eclipse-jdt-args (list "-Xmx1G")))
    (jal-test--with-functions
      ((jal-get-vmargs-with-javaagents (lambda () nil))
        (eglot--guess-contact
          ;; Like eglot-java: splice the shared list into a fresh command.
          (lambda (&rest _)
            (nconc (list 'x) eglot-java-eclipse-jdt-args (list "-jar" "j")))))
      (jal-test--with-eglot
        (dotimes (_ 3) (eglot--guess-contact))
        (should (equal '("-Xmx1G") eglot-java-eclipse-jdt-args))))))

(ert-deftest jal-test/eglot-resolves-java-from-launch-directory ()
  (let* ((root (make-temp-file "jal-eglot-root-" t))
          (java (expand-file-name "tools/java" root))
          (buffer (generate-new-buffer " *jal-eglot-rel*")))
    (unwind-protect
      (progn
        (make-directory (file-name-directory java) t)
        (make-directory (expand-file-name "src" root) t)
        (with-temp-file java (insert "#!/bin/sh\n"))
        (set-file-modes java #o755)
        (jal-test--with-functions
          ((jal-get-vmargs-with-javaagents (lambda () nil)))
          (jal-test--with-eglot
            (with-current-buffer buffer
              (setq buffer-file-name (expand-file-name "src/Main.java" root)
                default-directory (expand-file-name "src/" root))
              (eglot--guess-contact
                (jal-test--eglot-result '("./tools/java" "-jar" "x")
                  (cons 'transient (file-name-as-directory root))))
              (should (equal java (expand-file-name jal--client-java)))))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest jal-test/eglot-relaunch-resolves-fresh-agents ()
  (let* ((project '(transient . "/tmp/"))
          (result (jal-test--eglot-result '("jdtls") project))
          (agents '("-javaagent:/old.jar"))
          (calls nil) (scheduled nil) (relaunched nil))
    (jal-test--with-functions
      ((jal-get-vmargs-with-javaagents (lambda () agents))
        (project-current (lambda (&rest _) project))
        (eglot-current-server (lambda () 'server))
        (eglot-shutdown (lambda (&rest _) (push 'shutdown calls)))
        (eglot (lambda (&rest _) (interactive)
                 (push 'eglot calls) (setq relaunched (eglot--guess-contact result))))
        (jal--defer (lambda (fn &rest args) (setq scheduled (cons fn args)))))
      (jal-test--with-eglot
        (with-temp-buffer
          (setq buffer-file-name "/tmp/Main.java")
          (eglot--guess-contact result)
          (setq agents '("-javaagent:/new.jar"))
          (puthash "scope" t jal--configured-scopes)
          (jal--eglot-reconnect)
          (should-not calls)
          (apply (car scheduled) (cdr scheduled))
          (should (equal '(eglot shutdown) calls))
          (should (equal '("jdtls" "--jvm-arg=-javaagent:/new.jar") (nth 3 relaunched)))
          (should (= 0 (hash-table-count jal--configured-scopes)))
          (setq calls nil)
          (jal-eglot-java-mode -1)
          (apply (car scheduled) (cdr scheduled))
          (should-not calls))))))

(ert-deftest jal-test/eglot-interface-warning-is-deferred-and-once ()
  (let ((warnings nil))
    (jal-test--with-functions
      ((eglot--guess-contact nil)
        (display-warning (lambda (_type message &rest _) (push message warnings))))
      (jal-test--with-eglot
        (should-not warnings)
        (jal--eglot-java-check-interface nil)
        (jal--eglot-java-check-interface nil)
        (should (= 1 (length warnings)))
        (should (string-match-p "eglot--guess-contact" (car warnings)))))))

(provide 'jal-eglot-test)
;;; jal-eglot-test.el ends here
