#!/bin/bash
# 停止 PH01 认证中心；顺手清理旧 Go 原型 ai-gateway 的遗留 PID。

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f data/.auth.pid ]]; then
  PID=$(cat data/.auth.pid)
  kill "$PID" 2>/dev/null && echo "[stop] auth-center PID=$PID" || true
  rm -f data/.auth.pid
fi

if [[ -f data/.ai.pid ]]; then
  PID=$(cat data/.ai.pid)
  kill "$PID" 2>/dev/null && echo "[stop] legacy ai-gateway PID=$PID" || true
  rm -f data/.ai.pid
fi
