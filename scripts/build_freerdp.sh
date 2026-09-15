#!/usr/bin/env bash
#
# 编译 FreeRDP 3.x 为静态库（libfreerdp.a + libwinpr.a）
#
# 产物：
#   build/dist-iphoneos/{libfreerdp.a,libwinpr.a}
#   build/dist-iphonesimulator/{libfreerdp.a,libwinpr.a}
#   build/{iphoneos,iphonesimulator}/include/   （CMake 生成的配置头文件）
#
# 说明：
#   - 关闭 FFmpeg，H.264 解码使用系统 VideoToolbox（WITH_VIDEOTOOLBOX=ON）
#   - 关闭所有客户端壳（client/common、client/iOS、SDL），我们自带 SwiftUI 客户端
#   - 目录名使用 PLATFORM_NAME，与 project.yml 的搜索路径对应
#
set -eo pipefail

MIN_IOS="${MIN_IOS:-16.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FREERDP_DIR="$ROOT/FreeRDP"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if [ ! -d "$FREERDP_DIR" ]; then
  echo "错误：未找到 $FREERDP_DIR，请先运行 bootstrap.sh" >&2
  exit 1
fi

build() {
  local platform="$1" frdp_platform="$2"
  local builddir="$ROOT/build/$platform"
  local distdir="$ROOT/build/dist-$platform"

  log "FreeRDP: $platform（PLATFORM=$frdp_platform）"
  cmake -S "$FREERDP_DIR" -B "$builddir" \
    -DCMAKE_TOOLCHAIN_FILE="$FREERDP_DIR/cmake/ios.toolchain.cmake" \
    -DPLATFORM="$frdp_platform" \
    -DDEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_CLIENT_COMMON=OFF \
    -DWITH_CLIENT_IOS=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_SAMPLE_CODE=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_DSP_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_CAIRO=OFF \
    -DWITH_GFX_H264=OFF \
    -DWITH_H264=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_DSP_EXPERIMENTAL=OFF \
    -DWITH_VIDEOTOOLBOX=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_PKCS11=OFF \
    -DWITH_CJSON=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DFREERDP_IOS_EXTERNAL_SSL_PATH="$ROOT/third-party/openssl/$platform"
  cmake --build "$builddir" --config Release --target freerdp winpr

  mkdir -p "$distdir"

  # FreeRDP 3.x 的静态库输出名可能带 API 版本后缀（libfreerdp3.a / libwinpr3.a），
  # 用通配查找并统一重命名为 libfreerdp.a / libwinpr.a（与 project.yml 的 -lfreerdp 对应）。
  # 拷贝后必须校验存在，避免静默失败导致链接阶段才报错。
  frdp_lib="$(find "$builddir" -name "libfreerdp*.a" -not -name "*pkgconfig*" | head -1)"
  winpr_lib="$(find "$builddir" -name "libwinpr*.a" -not -name "*pkgconfig*" | head -1)"
  if [ -z "$frdp_lib" ]; then
    echo "错误：构建树中未找到 libfreerdp*.a" >&2
    find "$builddir" -name "*.a" | head -20 >&2 || true
    exit 1
  fi
  if [ -z "$winpr_lib" ]; then
    echo "错误：构建树中未找到 libwinpr*.a" >&2
    find "$builddir" -name "*.a" | head -20 >&2 || true
    exit 1
  fi
  cp -v "$frdp_lib"  "$distdir/libfreerdp.a"
  cp -v "$winpr_lib" "$distdir/libwinpr.a"
}

build "iphoneos"        "OS64"
build "iphonesimulator" "SIMULATORARM64"

log "FreeRDP 编译完成"
ls -lh "$ROOT"/build/dist-iphoneos "$ROOT"/build/dist-iphonesimulator
