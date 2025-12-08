;;; jal-vars.el --- Variables for Java Agent Loader -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>

;;; Commentary:
;; Variables and constants for jal.

;;; Code:

(defvar jal--feature-supported-p t
  "Internal predicate indicating if all required external features (project)
were successfully loaded.  Set to nil if any prerequisite is missing.
Use only within `jal' functions; do not reference externally.")

(defcustom jal-project-cache-filename ".jal-config.el"
  "Name of the file storing project-specific JAL config in the project root."
  :type 'string
  :group 'jal)

(defcustom jal-agents-config nil
  "List of agents to detect.
Elements can be:
- (ARTIFACT-ID . PROPS) : Specify properties.
- (ARTIFACT-ID)         : Use defaults (no properties).

PROPS is a property list supporting the following keys:
  :params   - Optional string of arguments to append (e.g., \"=destfile=...\").
  :jar-path - Optional format string for the JAR filename OR an absolute path.
              If it starts with \"/\", it is treated as an absolute path.
              Otherwise, it is treated as a pattern relative to the local
              repository.
              Pattern placeholders: %a = artifactId, %v = version, %g = groupId.
              Default: \"%a-%v.jar\"."
  :type '(alist :key-type string :value-type (plist :key-type symbol :value-type (choice string (const :tag "None" nil))))
  :group 'jal)

(defcustom jal-agents-detected-hook nil
  "Hook run after agents are successfully detected and cached.
This is useful for restarting the LSP/Eglot server to pick up the new agents."
  :type 'hook
  :group 'jal)

(defvar jal--original-lsp-java-vmargs nil
  "Stores the original value of `lsp-java-vmargs' before JAL modification.")

(provide 'jal-vars)
;;; jal-vars.el ends here
