;;; init-eglot.el --- Isolated JAL + eglot-java test environment -*- lexical-binding: t; -*-

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

;; Usage: `emacs -Q -l /path/to/java-agent-loader/dev/env/init-eglot.el'
;;        or: `./dev/env/start-dev-env.sh eglot [dev/test-projects/maven]'
;;
;; See `init-common.el' for the isolation model.

;;; Code:

(load (expand-file-name "init-common"
        (file-name-directory (or load-file-name buffer-file-name)))
  nil t)

(declare-function jal-dev/bootstrap "init-common")
(declare-function jal-dev/setup-project "init-common")
(declare-function jal-dev/announce "init-common")
(defvar eglot-java-server-install-dir)
(defvar eglot-stay-out-of)
(defvar jal-dev/repo-root)

(jal-dev/bootstrap 'eglot)

(use-package eglot-java
  :ensure t
  :demand t
  :init
  (setq eglot-java-server-install-dir
    (expand-file-name ".jdtls-eglot" jal-dev/repo-root))
  :config
  (add-to-list 'eglot-stay-out-of 'company)
  :hook
  (java-mode . eglot-java-mode)
  (java-ts-mode . eglot-java-mode))

(use-package jal
  :load-path jal-dev/project-root
  :custom
  (jal-auto-setup t)
  :config
  (jal-eglot-java-mode 1))

(jal-dev/setup-project)

;; eglot-java downloads JDTLS on demand; `plugins/' marks a complete install.
(defun jal-dev/maybe-install-jdtls ()
  "Install JDTLS via eglot-java if `plugins/' is missing."
  (when (fboundp 'eglot-java-upgrade-lsp-server)
    (let ((plugins (expand-file-name "plugins" eglot-java-server-install-dir)))
      (unless (file-directory-p plugins)
        (message "JAL dev: installing JDTLS via eglot-java-upgrade-lsp-server...")
        (eglot-java-upgrade-lsp-server)))))

(add-hook 'emacs-startup-hook #'jal-dev/maybe-install-jdtls)
(jal-dev/announce "eglot")

;;; init-eglot.el ends here
