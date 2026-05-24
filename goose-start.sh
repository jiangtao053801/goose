#!/bin/bash
# ============================================================
# Goose 桌面版 - 一键完全重启脚本
# ============================================================
# 安全原则：
# 1. 绝不 kill 当前的 goose 进程（避免自杀）
# 2. 使用端口号识别进程而非进程名
# 3. 所有日志统一写到 /tmp/desktop-goosed.log
# ============================================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

PROJECT_DIR="/data/goose/goose"
DESKTOP_DIR="$PROJECT_DIR/ui/desktop"
BIN_DIR="$DESKTOP_DIR/src/bin"
BUILD_DIR="$DESKTOP_DIR/.vite/build"
ELECTRON_BIN="$PROJECT_DIR/ui/node_modules/electron/dist/electron"
VITE_BIN="$PROJECT_DIR/ui/node_modules/vite/bin/vite.js"

# 统一日志文件
LOG_FILE="/tmp/desktop-goosed.log"

# ============================================================
# 辅助函数：通过端口号查找 PID
# ============================================================
pid_on_port() {
  ss -tlnp 2>/dev/null | grep ":$1 " | grep -oP 'pid=\K[0-9]+' | head -1 || echo ""
}

kill_process_on_port() {
  local port=$1
  local pid
  pid=$(pid_on_port "$port")
  if [ -n "$pid" ]; then
    log_info "端口 $port 被 PID $pid 占用，正在停止..."
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 10); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      sleep 1
    fi
    log_ok "端口 $port 已释放"
  fi
}

is_port_free() {
  ! ss -tlnp 2>/dev/null | grep -q ":$1 "
}

# ============================================================
# 启动 goosed 后端
# ============================================================
start_goosed() {
  log_info "启动 goosed 后端 (端口 3013)..."

  if ! is_port_free 3013; then
    log_warn "端口 3013 已被占用，强制释放..."
    kill_process_on_port 3013
  fi

  cd "$PROJECT_DIR"
  GOOSE_SERVER__SECRET_KEY=weiduyanjin-2026 \
    GOOSE_PORT=3013 \
    GOOSE_HOST=0.0.0.0 \
    nohup "$BIN_DIR/goosed" agent >> "$LOG_FILE" 2>&1 &
  local pid=$!

  for i in $(seq 1 15); do
    if pid_on_port 3013 | grep -q "$pid"; then
      log_ok "goosed 已启动 (PID: $pid)"
      return 0
    fi
    sleep 0.5
  done

  log_error "goosed 启动失败（超时15秒）"
  tail -20 "$LOG_FILE"
  return 1
}

# ============================================================
# 启动 Vite 前端开发服务器
# ============================================================
start_vite() {
  log_info "启动 Vite 前端服务器 (端口 5173)..."

  if ! is_port_free 5173; then
    log_warn "端口 5173 已被占用，强制释放..."
    kill_process_on_port 5173
  fi

  cd "$DESKTOP_DIR"
  nohup /usr/bin/node "$VITE_BIN" \
    --config vite.renderer.config.mts \
    --port 5173 --host 127.0.0.1 \
    >> "$LOG_FILE" 2>&1 &
  local pid=$!

  for i in $(seq 1 15); do
    if pid_on_port 5173 | grep -q "$pid"; then
      log_ok "Vite 已启动 (PID: $pid)"
      return 0
    fi
    sleep 0.5
  done

  log_error "Vite 启动失败（超时15秒）"
  tail -20 "$LOG_FILE"
  return 1
}

# ============================================================
# 启动 Electron 桌面
# ============================================================
start_electron() {
  log_info "启动 Electron 桌面..."

  if [ ! -f "$BUILD_DIR/main.js" ]; then
    log_error "main.js 不存在，请先运行打包脚本"
    return 1
  fi
  if [ ! -f "$BUILD_DIR/preload.js" ]; then
    log_error "preload.js 不存在，请先运行打包脚本"
    return 1
  fi

  # Electron 是单实例架构，必须先杀掉旧实例，新 preload/main 才会加载
  local old_pid
  old_pid=$(pgrep -f "electron.*main.js" | head -1)
  if [ -n "$old_pid" ]; then
    log_info "→ 停止旧 Electron 实例 (PID: $old_pid)..."
    kill "$old_pid" 2>/dev/null || true
    for i in $(seq 1 10); do
      if ! kill -0 "$old_pid" 2>/dev/null; then break; fi
      sleep 0.5
    done
    kill -9 "$old_pid" 2>/dev/null || true
    sleep 1
    log_ok "→ 旧 Electron 已停止"
  fi

  cd "$DESKTOP_DIR"
  GOOSE_PORT=3013 \
    GOOSE_SERVER__SECRET_KEY=weiduyanjin-2026 \
    GOOSE_EXTERNAL_BACKEND="https://127.0.0.1:3013" \
    MAIN_WINDOW_VITE_DEV_SERVER_URL="http://localhost:5173" \
    nohup "$ELECTRON_BIN" \
    .vite/build/main.js \
    --no-sandbox >> "$LOG_FILE" 2>&1 &
  local pid=$!

  # Electron 是多进程架构，用轮询等待主进程就绪
  for i in $(seq 1 15); do
    if pgrep -P "$pid" 2>/dev/null | grep -q . || kill -0 "$pid" 2>/dev/null; then
      log_ok "Electron 已启动 (PID: $pid)"
      return 0
    fi
    sleep 1
  done

  # 如果主进程不在了，再检查是否有任何 electron 进程
  if pgrep -f "electron.*main.js" > /dev/null 2>&1; then
    log_ok "Electron 已在运行 (PID: $(pgrep -f 'electron.*main.js' | head -1))"
    return 0
  fi

  log_error "Electron 启动失败"
  tail -20 "$LOG_FILE"
  return 1
}

# ============================================================
# 检查页面是否正常
# ============================================================
check_page() {
  log_info "检查页面是否正常..."
  for i in $(seq 1 10); do
    if curl -sf -o /dev/null "http://localhost:5173" 2>/dev/null; then
      log_ok "页面正常服务 ✅"
      return 0
    fi
    sleep 1
  done
  log_warn "页面超时（Electron 可能已加载）"
  return 0
}

# ============================================================
# 主流程
# ============================================================
main() {
  echo ""
  echo "========================================="
  echo "  Goose 桌面版 - 一键完全重启"
  echo "========================================="
  echo ""

  if [ ! -f "$BIN_DIR/goosed" ]; then
    log_error "goosed 二进制不存在，请先运行: bash /home/node118/goose-build.sh"
    exit 1
  fi

  # 日志文件头
  echo "===== $(date) Goosed Desktop Restart =====" >> "$LOG_FILE"

  start_goosed || exit 1
  echo ""
  start_vite || exit 1
  echo ""
  start_electron || exit 1
  echo ""
  check_page || true

  echo ""
  echo "========================================="
  echo "  🎉 Goose 桌面版已完全重启！"
  echo "========================================="
  echo "  goosed   : https://127.0.0.1:3013"
  echo "  Vite     : http://127.0.0.1:5173"
  echo "  Electron : PID $(pgrep -f 'electron.*main.js' | head -1 || echo '?')"
  echo ""
  echo "  统一日志: tail -f $LOG_FILE"
  echo "========================================="
}

main "$@"
