#!/bin/bash
# 启动 PH01 认证中心（Linux / macOS）。

set -euo pipefail

cd "$(dirname "$0")/.."

REBUILD=0
CONFIG="config.hcl"
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --config=*) CONFIG="${arg#--config=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p data data/logs bin

if [[ ! -f "$CONFIG" ]]; then
  cp config.hcl.example "$CONFIG"
  echo "[init] 已从 config.hcl.example 生成 $CONFIG"
  echo "[init] 请先填写 PostgreSQL DSN、Redis URL 和 admin token，再重新运行。"
  exit 1
fi

if grep -q "CHANGE_ME" "$CONFIG"; then
  echo "[error] $CONFIG 中仍包含 CHANGE_ME，占位配置不能启动服务。"
  exit 1
fi

if [[ $REBUILD -eq 1 ]] || [[ ! -f bin/auth-gateway ]]; then
  echo "[build] 编译中..."
  go build -o bin/auth-gateway ./cmd/auth-gateway
fi

echo "[start] auth-center"
./bin/auth-gateway -config "$CONFIG" > data/logs/auth.log 2>&1 &
AUTH_PID=$!
echo "$AUTH_PID" > data/.auth.pid

echo ""
echo "================================================"
echo "服务已启动："
echo "  auth-center PID=$AUTH_PID    http://localhost:8080"
echo ""
echo "管理后台："
echo "  http://localhost:8080/admin-ui/auth.html"
echo ""
echo "配置文件：$CONFIG"
echo "停止：./scripts/stop-all.sh 或 kill $AUTH_PID"
echo "日志：tail -f data/logs/auth.log"
echo "================================================"
