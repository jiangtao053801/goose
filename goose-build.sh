#!/bin/bash
# ============================================================
# Goose 桌面版 - 一键打包脚本
# 功能：编译 Rust + 生成 OpenAPI + 构建前端 + 复制产物
# 用法：bash bootstrap.sh              # debug 模式
#       RELEASE=1 bash bootstrap.sh    # release 模式
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

# ---------- 配置 ----------
PROJECT_DIR="/data/goose/goose"
DESKTOP_DIR="$PROJECT_DIR/ui/desktop"
BIN_DIR="$DESKTOP_DIR/src/bin"
BUILD_DIR="$DESKTOP_DIR/.vite/build"
RELEASE_MODE="${RELEASE:-debug}"
VITE_BIN="$PROJECT_DIR/ui/node_modules/vite/bin/vite.js"

# ---------- 计时 ----------
start_time=$(date +%s)

echo ""
echo "=============================================="
echo "     Goose 桌面版 - 一键打包"
echo "=============================================="
echo ""

# ============================================================
# 1. 检查环境
# ============================================================
# 切换到项目目录（所有编译操作以此为基准）
cd "$PROJECT_DIR"
log_info "检查环境..."

if ! command -v cargo &>/dev/null; then
  log_error "cargo 未安装"
  exit 1
fi

if ! command -v node &>/dev/null; then
  log_error "node 未安装"
  exit 1
fi
log_ok "Node.js $(node --version)"

if [ ! -d "$DESKTOP_DIR" ]; then
  log_error "项目目录不正确：$DESKTOP_DIR"
  exit 1
fi

# ---------- 载入 Cargo 环境 ----------
if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi

# ============================================================
# 2. 检测 Rust 代码变更
# ============================================================
if [ "$RELEASE_MODE" = "release" ]; then
  TARGET_DIR="$PROJECT_DIR/target/release"
else
  TARGET_DIR="$PROJECT_DIR/target/debug"
fi

log_info "检测 Rust 代码变更..."
RUST_CHANGED=false
if git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null | grep -qE "\.(rs|toml|lock)$"; then
  RUST_CHANGED=true
  log_info "→ Rust 代码有变更，需要编译"
elif [ ! -f "$TARGET_DIR/goosed" ]; then
  RUST_CHANGED=true
  log_info "→ 二进制不存在，进行首次编译"
else
  log_ok "→ Rust 代码无变更，跳过编译"
fi

# ============================================================
# 3. 编译 Rust 二进制（统一变量名：GOOSE_BIN / GOOSED_BIN）
# ============================================================
GOOSE_BIN="$TARGET_DIR/goose"
GOOSED_BIN="$TARGET_DIR/goosed"

if [ "$RUST_CHANGED" = true ]; then
  BUILD_LOG=$(mktemp /tmp/goose-rust-build.XXXXXX.log)
  trap 'rm -f "$BUILD_LOG"' EXIT

  log_info "编译 Rust ($RELEASE_MODE 模式)..."
  BUILD_FLAGS=""
  [ "$RELEASE_MODE" = "release" ] && BUILD_FLAGS="--release"

  if ! cargo build $BUILD_FLAGS -p goose-cli -p goose-server > "$BUILD_LOG" 2>&1; then
    log_error "Rust 编译失败！错误日志："
    cat "$BUILD_LOG"
    rm -f "$BUILD_LOG"
    exit 1
  fi

  tail -n 3 "$BUILD_LOG" || true
  log_ok "Rust 编译成功"
  rm -f "$BUILD_LOG"
  trap - EXIT
fi

# ============================================================
# 4. 生成 OpenAPI schema
# ============================================================
log_info "生成 OpenAPI schema..."
SCHEMA_LOG=$(mktemp /tmp/goose-schema.XXXXXX.log)
trap 'rm -f "$SCHEMA_LOG"' EXIT

BUILD_FLAGS=""
[ "$RELEASE_MODE" = "release" ] && BUILD_FLAGS="--release"

if ! cargo run $BUILD_FLAGS -p goose-server --bin generate_schema > "$SCHEMA_LOG" 2>&1; then
  log_error "生成 OpenAPI schema 失败！"
  cat "$SCHEMA_LOG"
  rm -f "$SCHEMA_LOG"
  exit 1
fi
rm -f "$SCHEMA_LOG"
trap - EXIT
log_ok "OpenAPI schema 已生成"

# ============================================================
# 5. 复制二进制到桌面应用
# ============================================================
log_info "复制二进制到桌面应用..."
mkdir -p "$BIN_DIR"

