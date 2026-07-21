;;; init-lsp.el --- Isolated JAL + lsp-java test environment -*- lexical-binding: t; -*-

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

;; Usage: `emacs -Q -l /path/to/java-agent-loader/dev/env/init-lsp.el'
;;        or: `./dev/env/start-dev-env.sh lsp [dev/test-projects/maven]'
;;
;; See `init-common.el' for the isolation model.

;;; Code:

(load (expand-file-name "init-common"
        (file-name-directory (or load-file-name buffer-file-name)))
  nil t)

(declare-function jal-dev/bootstrap "init-common")
(declare-function jal-dev/setup-project "init-common")
(declare-function jal-dev/announce "init-common")

(jal-dev/bootstrap 'lsp)

(use-package lsp-mode
  :ensure t
  :custom
  (lsp-disabled-clients '(semgrep-ls))
  (lsp-enable-snippet nil)
  (lsp-completion-provider :none))

(use-package lsp-java
  :ensure t
  :demand t
  :custom
  (lsp-java-server-install-dir
    (expand-file-name ".jdtls-lsp/server/" jal-dev/repo-root))
  (lsp-java-workspace-dir
    (expand-file-name ".jdtls-lsp/workspace/" jal-dev/repo-root))
  :hook
  (java-mode . lsp)
  (java-ts-mode . lsp))

(use-package jal
  :load-path jal-dev/project-root
  :custom
  (jal-auto-setup t)
  :config
  (jal-lsp-java-mode 1))

(jal-dev/setup-project)
(jal-dev/announce "lsp-java")

;;; init-lsp.el ends here
