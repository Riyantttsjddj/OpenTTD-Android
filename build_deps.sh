#!/bin/bash
# Cross-compile OpenTTD's dependency libraries for Android.
#
# Everything installs into a per-ABI prefix so the OpenTTD configure step can
# find the whole set through one CMAKE_PREFIX_PATH.  Each library is a separate
# function so a single failure does not lose the rest of the run; pass library
# names as arguments to build only those.
#
# Usage: build_deps.sh [arm64|armv7] [lib ...]
#   The first argument selects the ABI (default arm64).  Libraries build into
#   /root/build/prefix for arm64 and /root/build/prefix-armv7 for armv7, so the
#   two ABIs never clobber each other.
set -uo pipefail

SRC=/root/build/src
BLD=/root/build/bld
TC=/root/ndk-mirror/build/cmake/android.toolchain.cmake
JOBS=${JOBS:-4}

TC_BIN=/root/ndk-mirror/toolchains/llvm/prebuilt/linux-x86_64/bin

ABI_ARG=${1:-arm64}
shift || true

case "$ABI_ARG" in
  arm64)
    ANDROID_ABI=arm64-v8a
    PFX=/root/build/prefix
    CLANG=($TC_BIN/aarch64-linux-android24-clang)
    HOST=aarch64-linux-android24
    OPENSSL_TARGET=android-arm64
    ;;
  armv7)
    ANDROID_ABI=armeabi-v7a
    PFX=/root/build/prefix-armv7
    CLANG=($TC_BIN/armv7a-linux-androideabi24-clang)
    HOST=armv7a-linux-androideabi24
    OPENSSL_TARGET=android-arm
    ;;
  *)
    echo "unknown ABI: $ABI_ARG (use arm64 or armv7)" >&2
    exit 2
    ;;
esac

mkdir -p "$BLD" "$PFX"

COMMON=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$TC"
  -DANDROID_ABI="$ANDROID_ABI"
  -DANDROID_PLATFORM=android-24
  -DCMAKE_INSTALL_PREFIX="$PFX"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_PREFIX_PATH="$PFX"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
)

step() {
  local name="$1"; shift
  local src="$1"; shift
  echo "=============================================================="
  echo "== $name"
  echo "=============================================================="
  rm -rf "$BLD/$name"
  mkdir -p "$BLD/$name"
  if ! cmake -S "$src" -B "$BLD/$name" "${COMMON[@]}" "$@" >"$BLD/$name.cfg.log" 2>&1; then
    echo "!! $name: CONFIGURE FAILED (see $BLD/$name.cfg.log)"
    tail -25 "$BLD/$name.cfg.log"
    return 1
  fi
  if ! cmake --build "$BLD/$name" -j "$JOBS" >"$BLD/$name.build.log" 2>&1; then
    echo "!! $name: BUILD FAILED (see $BLD/$name.build.log)"
    tail -25 "$BLD/$name.build.log"
    return 1
  fi
  if ! cmake --install "$BLD/$name" >"$BLD/$name.install.log" 2>&1; then
    echo "!! $name: INSTALL FAILED (see $BLD/$name.install.log)"
    tail -25 "$BLD/$name.install.log"
    return 1
  fi
  echo "ok $name"
}

build_zlib() {
  step zlib "$SRC/zlib-1.3.1" \
    -DZLIB_BUILD_EXAMPLES=OFF -DINSTALL_UTILS=OFF
}

# lzo has no CMake build.  Configure it with autotools: it is small and ships a
# lzo2.pc, which is what OpenTTD's FindLZO looks for first.
build_lzo() {
  local name=lzo
  echo "=============================================================="
  echo "== $name (autotools)"
  echo "=============================================================="
  rm -rf "$BLD/$name"; mkdir -p "$BLD/$name"
  ( cd "$BLD/$name" &&
    CC="${CLANG[0]}" \
    AR="$TC_BIN/llvm-ar" RANLIB="$TC_BIN/llvm-ranlib" \
    "$SRC/lzo-2.10/configure" \
      --host="$HOST" \
      --prefix="$PFX" --enable-static --disable-shared \
      >"$BLD/$name.cfg.log" 2>&1 &&
    make -j "$JOBS" >"$BLD/$name.build.log" 2>&1 &&
    make install >"$BLD/$name.install.log" 2>&1 )
  if [ $? -ne 0 ] || [ ! -f "$PFX/lib/liblzo2.a" ]; then
    echo "!! $name FAILED"; tail -20 "$BLD/$name.cfg.log" 2>/dev/null; tail -20 "$BLD/$name.build.log" 2>/dev/null
    return 1
  fi
  echo "ok $name"
}

build_xz() {
  step xz "$SRC/xz-5.6.3" \
    -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
    -DXZ_TOOL_LZMADEC=OFF -DXZ_NLS=OFF \
    -DCREATE_XZ_SYMLINKS=OFF -DCREATE_LZMA_SYMLINKS=OFF
}

build_png() {
  step libpng "$SRC/libpng-1.6.44" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
    -DPNG_EXECUTABLES=OFF -DPNG_TOOLS=OFF \
    -DZLIB_ROOT="$PFX" -DZLIB_LIBRARY="$PFX/lib/libz.a" \
    -DZLIB_INCLUDE_DIR="$PFX/include"
}

