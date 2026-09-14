#!/usr/bin/env bash
#
# RDPClient 一键构建脚本
#
# 功能：
#   1. 克隆 FreeRDP 源码（锁定版本 tag）
#   2. 编译 OpenSSL 静态库（真机 arm64 + 模拟器）
#   3. 编译 FreeRDP 静态库（libfreerdp.a / libwinpr.a）
#   4. 用 XcodeGen 生成 RDPClient.xcodeproj
#
# 环境要求（macOS）：
#   - Xcode 16+（含 iOS 18 SDK）
#   - cmake >= 3.13        （brew install cmake）
#   - xcodegen             （brew install xcodegen，脚本会自动尝试安装）
#
# 用法：
#   ./bootstrap.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 可通过环境变量覆盖 FreeRDP 版本，例如：FREERDP_REF=3.31.1 ./bootstrap.sh
FREERDP_REF="${FREERDP_REF:-3.31.1}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------
log "检查构建环境"
for tool in git cmake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "错误：缺少 $tool。请先安装：brew install $tool" >&2
    exit 1
  fi
done
if ! xcode-select -p >/dev/null 2>&1; then
  echo "错误：未检测到 Xcode，请先安装 Xcode 并执行 xcode-select --install" >&2
  exit 1
fi

# ---------------------------------------------------------------
# 1. FreeRDP 源码
# ---------------------------------------------------------------
if [ ! -d "$ROOT/FreeRDP" ]; then
  log "克隆 FreeRDP（ref: $FREERDP_REF）"
  if ! git clone --depth 1 --branch "$FREERDP_REF" \
        https://github.com/FreeRDP/FreeRDP.git FreeRDP 2>/dev/null; then
    echo "警告：无法获取 tag $FREERDP_REF，改用 master 分支" >&2
    git clone --depth 1 https://github.com/FreeRDP/FreeRDP.git FreeRDP
  fi
else
  log "FreeRDP 源码已存在，跳过克隆"
fi

# ---------------------------------------------------------------
# 2. OpenSSL 静态库
# ---------------------------------------------------------------
log "编译 OpenSSL（真机 + 模拟器，首次约 10~20 分钟）"
bash "$ROOT/scripts/build_openssl.sh"

# ---------------------------------------------------------------
# 3. FreeRDP 静态库
# ---------------------------------------------------------------
log "编译 FreeRDP（首次约 10~30 分钟）"
bash "$ROOT/scripts/build_freerdp.sh"

# ---------------------------------------------------------------
# 4. 生成 Xcode 工程
# ---------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  log "未检测到 xcodegen，尝试通过 Homebrew 安装"
  if ! command -v brew >/dev/null 2>&1; then
    echo "错误：请先安装 Homebrew（https://brew.sh），然后重新运行本脚本" >&2
    exit 1
  fi
  brew install xcodegen
fi

log "生成 RDPClient.xcodeproj"
xcodegen generate

log "全部完成！下一步："
echo "    open RDPClient.xcodeproj   # 在 Xcode 里选择你的 Team，连接 iPhone/iPad 运行"
