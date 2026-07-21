;;; init-common.el --- Shared bootstrap for JAL isolated dev environments -*- lexical-binding: t; -*-

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

;; Loaded by `init-lsp.el' and `init-eglot.el'. Provides isolation sandbox,
;; package bootstrap, project wiring, JAL load helpers, and debug commands.
;;
;; Isolation model (per client):
;;   /tmp/jal-{client}-<PID>/  session-volatile (user-emacs-directory, eln-cache)
;;   dev/env/.pkg-{client}/    persistent ELPA cache
;;   dev/env/.jdtls-{client}/  persistent JDTLS install

;;; Code:

(declare-function project-root "project" (project))
(defvar package-archives)
(defvar package-archive-contents)
(defvar project-find-functions)

(defconst jal-dev/repo-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Absolute path to `dev/env/'.")

(defconst jal-dev/project-root
  (expand-file-name "../.." jal-dev/repo-root)
  "Absolute path to the java-agent-loader repo root.")

(defvar jal-dev/tmp-dir nil
  "Session-scoped /tmp directory. Deleted on Emacs exit.")

(defvar jal-dev/example-dir nil
  "Project opened on startup. Set from `JAL_DEV_PROJECT'.")

(defvar jal-dev/client nil
  "Symbol identifying the active client: `lsp' or `eglot'.")

(defun jal-dev/bootstrap (client)
  "Initialize isolation sandbox and package.el for CLIENT (`lsp' or `eglot')."
  (setq jal-dev/client client)
  (setq jal-dev/tmp-dir
    (or (getenv "JAL_DEV_TMPDIR")
      (make-temp-file (format "jal-%s-" client) t)))
  (setq user-emacs-directory (file-name-as-directory jal-dev/tmp-dir))
  (when (boundp 'native-comp-eln-load-path)
    (setcar native-comp-eln-load-path
      (expand-file-name "eln-cache" user-emacs-directory)))
  (when (boundp 'native-comp-async-report-warnings-errors)
    (setq native-comp-async-report-warnings-errors nil))
  (add-to-list 'warning-suppress-types '(native-compiler))
  (add-hook 'kill-emacs-hook #'jal-dev--cleanup-tmp-dir)
  (jal-dev--init-packages (format ".pkg-%s" client)))

(defun jal-dev--cleanup-tmp-dir ()
  "Delete `jal-dev/tmp-dir' if it still exists."
  (when (and (stringp jal-dev/tmp-dir)
          (file-directory-p jal-dev/tmp-dir))
    (delete-directory jal-dev/tmp-dir t)
    (message "JAL dev: cleaned up %s" jal-dev/tmp-dir)))

(defun jal-dev--init-packages (pkg-subdir)
  "Bootstrap `package.el' with persistent cache in PKG-SUBDIR."
  (require 'package)
  (setq package-user-dir (expand-file-name pkg-subdir jal-dev/repo-root))
  (setq package-archives
    '(("melpa" . "https://melpa.org/packages/")
       ("gnu"   . "https://elpa.gnu.org/packages/")))
  (package-initialize)
  (unless package-archive-contents
    (package-refresh-contents))
  (unless (package-installed-p 'use-package)
    (package-install 'use-package))
  (require 'use-package))

(defun jal-dev/setup-project ()
  "Bind `project.el' to `JAL_DEV_PROJECT' and open it on startup.
Without an explicit root, VC walks up to the java-agent-loader git root
\(no pom.xml/build.gradle) and JAL skips build-tool detection."
  (setq jal-dev/example-dir
    (let ((dir (getenv "JAL_DEV_PROJECT")))
      (and dir (file-name-as-directory dir))))
  (require 'project)
  (add-to-list 'project-find-functions #'jal-dev/project-try)
  (add-hook 'emacs-startup-hook #'jal-dev/open-example))

(defun jal-dev/project-try (dir)
  "Return a transient project at `jal-dev/example-dir' if inside DIR."
  (when (and (stringp jal-dev/example-dir)
          (file-directory-p jal-dev/example-dir)
          (string-prefix-p (expand-file-name jal-dev/example-dir)
            (expand-file-name (file-name-as-directory dir))))
    (cons 'transient jal-dev/example-dir)))

(defun jal-dev/open-example ()
  "Open the project directory in Dired."
  (interactive)
  (when jal-dev/example-dir
    (dired jal-dev/example-dir)))

(defun jal-dev/announce (label)
  "Print startup banner for LABEL."
  (message "JAL %s dev env | tmp: %s | project: %s"
    label jal-dev/tmp-dir jal-dev/example-dir)
  (message "Commands: jal-dev/{open-example,show-cache,clear-cache,reset-session,show-tmp-dir}"))


;;; Debug helpers

(defvar jal-project-cache-filename)
(defvar jal--configured-scopes)

(defun jal-dev--cache-file ()
  "Return path to the JAL cache for the current project, or nil."
  (let* ((proj (project-current))
          (root (and proj (file-name-as-directory (project-root proj)))))
    (and root (expand-file-name jal-project-cache-filename root))))

(defun jal-dev/show-cache ()
  "Display the current JAL cache file content in a buffer."
  (interactive)
  (let ((cache (jal-dev--cache-file)))
    (if (and cache (file-exists-p cache))
      (find-file cache)
      (message "JAL: no cache file found for current project"))))

(defun jal-dev/clear-cache ()
  "Delete the JAL cache file for the current project."
  (interactive)
  (let ((cache (jal-dev--cache-file)))
    (if (and cache (file-exists-p cache))
      (progn
        (delete-file cache)
        (clrhash jal--configured-scopes)
        (message "JAL: cache cleared"))
      (message "JAL: no cache file to delete"))))

(defun jal-dev/reset-session ()
  "Clear JAL session state (scope guard) without deleting the cache."
  (interactive)
  (clrhash jal--configured-scopes)
  (message "JAL: session scope guard cleared"))

(defun jal-dev/show-tmp-dir ()
  "Show the /tmp sandbox path for this session."
  (interactive)
  (message "JAL dev tmp: %s" jal-dev/tmp-dir))

(provide 'init-common)
;;; init-common.el ends here
