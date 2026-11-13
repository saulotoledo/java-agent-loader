;;; jal-client-common.el --- Shared client helpers for Java Agent Loader (JAL) -*- lexical-binding: t; -*-

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

;; Launcher handling shared by the Java Agent Loader client adapters.

;;; Code:

(require 'seq)

(defvar-local jal--client-java nil
  "Launcher JVM selected for this buffer by the active JAL client mode.")

(defun jal--client-program (command)
  "Return the lowercase base name of COMMAND's program."
  (downcase (file-name-nondirectory (subst-char-in-string ?\\ ?/ (car command)))))

(defun jal--client-split-wrapper (command)
  "Split string list COMMAND into (WRAPPER . INNER).
WRAPPER holds the leading `emacs-lsp-booster' launcher and its flags, up to
and including `--' when flags are used. It is nil for any other command,
and for a booster command whose flags are not terminated by `--'."
  (let ((rest (and (consp command) (cdr command))))
    (if (not (and (consp command) (stringp (car command))
                  (member (jal--client-program command)
                          '("emacs-lsp-booster" "emacs-lsp-booster.exe"))))
        (cons nil command)
      (if (and rest (string-prefix-p "-" (car rest)))
          (let ((tail (member "--" rest)))
            (if tail
                (cons (butlast command (1- (length tail))) (cdr tail))
              (cons nil command)))
        (cons (list (car command)) rest)))))

(defun jal--client-command-kind (command)
  "Classify resolved COMMAND as `jdtls', `java', or nil.
Only string argument lists with a recognized injection point are supported.
A leading `emacs-lsp-booster' wrapper is looked through."
  (when (and (consp command) (proper-list-p command)
             (catch 'invalid
               (dolist (arg command) (unless (stringp arg) (throw 'invalid nil)))
               t))
    (let* ((inner (cdr (jal--client-split-wrapper command)))
           (program (and inner (jal--client-program inner))))
      (cond
       ((null inner) nil)
       ((member program '("jdtls" "jdtls.py" "jdtls.exe" "jdtls.cmd" "jdtls.bat"))
        'jdtls)
       ((and (member program '("java" "java.exe")) (member "-jar" (cdr inner)))
        'java)))))

(defun jal--client-resolve-java (program)
  "Resolve Java PROGRAM without substituting a different JVM."
  (when (and program (not (equal program "")))
    (if (file-name-absolute-p program)
        program
      (executable-find program))))

(defun jal--client-command-java (command kind)
  "Return the launcher JVM selected by COMMAND of KIND.
Explicit selections take precedence over JAVA_HOME and PATH."
  (setq command (cdr (jal--client-split-wrapper command)))
  (if (eq kind 'java)
      (jal--client-resolve-java (car command))
    (when (eq kind 'jdtls)
      (let ((args (cdr command)) (explicit nil) (program nil))
        (while args
          (let ((arg (pop args)))
            (cond
             ((string-prefix-p "--java-executable=" arg)
              (setq explicit t program (substring arg 18)))
             ((equal arg "--java-executable")
              (setq explicit t program (pop args))))))
        (if explicit
            (jal--client-resolve-java program)
          (let* ((java-home (getenv "JAVA_HOME"))
                 (candidate (and java-home
                                 (expand-file-name
                                  (if (eq system-type 'windows-nt)
                                      "bin/java.exe" "bin/java") java-home))))
            (or (and candidate (file-executable-p candidate) candidate)
                (executable-find "java"))))))))

(defun jal--client-agent-path (arg)
  "Return the normalized agent jar path when ARG is a `-javaagent:' option.
Accepts the plain form and the JDTLS wrapper's `--jvm-arg=' form, and
ignores any `=params' suffix. Return nil for other arguments."
  (let ((option (and (stringp arg)
                     (if (string-prefix-p "--jvm-arg=" arg) (substring arg 10) arg))))
    (when (and option (string-prefix-p "-javaagent:" option))
      (let* ((spec (substring option 11))
             (end (string-search "=" spec)))
        (expand-file-name (if end (substring spec 0 end) spec))))))

(defun jal--client-drop-present-agents (command vmargs)
  "Return VMARGS without agents whose jar COMMAND already loads."
  (let ((present (delq nil (mapcar #'jal--client-agent-path command))))
    (seq-remove (lambda (arg)
                  (let ((path (jal--client-agent-path arg)))
                    (and path (member path present))))
                vmargs)))

(defun jal--client-inject-vmargs (command kind vmargs)
  "Return COMMAND of KIND with VMARGS inserted, without changing input lists.
Agents whose jar COMMAND already passes as `-javaagent' are not added again.
A leading `emacs-lsp-booster' wrapper is kept in front of the result."
  (let* ((split (if (proper-list-p command)
                    (jal--client-split-wrapper command)
                  (cons nil command)))
         (wrapper (car split))
         (inner (cdr split))
         (vmargs (jal--client-drop-present-agents inner vmargs)))
    (cond
     ((null vmargs) command)
     ((eq kind 'jdtls)
      (append wrapper inner
              (mapcar (lambda (arg) (concat "--jvm-arg=" arg)) vmargs)))
     ((eq kind 'java)
      (let ((tail (member "-jar" inner)))
        (if tail
            (append wrapper (butlast inner (length tail)) vmargs tail)
          command)))
     (t command))))

(defun jal--client-current-java ()
  "Return the launcher JVM selected for this buffer."
  jal--client-java)

(defun jal--client-clear-java ()
  "Clear the active client's Java selection in all live buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (kill-local-variable 'jal--client-java))))

(provide 'jal-client-common)
;;; jal-client-common.el ends here