build_freetype() {
  step freetype "$SRC/freetype-2.13.3" \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_PNG=OFF \
    -DZLIB_INCLUDE_DIR="$PFX/include" -DZLIB_LIBRARY="$PFX/lib/libz.a" \
    -DPNG_PNG_INCLUDE_DIR="$PFX/include" -DPNG_LIBRARY="$PFX/lib/libpng.a"
}

build_harfbuzz() {
  # HarfBuzz's find_package(Freetype) goes through CMake's FindFreetype module,
  # whose find_library/find_path searches are confined to the toolchain's root
  # path while cross-compiling.  Point it straight at the prefix we installed.
  step harfbuzz "$SRC/harfbuzz-10.0.1" \
    -DHB_HAVE_FREETYPE=ON -DHB_HAVE_ICU=OFF \
    -DHB_BUILD_UTILS=OFF -DHB_BUILD_TESTS=OFF -DHB_BUILD_SUBSET=OFF \
    -DFREETYPE_LIBRARY="$PFX/lib/libfreetype.a" \
    -DFREETYPE_INCLUDE_DIRS="$PFX/include/freetype2"
}

# OpenSSL 3.x has a first-class `android-arm64` target, which is more reliable
# here than driving its CMake build.  no-asm skips the hand-written arm64
# assembly: it needs a Perl assembler pipeline that adds nothing for TLS in a
# game client, and dropping it removes a whole class of build failure.
build_openssl() {
  local name=openssl
  echo "=============================================================="
  echo "== $name (Configure android-arm64)"
  echo "=============================================================="
  rm -rf "$BLD/$name"; mkdir -p "$BLD/$name"
  (
    # Configure records CC by basename, so the toolchain must stay on PATH for
    # the make step as well -- not just for Configure.
    export PATH="$TC_BIN:$PATH"
    export ANDROID_NDK_ROOT=/root/ndk-mirror
    cd "$BLD/$name" &&
    "$SRC/openssl-3.0.16/Configure" "$OPENSSL_TARGET" \
      -D__ANDROID_API__=24 \
      no-shared no-tests no-asm no-ui-console \
      --prefix="$PFX" --openssldir="$PFX/ssl" \
      CC="${CLANG[0]}" \
      AR="$TC_BIN/llvm-ar" RANLIB="$TC_BIN/llvm-ranlib" \
      >"$BLD/$name.cfg.log" 2>&1 &&
    make -j "$JOBS" >"$BLD/$name.build.log" 2>&1 &&
    make install_sw >"$BLD/$name.install.log" 2>&1
  )
  if [ $? -ne 0 ] || [ ! -f "$PFX/lib/libssl.a" ]; then
    echo "!! $name FAILED"
    tail -20 "$BLD/$name.cfg.log" 2>/dev/null
    tail -20 "$BLD/$name.build.log" 2>/dev/null
    return 1
  fi
  echo "ok $name"
}

build_sdl2() {
  # SDL2 must be a shared library on Android: SDLActivity dlopen()s libSDL2.so
  # and reaches the native code through it.  Static is built as well because
  # SDL2main is linked that way.
  #
  # SDL2 installs its own SDL2Config.cmake, so OpenTTD's find_package(SDL2)
  # resolves through CMAKE_PREFIX_PATH without help.
  step SDL2 "$SRC/SDL-release-2.32.10" \
    -DSDL_SHARED=ON -DSDL_STATIC=ON \
    -DSDL_TEST=OFF -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF \
    -DSDL_DISABLE_INSTALL_DOCS=ON -DSDL_INSTALL_TESTS=OFF \
    -DVIDEO_OPENGL=ON -DVIDEO_OPENGLES=ON \
    -DSDL_HIDAPI=ON -DSDL_HIDAPI_JOYSTICK=ON -DSDL_HIDAPI_LIBUSB=OFF \
    -DSDL_LIBC=ON \
    -DSDL_SYSTEM_ICONV=OFF -DSDL_ICONV=OFF
}

build_curl() {
  step curl "$SRC/curl-8.10.1" \
    -DBUILD_CURL_EXE=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$PFX" \
    -DOPENSSL_INCLUDE_DIR="$PFX/include" \
    -DOPENSSL_SSL_LIBRARY="$PFX/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$PFX/lib/libcrypto.a" \
    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_TELNET=ON -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_GOPHER=ON -DCURL_DISABLE_MQTT=ON \
    -DCMAKE_USE_SYSTEM_LIBRARIES=OFF \
    -DZLIB_INCLUDE_DIR="$PFX/include" -DZLIB_LIBRARY="$PFX/lib/libz.a"
}

want=("$@")
[ ${#want[@]} -eq 0 ] && want=(zlib lzo xz png freetype harfbuzz openssl curl SDL2)

rc=0
for lib in "${want[@]}"; do
  case "$lib" in
    zlib)     build_zlib ;;
    lzo)      build_lzo ;;
    xz)       build_xz ;;
    png)      build_png ;;
    freetype) build_freetype ;;
    harfbuzz) build_harfbuzz ;;
    SDL2|sdl2) build_sdl2 ;;
    openssl)  build_openssl ;;
    curl)     build_curl ;;
    *) echo "unknown library: $lib"; rc=1 ;;
  esac || rc=1
done

echo
echo "=== installed into $PFX ==="
ls "$PFX/lib"/*.a 2>/dev/null
echo "--- pkgconfig ---"
ls "$PFX"/lib/pkgconfig "$PFX"/share/pkgconfig 2>/dev/null
exit $rc
