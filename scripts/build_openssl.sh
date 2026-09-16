#!/usr/bin/env bash
#
# 编译 OpenSSL 3.x 静态库（iOS 真机 arm64 + iOS 模拟器）
#
# 产物：
#   third-party/openssl/iphoneos/lib/libssl.a libcrypto.a
#   third-party/openssl/iphonesimulator/lib/libssl.a libcrypto.a
#   third-party/openssl/{iphoneos,iphonesimulator}/include/...
#
# 目录名特意使用 PLATFORM_NAME（iphoneos / iphonesimulator），
# 与 project.yml 中的 LIBRARY_SEARCH_PATHS 相对应。
#
set -eo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.3.2}"
MIN_IOS="${MIN_IOS:-16.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/third-party"
SRC="$WORK/openssl-$OPENSSL_VERSION"
TARBALL="$WORK/openssl-$OPENSSL_VERSION.tar.gz"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

mkdir -p "$WORK"

# ---------------------------------------------------------------
# 下载源码
# ---------------------------------------------------------------
if [ ! -d "$SRC" ]; then
  log "下载 OpenSSL $OPENSSL_VERSION"
  curl -fL --retry 3 -o "$TARBALL" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
  tar -xzf "$TARBALL" -C "$WORK"
fi

# ---------------------------------------------------------------
# 编译单个平台（OpenSSL 3 支持 out-of-tree 构建）
# ---------------------------------------------------------------
build() {
  local platform="$1" target="$2"
  local builddir="$WORK/openssl-build-$platform"
  local outdir="$WORK/openssl/$platform"

  log "OpenSSL: $platform（target=$target）"
  rm -rf "$builddir" "$outdir"
  mkdir -p "$builddir"
  (
    cd "$builddir"
    # no-shared：静态库；no-module：禁用动态 provider 模块。
    #   关键：模块模式（默认）下 legacyprov.c（provider 入口）不会编进
    #   liblegacy.a，链接必失败（ossl_legacy_provider_init undefined）。
    #   加 no-module 后走 STATIC_LEGACY 分支：legacy provider（MD4/RC4，
    #   NTLM 必需）连同入口函数全部内置进 libcrypto.a。
    # no-tests：跳过测试代码；no-docs：跳过文档
    perl "$SRC/Configure" "$target" \
      no-shared no-module no-tests no-docs \
      "--prefix=$outdir" \
      "-mios-version-min=$MIN_IOS" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" build_sw >/dev/null
    make install_sw >/dev/null
    # 自检：确认 legacy provider 入口真的进了 libcrypto.a。
    # 注意 1：不能写 `nm | grep -q`——本脚本开了 pipefail，grep -q 命中后
    #   立即退出，nm 收到 SIGPIPE 以 141 退出，整条管道被判失败，
    #   导致符号明明存在也误报「未找到」。必须先落盘再查。
    # 注意 2：nm 对 Apple 归档可能返回非零退出码，用 || true 兜住；
    #   判定结果以 grep 是否命中为准。
    nm "$outdir/lib/libcrypto.a" > "$builddir/nm-symbols.txt" 2>/dev/null || true
    if ! grep -q "ossl_legacy_provider_init" "$builddir/nm-symbols.txt"; then
      echo "错误：libcrypto.a 中未找到 ossl_legacy_provider_init（STATIC_LEGACY 未生效）" >&2
      echo "提示：确认 Configure 选项包含 no-module" >&2
      exit 1
    fi
    rm -f "$builddir/nm-symbols.txt"
  )
  echo "  -> $outdir/lib/libssl.a  libcrypto.a（含内置 legacy provider）"
}

build "iphoneos"        "ios64-xcrun"
build "iphonesimulator" "iossimulator-xcrun"

log "OpenSSL 编译完成"
