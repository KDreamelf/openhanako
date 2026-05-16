#!/usr/bin/env sh
set -eu

PACKAGE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MODE="${1:-up}"

EXPERIENCE_DHT_DATA_DIR="${EXPERIENCE_DHT_DATA_DIR:-"$PACKAGE_DIR/data"}"
EXPERIENCE_DHT_PROJECT="${EXPERIENCE_DHT_PROJECT:-experience-dht}"
EXPERIENCE_DHT_IMAGE="${EXPERIENCE_DHT_IMAGE:-dreamelf6174/experience-dht:latest}"
EXPERIENCE_DHT_INIT_PASSWORD="${EXPERIENCE_DHT_INIT_PASSWORD:-}"
export EXPERIENCE_DHT_DATA_DIR EXPERIENCE_DHT_IMAGE EXPERIENCE_DHT_INIT_PASSWORD

usage() {
  echo "usage: ./deploy.sh [init|up|pull|build|down|logs|ps|reset]" >&2
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "[deploy] docker compose is required" >&2
    exit 1
  fi
}

init_layout() {
  mkdir -p "$EXPERIENCE_DHT_DATA_DIR"
  echo "[config] set EXPERIENCE_DHT_INIT_PASSWORD before deployment"
}

validate_env() {
  if [ -z "${EXPERIENCE_DHT_INIT_PASSWORD:-}" ] || [ "$EXPERIENCE_DHT_INIT_PASSWORD" = "CHANGE_ME_DHT_INIT_PASSWORD" ]; then
    echo "[config] set EXPERIENCE_DHT_INIT_PASSWORD to the one-time bind password before deployment" >&2
    exit 1
  fi
}

require_binary() {
  if [ ! -f "$PACKAGE_DIR/bin/experience-dht" ]; then
    echo "[deploy] missing prebuilt binary: $PACKAGE_DIR/bin/experience-dht" >&2
    echo "[deploy] build the deployment package on the development machine first" >&2
    exit 1
  fi
}

case "$MODE" in
  init)
    init_layout
    ;;
  up)
    init_layout
    validate_env
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" up -d
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" ps
    ;;
  pull)
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" pull
    ;;
  build)
    init_layout
    require_binary
    docker build \
      --build-arg "ALPINE_MIRROR=${EXPERIENCE_DHT_ALPINE_MIRROR:-http://mirrors.aliyun.com/alpine}" \
      -t "$EXPERIENCE_DHT_IMAGE" \
      "$PACKAGE_DIR"
    ;;
  down)
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" down
    ;;
  logs)
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" logs -f --tail 120
    ;;
  ps)
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" ps
    ;;
  reset)
    compose -p "$EXPERIENCE_DHT_PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" down
    rm -rf "$EXPERIENCE_DHT_DATA_DIR"
    init_layout
    echo "[reset] removed DHT state. Run ./deploy.sh up, then bind again from the client."
    ;;
  *)
    usage
    exit 2
    ;;
esac
