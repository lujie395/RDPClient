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

MIN_IOS="${MIN_IOS:-18.0}"

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
    -DFREERDP_IOS_EXTERNAL_SSL_PATH="$ROOT/third-party/openssl/$platform"
  cmake --build "$builddir" --config Release --target freerdp winpr

  mkdir -p "$distdir"
  find "$builddir" -name "libfreerdp.a" -exec cp -v {} "$distdir/" \;
  find "$builddir" -name "libwinpr.a"   -exec cp -v {} "$distdir/" \;
}

build "iphoneos"        "OS64"
build "iphonesimulator" "SIMULATORARM64"

log "FreeRDP 编译完成"
ls -lh "$ROOT"/build/dist-iphoneos "$ROOT"/build/dist-iphonesimulator
