;;; init-lsp-java.el --- Isolated JAL + lsp-java test environment -*- lexical-binding: t; -*-

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

;; Usage: `emacs -Q -l /path/to/java-agent-loader/dev/env/init-lsp-java.el'
;;        or: `./dev/env/start-dev-env.sh lsp-java [dev/test-projects/maven]'
;;
;; See `init-common.el' for the isolation model.

;;; Code:

(load (expand-file-name "init-common"
        (file-name-directory (or load-file-name buffer-file-name)))
  nil t)

(declare-function jal-dev/bootstrap "init-common")
(declare-function jal-dev/setup-project "init-common")
(declare-function jal-dev/announce "init-common")
(declare-function jal-dev/ensure-jdtls "init-common")
(declare-function jal-dev/jdtls-fresh-data-dir "init-common")
(defvar jal-dev/repo-root)
(defvar lsp-java-workspace-dir)

(jal-dev/bootstrap 'lsp-java)

(use-package lsp-mode
  :ensure t
  :custom
  (lsp-disabled-clients '(semgrep-ls))
  (lsp-enable-snippet nil)
  (lsp-completion-provider :none))

(defconst jal-dev/lsp-java-server-dir
  (expand-file-name ".jdtls-lsp-java/server/" jal-dev/repo-root)
  "Server directory used by lsp-java in this sandbox.")

;; lsp-java would otherwise build JDTLS with Maven on `lsp-install-server'.
;; Install the release archive into its expected directory up front.
(jal-dev/ensure-jdtls jal-dev/lsp-java-server-dir t)

(defconst jal-dev/lsp-java-workspace-base
  (expand-file-name ".jdtls-lsp-java/workspace/" jal-dev/repo-root)
  "Parent of the per-project JDT workspaces used by lsp-java in this sandbox.")

(use-package lsp-java
  :ensure t
  :demand t
  :custom
  (lsp-java-server-install-dir jal-dev/lsp-java-server-dir)
  (lsp-java-workspace-dir jal-dev/lsp-java-workspace-base)
  :hook
  (java-mode . lsp)
  (java-ts-mode . lsp))

(defun jal-dev/lsp-java-set-workspace ()
  "Give this buffer's project its own, freshly emptied JDT workspace.
lsp-java otherwise shares one `-data' directory across all projects, so a
project opened earlier can break the initialization of the next one."
  (let ((project (project-current)))
    (setq-local lsp-java-workspace-dir
                (jal-dev/jdtls-fresh-data-dir
                 jal-dev/lsp-java-workspace-base
                 (if project (project-root project) default-directory)))))

;; Run before the `lsp' entries added by `use-package' above.
(add-hook 'java-mode-hook #'jal-dev/lsp-java-set-workspace -90)
(add-hook 'java-ts-mode-hook #'jal-dev/lsp-java-set-workspace -90)

(use-package jal
  :load-path jal-dev/project-root
  :custom
  (jal-auto-setup t)
  :config
  (jal-lsp-java-mode 1))

(jal-dev/setup-project)
(jal-dev/announce "lsp-java")

;;; init-lsp-java.el ends here
