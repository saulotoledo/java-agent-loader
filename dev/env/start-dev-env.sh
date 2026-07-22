#!/usr/bin/env bash
# start-dev-env.sh — Launch an isolated JAL debug environment
#
# Usage:
#   ./dev/env/start-dev-env.sh eglot <project-dir>
#   ./dev/env/start-dev-env.sh lsp   <project-dir>
#
# Isolation model:
#   /tmp/jal-{eglot,lsp}-<PID>/  session-volatile Emacs state
#                                deleted on exit (kill-emacs-hook + trap)
#   dev/env/.pkg-{eglot,lsp}/    ELPA packages   (persistent)
#   dev/env/.jdtls-eglot/        JDTLS server    (persistent, eglot only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: $0 {eglot|lsp} <project-dir>"
  exit 1
}

[[ $# -lt 2 ]] && usage

CLIENT="${1}"
PROJECT_DIR="${2}"

case "$CLIENT" in
  eglot)
    INIT_FILE="$SCRIPT_DIR/init-eglot.el"
    TMP_PREFIX="jal-eglot"
    LABEL="eglot-java"
    ;;
  lsp)
    INIT_FILE="$SCRIPT_DIR/init-lsp.el"
    TMP_PREFIX="jal-lsp"
    LABEL="lsp-java"
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
[[ "$CLIENT" == "eglot" ]] && \
echo " JDTLS   (persist)   : $SCRIPT_DIR/.jdtls-eglot"
echo " Project             : $PROJECT_DIR"
echo "----------------------------------------------"

emacs -Q \
  --eval "(setenv \"JAL_DEV_PROJECT\" \"$PROJECT_DIR\")" \
  -l "$INIT_FILE"

# trap EXIT fires here -> cleanup() removes $TMP_DIR
