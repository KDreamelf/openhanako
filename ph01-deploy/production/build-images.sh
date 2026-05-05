#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="${1:-${PH01_IMAGE_REGISTRY:-registry.example.com/ph01}}"
TAG="${2:-${PH01_IMAGE_TAG:-20260505}}"
PUSH_ARG="${3:-}"

AUTH_IMAGE="$REGISTRY/auth-center:$TAG"
AI_IMAGE="$REGISTRY/ai-gateway:$TAG"
EXP_IMAGE="$REGISTRY/experience-network-manager:$TAG"

docker build -f "$ROOT_DIR/ph01-backend/Dockerfile.auth-center" -t "$AUTH_IMAGE" "$ROOT_DIR/ph01-backend"
docker build -f "$ROOT_DIR/ph01-ai-gateway/Dockerfile" -t "$AI_IMAGE" "$ROOT_DIR/ph01-ai-gateway"
docker build -f "$SCRIPT_DIR/images/experience-network-manager/Dockerfile" -t "$EXP_IMAGE" "$ROOT_DIR/ph01-experience-hub"

if [ "$PUSH_ARG" = "--push" ]; then
  docker push "$AUTH_IMAGE"
  docker push "$AI_IMAGE"
  docker push "$EXP_IMAGE"
fi

echo "[build] auth-center: $AUTH_IMAGE"
echo "[build] ai-gateway: $AI_IMAGE"
echo "[build] experience-network-manager: $EXP_IMAGE"
