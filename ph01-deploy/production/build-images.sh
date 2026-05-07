#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="${1:-${PH01_IMAGE_REGISTRY:-registry.example.com/ph01}}"
TAG="${2:-${PH01_IMAGE_TAG:-20260505}}"
PUSH_ARG="${3:-}"
GOPROXY="${PH01_GOPROXY:-https://goproxy.cn,direct}"
GOSUMDB="${PH01_GOSUMDB:-sum.golang.google.cn}"
NPM_REGISTRY="${PH01_NPM_REGISTRY:-https://registry.npmmirror.com}"
ALPINE_MIRROR="${PH01_ALPINE_MIRROR:-http://mirrors.aliyun.com/alpine}"
DEBIAN_MIRROR="${PH01_DEBIAN_MIRROR:-http://mirrors.aliyun.com/debian}"
DEBIAN_SECURITY_MIRROR="${PH01_DEBIAN_SECURITY_MIRROR:-http://mirrors.aliyun.com/debian-security}"

AUTH_IMAGE="$REGISTRY/auth-center:$TAG"
AI_IMAGE="$REGISTRY/ai-gateway:$TAG"
EXP_IMAGE="$REGISTRY/experience-network-manager:$TAG"

docker build \
  --build-arg GOPROXY="$GOPROXY" \
  --build-arg GOSUMDB="$GOSUMDB" \
  --build-arg ALPINE_MIRROR="$ALPINE_MIRROR" \
  -f "$ROOT_DIR/ph01-backend/Dockerfile.auth-center" \
  -t "$AUTH_IMAGE" \
  "$ROOT_DIR/ph01-backend"

docker build \
  --build-arg GOPROXY="$GOPROXY" \
  --build-arg GOSUMDB="$GOSUMDB" \
  --build-arg NPM_REGISTRY="$NPM_REGISTRY" \
  --build-arg DEBIAN_MIRROR="$DEBIAN_MIRROR" \
  --build-arg DEBIAN_SECURITY_MIRROR="$DEBIAN_SECURITY_MIRROR" \
  -f "$ROOT_DIR/ph01-ai-gateway/Dockerfile" \
  -t "$AI_IMAGE" \
  "$ROOT_DIR/ph01-ai-gateway"

docker build \
  --build-arg GOPROXY="$GOPROXY" \
  --build-arg GOSUMDB="$GOSUMDB" \
  --build-arg ALPINE_MIRROR="$ALPINE_MIRROR" \
  -f "$SCRIPT_DIR/images/experience-network-manager/Dockerfile" \
  -t "$EXP_IMAGE" \
  "$ROOT_DIR/ph01-experience-hub"

if [ "$PUSH_ARG" = "--push" ]; then
  docker push "$AUTH_IMAGE"
  docker push "$AI_IMAGE"
  docker push "$EXP_IMAGE"
fi

echo "[build] auth-center: $AUTH_IMAGE"
echo "[build] ai-gateway: $AI_IMAGE"
echo "[build] experience-network-manager: $EXP_IMAGE"
