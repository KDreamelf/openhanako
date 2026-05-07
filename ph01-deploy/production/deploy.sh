#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
PH01_DATA_DIR="${PH01_DATA_DIR:-"$ROOT_DIR/data/production"}"
export PH01_DATA_DIR

MODE="${1:-auto}"
PH01_IMAGE_REGISTRY="${2:-${PH01_IMAGE_REGISTRY:-registry.example.com/ph01}}"
PH01_IMAGE_TAG="${3:-${PH01_IMAGE_TAG:-20260505}}"
export PH01_IMAGE_REGISTRY PH01_IMAGE_TAG

case "$MODE" in
  --auto|auto|"")
    MODE="auto"
    ;;
  --init-data|init-data)
    MODE="init-data"
    ;;
  --build|build)
    MODE="build"
    ;;
  --no-pull|no-pull)
    MODE="no-pull"
    ;;
  --pull|pull)
    MODE="pull"
    ;;
  *)
    echo "usage: ./deploy.sh [--auto|--init-data|--pull|--build|--no-pull] [registry] [tag]" >&2
    exit 2
    ;;
esac

create_data_dirs() {
  mkdir -p \
    "$PH01_DATA_DIR/config" \
    "$PH01_DATA_DIR/certs/mtls" \
    "$PH01_DATA_DIR/certs/experience-network" \
    "$PH01_DATA_DIR/runtime/ai-gateway" \
    "$PH01_DATA_DIR/runtime/experience-hub" \
    "$PH01_DATA_DIR/logs/ai-gateway"
}

seed_file() {
  src="$1"
  dst="$2"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    echo "[data] seeded $dst"
  fi
}

seed_initial_data() {
  create_data_dirs

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
}

data_has_entries() {
  [ -d "$PH01_DATA_DIR" ] || return 1
  set -- "$PH01_DATA_DIR"/*
  [ -e "$1" ]
}

required_data_exists() {
  [ -f "$PH01_DATA_DIR/config/auth-center.hcl" ] \
    && [ -f "$PH01_DATA_DIR/config/ai-gateway.yaml" ] \
    && [ -f "$PH01_DATA_DIR/config/experience-hub.json" ] \
    && [ -f "$PH01_DATA_DIR/certs/experience-network/manifest.json" ] \
    && [ -f "$PH01_DATA_DIR/certs/experience-network/master-certificate.json" ] \
    && [ -f "$PH01_DATA_DIR/certs/experience-network/root-certificate.json" ] \
    && [ -f "$PH01_DATA_DIR/certs/mtls/root-ca.pem" ] \
    && [ -f "$PH01_DATA_DIR/certs/mtls/auth-center.pem" ] \
    && [ -f "$PH01_DATA_DIR/certs/mtls/auth-center-key.pem" ] \
    && [ -f "$PH01_DATA_DIR/certs/mtls/ai-gateway.pem" ] \
    && [ -f "$PH01_DATA_DIR/certs/mtls/ai-gateway-key.pem" ]
}

print_missing_required_data() {
  for rel in \
    config/auth-center.hcl \
    config/ai-gateway.yaml \
    config/experience-hub.json \
    certs/experience-network/manifest.json \
    certs/experience-network/master-certificate.json \
    certs/experience-network/root-certificate.json \
    certs/mtls/root-ca.pem \
    certs/mtls/auth-center.pem \
    certs/mtls/auth-center-key.pem \
    certs/mtls/ai-gateway.pem \
    certs/mtls/ai-gateway-key.pem
  do
    [ -f "$PH01_DATA_DIR/$rel" ] || echo "  - $PH01_DATA_DIR/$rel"
  done
}

cleanup_old_runtime() {
  echo "[cleanup] removing old PH01 containers; persistent data is not touched"
  for name in \
    ph01-auth-center \
    ph01-ai-gateway \
    ph01-experience-network-manager
  do
    if docker container inspect "$name" >/dev/null 2>&1; then
      docker rm -f "$name"
    fi
  done

  echo "[cleanup] removing old PH01 images for registry: $PH01_IMAGE_REGISTRY"
  for repo in \
    "$PH01_IMAGE_REGISTRY/auth-center" \
    "$PH01_IMAGE_REGISTRY/ai-gateway" \
    "$PH01_IMAGE_REGISTRY/experience-network-manager"
  do
    ids="$(docker image ls --quiet "$repo" 2>/dev/null | sort -u)"
    if [ -n "$ids" ]; then
      docker rmi -f $ids
    fi
  done
}

print_compose_diagnostics() {
  echo "[deploy] compose failed; showing PH01 container status and recent logs" >&2
  $COMPOSE -p ph01-production -f docker-compose.yml ps >&2 || true

  for name in \
    ph01-auth-center \
    ph01-ai-gateway \
    ph01-experience-network-manager
  do
    if docker container inspect "$name" >/dev/null 2>&1; then
      echo "[deploy] inspect $name" >&2
      docker inspect \
        --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} exit_code={{.State.ExitCode}} error={{.State.Error}}' \
        "$name" >&2 || true
      docker inspect \
        --format '{{if .State.Health}}{{range .State.Health.Log}}health_start={{.Start}} health_exit={{.ExitCode}} health_output={{printf "%q" .Output}}{{println}}{{end}}{{end}}' \
        "$name" >&2 || true
      echo "[deploy] logs $name" >&2
      docker logs --tail 120 "$name" >&2 || true
    fi
  done
}

fail_if_config_contains() {
  file="$1"
  pattern="$2"
  message="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "[config] $message" >&2
    echo "[config] edit this file before deployment: $file" >&2
    exit 1
  fi
}

validate_runtime_config() {
  fail_if_config_contains \
    "$PH01_DATA_DIR/config/auth-center.hcl" \
    'CHANGE_ME_AUTH_DB_PASSWORD|postgres\.example\.internal' \
    "auth-center PostgreSQL DSN is still using the template value"

  fail_if_config_contains \
    "$PH01_DATA_DIR/config/ai-gateway.yaml" \
    'CHANGE_ME_AI_DB_PASSWORD|postgres\.example\.internal' \
    "ai-gateway PostgreSQL DSN is still using the template value"
}

if [ "$MODE" = "init-data" ]; then
  seed_initial_data
  echo "[data] initialized persistent deployment data at: $PH01_DATA_DIR"
  echo "[data] edit config files under: $PH01_DATA_DIR/config"
  exit 0
fi

if ! data_has_entries; then
  seed_initial_data
  echo "[data] initialized persistent deployment data at: $PH01_DATA_DIR"
  echo "[data] first-run deployment data was created; edit config files under: $PH01_DATA_DIR/config"
  echo "[data] deployment stopped before docker compose. Re-run this command after editing the config files."
  exit 0
fi

if ! required_data_exists; then
  echo "[data] existing data directory found, refusing to modify it: $PH01_DATA_DIR" >&2
  echo "[data] missing required deployment data:" >&2
  print_missing_required_data >&2
  echo "[data] run ./deploy.sh --init-data only if you want to seed missing files without overwriting existing files." >&2
  exit 1
fi

validate_runtime_config

if [ "$MODE" = "auto" ]; then
  MODE="build"
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
  cleanup_old_runtime
  ./build-images.sh "$PH01_IMAGE_REGISTRY" "$PH01_IMAGE_TAG"
elif [ "$MODE" = "pull" ]; then
  $COMPOSE -p ph01-production -f docker-compose.yml pull
fi

if ! $COMPOSE -p ph01-production -f docker-compose.yml up -d --remove-orphans; then
  print_compose_diagnostics
  exit 1
fi
$COMPOSE -p ph01-production -f docker-compose.yml ps
