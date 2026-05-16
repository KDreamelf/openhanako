#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/deployment-package"
BIN_DIR="$PACKAGE_DIR/bin"
RELEASE_DIR="$ROOT_DIR/release"
VERSION="${1:-dev}"
GOOS_TARGET="${GOOS_TARGET:-linux}"
GOARCH_TARGET="${GOARCH_TARGET:-amd64}"
ARCHIVE="$RELEASE_DIR/experience-dht-deployment-package-$VERSION-$GOOS_TARGET-$GOARCH_TARGET.tar.gz"

mkdir -p "$BIN_DIR" "$RELEASE_DIR"

cd "$ROOT_DIR"
go test ./...
CGO_ENABLED=0 GOOS="$GOOS_TARGET" GOARCH="$GOARCH_TARGET" go build -ldflags "-s -w" -o "$BIN_DIR/experience-dht" ./cmd/experience-dht

tar \
  --exclude './data' \
  --exclude './*.zip' \
  --exclude './*.tar.gz' \
  -czf "$ARCHIVE" \
  -C "$PACKAGE_DIR" \
  .
echo "[package] wrote $ARCHIVE"
