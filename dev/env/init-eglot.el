;;; init-eglot.el --- Isolated JAL + plain Eglot test environment -*- lexical-binding: t; -*-

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

;; ./dev/env/start-dev-env.sh eglot dev/test-projects/maven
;; Uses Eglot without eglot-java. See init-common.el for isolation.

;;; Code:

(load (expand-file-name "init-common"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(jal-dev/bootstrap 'eglot)

(use-package eglot
  :ensure nil
  :demand t
  :config
  (add-to-list 'eglot-stay-out-of 'company))

(defvar jal-dev/jdtls-launcher
  (jal-dev/ensure-jdtls (expand-file-name ".jdtls-eglot/" jal-dev/repo-root))
  "JDTLS executable for the plain Eglot sandbox.")

(defun jal-dev/eglot-contact (_interactive project)
  "Build a JDTLS contact with a separate data directory for PROJECT."
  (jal-dev/jdtls-command
    jal-dev/jdtls-launcher
    (expand-file-name ".jdtls-eglot/workspace/" jal-dev/repo-root)
    (project-root project)))

(add-to-list 'eglot-server-programs
  '((java-mode java-ts-mode) . jal-dev/eglot-contact))

(use-package jal
  :load-path jal-dev/project-root
  :custom
  (jal-auto-setup t)
  :config
  (jal-eglot-java-mode 1))

(add-hook 'java-mode-hook #'eglot-ensure)
(add-hook 'java-ts-mode-hook #'eglot-ensure)
(jal-dev/setup-project)
(jal-dev/announce "Eglot without eglot-java")

;;; init-eglot.el ends here
