#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"

clean_path() {
  rel="$1"
  target="$ROOT_DIR/$rel"
  case "$target" in
    "$ROOT_DIR"/*) ;;
    *) echo "refuse to delete outside workspace: $target" >&2; exit 1 ;;
  esac
  if [ -e "$target" ]; then
    echo "[clean] $rel"
    rm -rf "$target"
  fi
}

clean_path "ph01-ai-gateway/.cache"
clean_path "ph01-ai-gateway/.npm-cache"
clean_path "ph01-ai-gateway/bin"
clean_path "ph01-ai-gateway/web/default/node_modules"
clean_path "ph01-ai-gateway/web/classic/node_modules"
clean_path "ph01-ai-gateway/web/default/dist"
clean_path "ph01-ai-gateway/web/classic/dist"
clean_path "ph01-backend/bin"
clean_path "ph01-backend/data"
clean_path "ph01-backend/auth-gateway.exe"
clean_path "ph01-experience-hub/bin"
clean_path "ph01-experience-hub/data"

echo "[clean] done"
