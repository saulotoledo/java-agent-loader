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

(defcustom jal-additional-agents nil
  "Additional agents merged with `jal-known-agents'.
Each element is either:
- (ARTIFACT-ID . PROPS) : Override a known agent or add a new one.
- (ARTIFACT-ID)         : Add an agent with all defaults.

PROPS is a plist with keys :params and :jar-path.
An entry whose ARTIFACT-ID matches a known agent overrides its defaults.

Set this before lsp-java or eglot-java loads, e.g. in a
`use-package jal :config' block."
  :type '(alist :key-type string
                :value-type (plist :key-type symbol
                                   :value-type (choice string (const :tag "None" nil))))
  :group 'jal)

(defcustom jal-auto-setup nil
  "When non-nil, automatically run agent detection without prompting.
By default JAL asks whether to set up agents for a new project.
Set this to t to skip the confirmation and always run detection."
  :type 'boolean
  :group 'jal)

(defcustom jal-agents-detected-hook nil
  "Hook run after agents are successfully detected and cached.
This is useful for restarting the LSP/Eglot server to pick up the new agents."
  :type 'hook
  :group 'jal)

(defvar jal-current-java-key-function nil
  "Function called with no arguments that returns the active java binary path.
Each client module (e.g. `jal-client-lsp', `jal-client-eglot') sets this
during setup so the core cache functions remain client-agnostic.
When nil, `jal--current-java-key' falls back to resolving the first
`java' found on PATH.")

(provide 'jal-vars)
;;; jal-vars.el ends here
