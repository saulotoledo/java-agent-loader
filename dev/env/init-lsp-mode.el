;;; init-lsp-mode.el --- Isolated JAL + plain lsp-mode test environment -*- lexical-binding: t; -*-

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

;; ./dev/env/start-dev-env.sh lsp-mode dev/test-projects/maven
;; Installs lsp-mode without lsp-java. See init-common.el for isolation.

;;; Code:

(load (expand-file-name "init-common"
        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(jal-dev/bootstrap 'lsp-mode)

(use-package lsp-mode
  :ensure t
  :demand t
  :custom
  (lsp-client-packages nil)
  (lsp-enable-snippet nil)
  (lsp-completion-provider :none))

(defvar jal-dev/jdtls-launcher
  (jal-dev/ensure-jdtls (expand-file-name ".jdtls-lsp-mode/" jal-dev/repo-root))
  "JDTLS executable for the plain lsp-mode sandbox.")

(defun jal-dev/lsp-mode-command ()
  "Build a JDTLS command with a separate data directory per project root."
  (jal-dev/jdtls-command
    jal-dev/jdtls-launcher
    (expand-file-name ".jdtls-lsp-mode/workspace/" jal-dev/repo-root)
    default-directory))

(lsp-register-client
  (make-lsp-client
    :new-connection (lsp-stdio-connection #'jal-dev/lsp-mode-command)
    :activation-fn (lsp-activate-on "java")
    ;; JDTLS sends custom notifications that only lsp-java handles.
    :notification-handlers (ht ("language/status" #'ignore)
                             ("language/actionableNotification" #'ignore))
    :server-id 'jdtls))

(use-package jal
  :load-path jal-dev/project-root
  :custom
  (jal-auto-setup t)
  :config
  (jal-lsp-java-mode 1))

(add-hook 'java-mode-hook #'lsp-deferred)
(add-hook 'java-ts-mode-hook #'lsp-deferred)
(jal-dev/setup-project)
(jal-dev/announce "lsp-mode without lsp-java")

;;; init-lsp-mode.el ends here