# goosed 正在运行时会锁定文件，复制前先按端口释放
GPID=$(ss -tlnp 2>/dev/null | grep ":3013 " | grep -oP 'pid=\K[0-9]+' | head -1)
if [ -n "$GPID" ]; then
  log_info "→ goosed 正在运行 (PID: $GPID)，先停止以释放二进制文件..."
  kill "$GPID" 2>/dev/null || true
  for i in $(seq 1 10); do
    if ! kill -0 "$GPID" 2>/dev/null; then break; fi
    sleep 0.5
  done
  kill -9 "$GPID" 2>/dev/null || true
  sleep 1
  log_ok "→ 已停止，端口 3013 已释放"
fi

cp "$GOOSED_BIN" "$BIN_DIR/goosed"
cp "$GOOSE_BIN"  "$BIN_DIR/goose"

GOOSED_SIZE=$(du -h "$BIN_DIR/goosed" | cut -f1)
GOOSE_SIZE=$(du -h "$BIN_DIR/goose" | cut -f1)
log_ok "goosed ($GOOSED_SIZE) → $BIN_DIR/goosed"
log_ok "goose  ($GOOSE_SIZE)  → $BIN_DIR/goose"

# ============================================================
# 6. 构建 Electron 前端
# ============================================================
log_info "编译 Electron 前端..."

cd "$DESKTOP_DIR"

# 清理旧的构建产物
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 6a. i18n 编译
log_info "→ 编译 i18n..."
/usr/bin/node scripts/i18n-compile.js
log_ok "i18n 完成"

# 6b. 构建 preload（先构建，防止被后续构建覆盖）
log_info "→ 构建 preload..."
/usr/bin/node "$VITE_BIN" build --config vite.preload.config.mts
log_ok "preload 完成"

# 6c. 构建 main（不 emptyOutDir，保留 preload）
log_info "→ 构建 main..."
/usr/bin/node "$VITE_BIN" build --config vite.main.dev.config.mjs
log_ok "main 完成"

# 6d. 构建 renderer
log_info "→ 构建 renderer..."
/usr/bin/node "$VITE_BIN" build --config vite.renderer.config.mts
log_ok "renderer 完成"

# ============================================================
# 7. 验证产物完整性
# ============================================================
log_info "验证打包产物..."

get_size() {
  if [ -f "$1" ]; then
    du -h "$1" | cut -f1
  else
    echo "❌ 缺失"
  fi
}

MAIN_SIZE=$(get_size "$BUILD_DIR/main.js")
PRELOAD_SIZE=$(get_size "$BUILD_DIR/preload.js")

# 查找 renderer 输出
REAL_INDEX=""
for p in "$DESKTOP_DIR/dist/index.html" "$BUILD_DIR/renderer/index.html"; do
  [ -f "$p" ] && REAL_INDEX="$p" && break
done
INDEX_SIZE=$(get_size "$REAL_INDEX")

echo ""
echo "  ┌─ $BIN_DIR"
echo "  │  ├─ goosed ($GOOSED_SIZE)"
echo "  │  └─ goose  ($GOOSE_SIZE)"
echo "  │"
echo "  ├─ $BUILD_DIR"
echo "  │  ├─ main.js    ($MAIN_SIZE)"
echo "  │  └─ preload.js ($PRELOAD_SIZE)"
echo "  │"
echo "  └─ 前端资源"
echo "     └─ index.html ($INDEX_SIZE)"
echo ""

ERRORS=0
[ ! -f "$BIN_DIR/goosed" ]    && log_error "goosed 缺失"    && ERRORS=$((ERRORS+1))
[ ! -f "$BIN_DIR/goose" ]     && log_error "goose 缺失"     && ERRORS=$((ERRORS+1))
[ ! -f "$BUILD_DIR/main.js" ] && log_error "main.js 缺失"  && ERRORS=$((ERRORS+1))
[ ! -f "$BUILD_DIR/preload.js" ] && log_error "preload.js 缺失" && ERRORS=$((ERRORS+1))
[ -z "$REAL_INDEX" ]          && log_error "index.html 缺失" && ERRORS=$((ERRORS+1))

if [ $ERRORS -gt 0 ]; then
  log_error "共 $ERRORS 个产物缺失，打包失败"
  exit 1
fi

# ============================================================
# 8. 完成
# ============================================================
end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo ""
echo "=============================================="
echo -e "  ${GREEN}🎉 打包完成！共耗时 ${elapsed}s${NC}"
echo "=============================================="
echo ""
echo "  启动命令:"
echo "    bash /home/node118/goose-start.sh"
echo ""
echo "  仅重新构建前端（不编译 Rust）:"
echo "    bash /home/node118/bootstrap.sh --frontend-only"
echo ""
echo "=============================================="
