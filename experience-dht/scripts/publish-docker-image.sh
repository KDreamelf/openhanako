#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/deployment-package"
VERSION="${1:-}"
REPOSITORY="${DOCKER_REPOSITORY:-dreamelf6174/experience-dht}"
PUSH="${PUSH:-1}"

if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/publish-docker-image.sh <version>" >&2
  echo "example: ./scripts/publish-docker-image.sh 20260512" >&2
  exit 2
fi

if [ ! -f "$PACKAGE_DIR/bin/experience-dht" ]; then
  echo "[docker] missing prebuilt binary: $PACKAGE_DIR/bin/experience-dht" >&2
  echo "[docker] run ./scripts/build-deployment-package.sh $VERSION first" >&2
  exit 1
fi

docker build \
  --build-arg "ALPINE_MIRROR=${EXPERIENCE_DHT_ALPINE_MIRROR:-http://mirrors.aliyun.com/alpine}" \
  -t "$REPOSITORY:$VERSION" \
  -t "$REPOSITORY:latest" \
  "$PACKAGE_DIR"

if [ "$PUSH" != "0" ]; then
  docker push "$REPOSITORY:$VERSION"
  docker push "$REPOSITORY:latest"
fi

echo "[docker] image ready: $REPOSITORY:$VERSION"
