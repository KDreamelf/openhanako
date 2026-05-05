#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)"
OUT_DIR="${1:-"$ROOT_DIR/data/production/certs/mtls"}"

if [ -f "$OUT_DIR/root-ca.pem" ] \
  && [ -f "$OUT_DIR/auth-center.pem" ] \
  && [ -f "$OUT_DIR/auth-center-key.pem" ] \
  && [ -f "$OUT_DIR/ai-gateway.pem" ] \
  && [ -f "$OUT_DIR/ai-gateway-key.pem" ]; then
  echo "[mtls] certs already exist: $OUT_DIR"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "[mtls] openssl is required to generate deployment certificates" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

openssl genrsa -out "$OUT_DIR/root-ca-key.pem" 4096
openssl req -x509 -new -nodes \
  -key "$OUT_DIR/root-ca-key.pem" \
  -sha256 \
  -days 3650 \
  -out "$OUT_DIR/root-ca.pem" \
  -subj "/CN=PH01 Deployment mTLS Root CA/O=PH01"

generate_leaf() {
  name="$1"
  cn="$2"
  san="$3"

  openssl genrsa -out "$OUT_DIR/$name-key.pem" 3072
  openssl req -new \
    -key "$OUT_DIR/$name-key.pem" \
    -out "$tmp_dir/$name.csr" \
    -subj "/CN=$cn/O=PH01"

  cat > "$tmp_dir/$name.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=$san
EOF

  openssl x509 -req \
    -in "$tmp_dir/$name.csr" \
    -CA "$OUT_DIR/root-ca.pem" \
    -CAkey "$OUT_DIR/root-ca-key.pem" \
    -CAcreateserial \
    -out "$OUT_DIR/$name.pem" \
    -days 1095 \
    -sha256 \
    -extfile "$tmp_dir/$name.ext"
}

generate_leaf "auth-center" "ph01-auth-center" "DNS:ph01-auth-center,DNS:auth-center,DNS:localhost,IP:127.0.0.1"
generate_leaf "ai-gateway" "ph01-ai-gateway" "DNS:ph01-ai-gateway,DNS:ai-gateway,DNS:localhost,IP:127.0.0.1"

chmod 644 "$OUT_DIR"/*.pem
chmod 600 "$OUT_DIR"/*-key.pem

echo "[mtls] generated deployment certs: $OUT_DIR"
