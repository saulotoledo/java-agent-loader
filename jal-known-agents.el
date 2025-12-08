;;; jal-known-agents.el --- Known agents registry for JAL -*- lexical-binding: t; -*-

;; Author: Saulo Toledo <saulotoledo@gmail.com>
;; Version: 0.1.0
;; Package-Prefixes: (jal)
;; Keywords: java, languages, tools
;; URL: https://github.com/saulotoledo/java-agent-loader

;;; Commentary:
;; This module provides a registry of commonly used Java agents with sensible defaults.

;;; Code:

(defvar jal-known-agents
  '(("lombok" :jar-path "org/projectlombok/%a/%v/%a-%v.jar" :params "")
    ("opentelemetry-javaagent" :jar-path "io/opentelemetry/javaagent/%a/%v/%a-%v.jar")
    ("org.jacoco.agent" :jar-path "org/jacoco/%a/%v/%a-%v-runtime.jar"))
  "Registry of known Java agents with default configurations.
Each entry is either:
- (ARTIFACT-ID) : Use defaults
- (ARTIFACT-ID . PROPS) : Specify properties

PROPS is a plist with keys :params and :jar-path.")

(provide 'jal-known-agents)
;;; jal-known-agents.el ends here
