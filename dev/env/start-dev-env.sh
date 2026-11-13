#!/usr/bin/env bash
# start-dev-env.sh — Launch an isolated JAL debug environment
#
# Usage:
#   ./dev/env/start-dev-env.sh eglot <project-dir>
#   ./dev/env/start-dev-env.sh eglot-java <project-dir>
#   ./dev/env/start-dev-env.sh lsp-java <project-dir>
#   ./dev/env/start-dev-env.sh lsp-mode <project-dir> # plain lsp-mode
#
# Isolation model:
#   /tmp/jal-{client}-<PID>/     session-volatile Emacs state
#                                deleted on exit (kill-emacs-hook + trap)
#   dev/env/.pkg-{client}/      ELPA packages   (persistent)
#   dev/env/.jdtls-{client}/     JDTLS server    (persistent)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: $0 {eglot|eglot-java|lsp-java|lsp-mode} <project-dir>"
  exit 1
}

[[ $# -lt 2 ]] && usage

CLIENT="${1}"
PROJECT_DIR="${2}"

case "$CLIENT" in
  eglot)
    INIT_FILE="$SCRIPT_DIR/init-eglot.el"
    TMP_PREFIX="jal-eglot"
    LABEL="Eglot without eglot-java"
    ;;
  eglot-java)
    INIT_FILE="$SCRIPT_DIR/init-eglot-java.el"
    TMP_PREFIX="jal-eglot-java"
    LABEL="eglot-java"
    ;;
  lsp-java)
    INIT_FILE="$SCRIPT_DIR/init-lsp-java.el"
    TMP_PREFIX="jal-lsp-java"
    LABEL="lsp-java"
    ;;
  lsp-mode)
    INIT_FILE="$SCRIPT_DIR/init-lsp-mode.el"
    TMP_PREFIX="jal-lsp-mode"
    LABEL="lsp-mode without lsp-java"
    ;;
  *)
    echo "Unknown client: $CLIENT"
    usage
    ;;
esac

# Resolve project dir to an absolute path
PROJECT_DIR="$(realpath "$PROJECT_DIR")"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: project dir not found: $PROJECT_DIR"
  exit 1
fi

# Force hash-table deserialization for lsp-mode. A parent shell may export
# LSP_USE_PLISTS=1; MELPA packages in the sandbox caches are compiled without
# it, and a compile/runtime mismatch yields hash-table-p errors on every
# JSON-RPC message. If a cache was installed with LSP_USE_PLISTS set, remove
# the matching .pkg-lsp-java/ or .pkg-lsp-mode/ directory once to recompile.
unset LSP_USE_PLISTS

# -- Create /tmp sandbox -------------------------------------------------------
# The init file also cleans up via kill-emacs-hook; this trap handles crashes
# or SIGINT/SIGTERM from outside Emacs.
TMP_DIR="$(mktemp -d "/tmp/${TMP_PREFIX}-XXXXXX")"
export JAL_DEV_TMPDIR="$TMP_DIR"

cleanup() {
  if [[ -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
    echo "Cleaned up $TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

echo "----------------------------------------------"
echo " JAL dev environment : $LABEL"
echo " Init file           : $INIT_FILE"
echo " /tmp sandbox        : $TMP_DIR  (deleted on exit)"
echo " Packages (persist)  : $SCRIPT_DIR/.pkg-${CLIENT}"
echo " LSP_USE_PLISTS      : unset (hash-table mode)"
case "$CLIENT" in
  eglot|eglot-java|lsp-mode) echo " JDTLS   (persist)   : $SCRIPT_DIR/.jdtls-${CLIENT}" ;;
esac
echo " Project             : $PROJECT_DIR"
echo "----------------------------------------------"

emacs -Q \
  --eval "(setenv \"JAL_DEV_PROJECT\" \"$PROJECT_DIR\")" \
  -l "$INIT_FILE"

# trap EXIT fires here -> cleanup() removes $TMP_DIR
