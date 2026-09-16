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
    # no-shared：静态库；no-tests：跳过测试代码；no-docs：跳过文档
    perl "$SRC/Configure" "$target" \
      no-shared no-tests no-docs \
      "--prefix=$outdir" \
      "-mios-version-min=$MIN_IOS" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" build_sw >/dev/null
    make install_sw >/dev/null
    # 关键：legacy provider（MD4/RC4/NTLM 必需）在静态构建下是独立的
    # liblegacy.a，install_sw 不会安装，必须手动拷贝。
    # 没有 it：NLA/CredSSP 认证必然失败（NTLM 哈希依赖 MD4）。
    if [ ! -f "$builddir/providers/liblegacy.a" ]; then
      echo "错误：未生成 providers/liblegacy.a（legacy provider）" >&2
      exit 1
    fi
    cp -v "$builddir/providers/liblegacy.a" "$outdir/lib/liblegacy.a"
  )
  echo "  -> $outdir/lib/libssl.a  libcrypto.a  liblegacy.a"
}

build "iphoneos"        "ios64-xcrun"
build "iphonesimulator" "iossimulator-xcrun"

log "OpenSSL 编译完成"
