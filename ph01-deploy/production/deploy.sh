#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
PH01_DATA_DIR="${PH01_DATA_DIR:-"$ROOT_DIR/data/production"}"
export PH01_DATA_DIR

MODE="${1:-pull}"
PH01_IMAGE_REGISTRY="${2:-${PH01_IMAGE_REGISTRY:-registry.example.com/ph01}}"
PH01_IMAGE_TAG="${3:-${PH01_IMAGE_TAG:-20260505}}"
export PH01_IMAGE_REGISTRY PH01_IMAGE_TAG

case "$MODE" in
  --init-data|init-data)
    MODE="init-data"
    ;;
  --build|build)
    MODE="build"
    ;;
  --no-pull|no-pull)
    MODE="no-pull"
    ;;
  --pull|pull|"")
    MODE="pull"
    ;;
  *)
    echo "usage: ./deploy.sh [--init-data|--pull|--build|--no-pull] [registry] [tag]" >&2
    exit 2
    ;;
esac

mkdir -p \
  "$PH01_DATA_DIR/config" \
  "$PH01_DATA_DIR/certs/mtls" \
  "$PH01_DATA_DIR/certs/experience-network" \
  "$PH01_DATA_DIR/runtime/ai-gateway" \
  "$PH01_DATA_DIR/runtime/experience-hub" \
  "$PH01_DATA_DIR/logs/ai-gateway"

seed_file() {
  src="$1"
  dst="$2"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    echo "[data] seeded $dst"
  fi
}

seed_file "$SCRIPT_DIR/config/auth-center.hcl" "$PH01_DATA_DIR/config/auth-center.hcl"
seed_file "$SCRIPT_DIR/config/ai-gateway.yaml" "$PH01_DATA_DIR/config/ai-gateway.yaml"
seed_file "$SCRIPT_DIR/config/experience-hub.json" "$PH01_DATA_DIR/config/experience-hub.json"
for item in "$SCRIPT_DIR"/certs/experience-network/*; do
  [ -f "$item" ] || continue
  seed_file "$item" "$PH01_DATA_DIR/certs/experience-network/$(basename "$item")"
done
for item in "$SCRIPT_DIR"/certs/mtls/*; do
  [ -f "$item" ] || continue
  seed_file "$item" "$PH01_DATA_DIR/certs/mtls/$(basename "$item")"
done

./scripts/generate-mtls-certs.sh "$PH01_DATA_DIR/certs/mtls"

if [ "$MODE" = "init-data" ]; then
  echo "[data] initialized persistent deployment data at: $PH01_DATA_DIR"
  echo "[data] edit config files under: $PH01_DATA_DIR/config"
  exit 0
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "[deploy] docker compose is required" >&2
  exit 1
fi

if [ "$MODE" = "build" ]; then
  ./build-images.sh "$PH01_IMAGE_REGISTRY" "$PH01_IMAGE_TAG"
elif [ "$MODE" = "pull" ]; then
  $COMPOSE -p ph01-production -f docker-compose.yml pull
fi

$COMPOSE -p ph01-production -f docker-compose.yml up -d --remove-orphans
$COMPOSE -p ph01-production -f docker-compose.yml ps
