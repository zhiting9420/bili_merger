#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# BiliMerger — slim ffmpeg for Android arm64-v8a
#
#   Builds a standalone `ffmpeg` executable (shipped as libffmpeg.so in
#   jniLibs/arm64-v8a) that only contains what BiliMerger actually needs:
#     demux  : mov/mp4/fMP4 (.m4s), raw h264/hevc/aac/mp3, image2
#     decode : h264, hevc, av1(libdav1d), aac, opus, mp3  (+ *_mediacodec)
#     encode : libx264, aac, mjpeg                        (+ *_mediacodec)
#     mux    : mp4, mov, image2, null
#     filter : ass (libass+freetype+fribidi+harfbuzz), scale, format, ...
#     proto  : file, pipe
#   NEON/ASM is ENABLED (the old vcpkg build used --disable-asm).
#
# Usage:  bash build-ffmpeg-slim.sh [clean]
# Output: $ROOT/out/libffmpeg.so
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
BLD="$ROOT/build"
PREFIX="$ROOT/sysroot"
OUT="$ROOT/out"

# ---- versions --------------------------------------------------------------
FFMPEG_VER=${FFMPEG_VER:-8.1.2}
DAV1D_VER=1.5.1
FREETYPE_VER=2.13.3
FRIBIDI_VER=1.0.16
HARFBUZZ_VER=10.4.0
LIBASS_VER=0.17.3

# ---- toolchain -------------------------------------------------------------
# NDK 位置。设 ANDROID_NDK_HOME 指定,否则从 ANDROID_HOME/ANDROID_SDK_ROOT 下自动挑最新的一个。
NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
  for base in "${ANDROID_HOME:-$HOME/Android/Sdk}" "${ANDROID_SDK_ROOT:-}"; do
    [ -d "$base/ndk" ] || continue
    NDK=$(find "$base/ndk" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)
    [ -n "$NDK" ] && break
  done
fi
if [ ! -d "$NDK" ]; then
  echo "找不到 Android NDK。请设置 ANDROID_NDK_HOME 后重试。" >&2
  exit 1
fi
API=24
ABI=arm64-v8a
TRIPLE=aarch64-linux-android
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$TC/bin:$PATH"

export CC="$TC/bin/${TRIPLE}${API}-clang"
export CXX="$TC/bin/${TRIPLE}${API}-clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export NM="$TC/bin/llvm-nm"
export STRIP="$TC/bin/llvm-strip"
export LD="$TC/bin/ld.lld"
export AS="$CC"
export CFLAGS="-Os -fPIC -DANDROID -D__ANDROID_API__=$API -ffunction-sections -fdata-sections"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -Wl,-z,max-page-size=16384"

export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
NPROC=$(nproc)

[ "${1:-}" = "clean" ] && rm -rf "$BLD" "$PREFIX" "$OUT"
mkdir -p "$SRC" "$BLD" "$PREFIX" "$OUT"

# ---- fetch -----------------------------------------------------------------
export http_proxy=${http_proxy:-http://127.0.0.1:2080}
export https_proxy=${https_proxy:-http://127.0.0.1:2080}
fetch() { # url file
  [ -f "$SRC/$2" ] || curl -sSL --retry 3 -o "$SRC/$2" "$1"
}
fetch https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz              ffmpeg-$FFMPEG_VER.tar.xz
fetch https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VER/dav1d-$DAV1D_VER.tar.gz dav1d-$DAV1D_VER.tar.gz
fetch https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz     freetype-$FREETYPE_VER.tar.xz
fetch https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VER/fribidi-$FRIBIDI_VER.tar.xz fribidi-$FRIBIDI_VER.tar.xz
fetch https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VER/harfbuzz-$HARFBUZZ_VER.tar.xz harfbuzz-$HARFBUZZ_VER.tar.xz
fetch https://github.com/libass/libass/releases/download/$LIBASS_VER/libass-$LIBASS_VER.tar.xz libass-$LIBASS_VER.tar.xz
[ -d "$SRC/x264" ] || git clone --depth 1 -b stable https://code.videolan.org/videolan/x264.git "$SRC/x264"

untar() { [ -d "$SRC/$2" ] || tar -C "$SRC" -xf "$SRC/$1"; }
untar ffmpeg-$FFMPEG_VER.tar.xz     ffmpeg-$FFMPEG_VER
untar dav1d-$DAV1D_VER.tar.gz       dav1d-$DAV1D_VER
untar freetype-$FREETYPE_VER.tar.xz freetype-$FREETYPE_VER
untar fribidi-$FRIBIDI_VER.tar.xz   fribidi-$FRIBIDI_VER
untar harfbuzz-$HARFBUZZ_VER.tar.xz harfbuzz-$HARFBUZZ_VER
untar libass-$LIBASS_VER.tar.xz     libass-$LIBASS_VER

# ---- local patches --------------------------------------------------------
# 0001: h264/hevc_mediacodec encoder writes into the codec's input buffer using
#       stride==FFALIGN(width,16); real devices pad much more (e.g. width 1440
#       -> stride 1536, height 1080 -> slice-height 1088) which shears the
#       picture and paints the bottom green.  Query AMediaCodec_getInputFormat
#       and use the reported stride / slice-height instead.
if [ -d "$ROOT/patches" ]; then
  for p in "$ROOT"/patches/*.patch; do
    [ -e "$p" ] || continue
    if ( cd "$SRC/ffmpeg-$FFMPEG_VER" && patch -p1 --dry-run --silent < "$p" ) >/dev/null 2>&1; then
      echo "applying $(basename "$p")"
      ( cd "$SRC/ffmpeg-$FFMPEG_VER" && patch -p1 < "$p" )
    else
      echo "skipping $(basename "$p") (already applied or does not apply)"
    fi
  done
fi

# ---- meson cross file ------------------------------------------------------
cat > "$BLD/android-arm64.cross" <<EOF
[binaries]
c        = '$CC'
cpp      = '$CXX'
ar       = '$AR'
strip    = '$STRIP'
pkg-config = 'pkg-config'
[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
[built-in options]
c_args      = ['-fPIC']
cpp_args    = ['-fPIC']
c_link_args = ['-Wl,--gc-sections']
cpp_link_args = ['-Wl,--gc-sections']
EOF

step() { echo; echo "################ $* ################"; echo; }

# ---- dav1d (AV1 decoder) ---------------------------------------------------
if [ ! -f "$PREFIX/lib/libdav1d.a" ]; then
step dav1d
rm -rf "$BLD/dav1d"
meson setup "$BLD/dav1d" "$SRC/dav1d-$DAV1D_VER" \
  --cross-file "$BLD/android-arm64.cross" \
  --prefix "$PREFIX" --libdir lib --buildtype release \
  --default-library=static \
  -Denable_tools=false -Denable_tests=false -Denable_examples=false \
  -Dbitdepths="8,16"
ninja -C "$BLD/dav1d" -j$NPROC
ninja -C "$BLD/dav1d" install
fi

# ---- x264 (H.264 software encoder) -----------------------------------------
if [ ! -f "$PREFIX/lib/libx264.a" ]; then
step x264
rm -rf "$BLD/x264"; mkdir -p "$BLD/x264"
( cd "$BLD/x264" && "$SRC/x264/configure" \
    --prefix="$PREFIX" --host=$TRIPLE --cross-prefix="$TC/bin/llvm-" \
    --sysroot="$TC/sysroot" \
    --enable-static --enable-pic --disable-cli --disable-opencl \
    --bit-depth=8 --chroma-format=420 \
    --extra-cflags="-O3 -fPIC" \
  && make -j$NPROC && make install )
fi

# ---- fribidi ---------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libfribidi.a" ]; then
step fribidi
rm -rf "$BLD/fribidi"; mkdir -p "$BLD/fribidi"
( cd "$BLD/fribidi" && "$SRC/fribidi-$FRIBIDI_VER/configure" \
    --host=$TRIPLE --prefix="$PREFIX" \
    --enable-static --disable-shared --disable-docs --disable-debug \
  && make -j$NPROC && make install )
fi

# ---- freetype (pass 1, no harfbuzz) ----------------------------------------
if [ ! -f "$PREFIX/lib/libfreetype.a" ]; then
step "freetype (pass 1)"
rm -rf "$BLD/freetype"; mkdir -p "$BLD/freetype"
( cd "$BLD/freetype" && "$SRC/freetype-$FREETYPE_VER/configure" \
    --host=$TRIPLE --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --with-zlib=no --with-bzip2=no --with-png=no --with-brotli=no --with-harfbuzz=no \
  && make -j$NPROC && make install )
fi

# ---- harfbuzz (text shaping for libass) ------------------------------------
if [ ! -f "$PREFIX/lib/libharfbuzz.a" ]; then
step harfbuzz
rm -rf "$BLD/harfbuzz"
meson setup "$BLD/harfbuzz" "$SRC/harfbuzz-$HARFBUZZ_VER" \
  --cross-file "$BLD/android-arm64.cross" \
  --prefix "$PREFIX" --libdir lib --buildtype release -Doptimization=s \
  --default-library=static \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
  -Dgraphite2=disabled -Dchafa=disabled -Dtests=disabled -Ddocs=disabled \
  -Dutilities=disabled -Dbenchmark=disabled -Dfreetype=enabled
ninja -C "$BLD/harfbuzz" -j$NPROC
ninja -C "$BLD/harfbuzz" install
fi

# ---- freetype (pass 2, with harfbuzz — better autohinting) -----------------
if [ ! -f "$PREFIX/lib/.freetype-pass2" ]; then
step "freetype (pass 2, +harfbuzz)"
rm -rf "$BLD/freetype2"; mkdir -p "$BLD/freetype2"
( cd "$BLD/freetype2" && PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
  "$SRC/freetype-$FREETYPE_VER/configure" \
    --host=$TRIPLE --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --with-zlib=no --with-bzip2=no --with-png=no --with-brotli=no --with-harfbuzz=yes \
  && make -j$NPROC && make install )
touch "$PREFIX/lib/.freetype-pass2"
fi

# ---- libass ----------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libass.a" ]; then
step libass
rm -rf "$BLD/libass"; mkdir -p "$BLD/libass"
( cd "$BLD/libass" && "$SRC/libass-$LIBASS_VER/configure" \
    --host=$TRIPLE --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --disable-fontconfig --disable-require-system-font-provider \
    --enable-harfbuzz --enable-asm \
  && make -j$NPROC && make install )
fi

# ---- ffmpeg ----------------------------------------------------------------
step ffmpeg
rm -rf "$BLD/ffmpeg"; mkdir -p "$BLD/ffmpeg"

DECODERS="h264,hevc,libdav1d,aac,aac_latm,opus,mp3,mp3float,mjpeg,pcm_s16le,rawvideo"
DECODERS="$DECODERS,h264_mediacodec,hevc_mediacodec,av1_mediacodec"
ENCODERS="libx264,aac,mjpeg,pcm_s16le,rawvideo,wrapped_avframe"
ENCODERS="$ENCODERS,h264_mediacodec,hevc_mediacodec"
DEMUXERS="mov,h264,hevc,aac,mp3,image2,image2pipe,rawvideo,concat,data"
MUXERS="mp4,mov,image2,image2pipe,null,rawvideo,md5"
PARSERS="h264,hevc,av1,aac,aac_latm,mpegaudio,opus,mjpeg"
BSFS="h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata,null,setts,h264_metadata,hevc_metadata"
FILTERS="ass,scale,format,null,copy,anull,aformat,aresample,atrim,trim,setpts,asetpts,fps,crop,hflip,vflip,transpose,rotate,pad,setsar,setdar,settb,asettb,volume"
PROTOCOLS="file,pipe,fd"

CONFIGURE_ARGS=(
  --prefix="$OUT/install"
  --target-os=android
  --arch=aarch64
  --cpu=armv8-a
  --enable-cross-compile
  --cross-prefix="$TC/bin/llvm-"
  --cc="$CC" --cxx="$CXX" --ld="$CC"
  --nm="$NM" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP"
  --sysroot="$TC/sysroot"
  --pkg-config=pkg-config --pkg-config-flags=--static

  # ---- what we build --------------------------------------------------
  --enable-ffmpeg --disable-ffplay --disable-ffprobe
  --disable-avdevice --disable-doc
  --disable-shared --enable-static --enable-pic

  # ---- strip everything, then whitelist -------------------------------
  --disable-everything
  --disable-autodetect
  --disable-network
  --disable-iconv --disable-xlib --disable-zlib --disable-bzlib --disable-lzma
  --disable-sdl2 --disable-openssl --disable-vulkan
  --disable-debug --disable-symver

  # ---- ASM / NEON ON (old vcpkg build had --disable-asm) --------------
  --enable-asm --enable-neon --enable-optimizations
  --enable-runtime-cpudetect

  # ---- external libs --------------------------------------------------
  --enable-gpl
  --enable-libx264
  --enable-libdav1d
  --enable-libass --enable-libfreetype --enable-libfribidi --enable-libharfbuzz
  --disable-libfontconfig

  # ---- Android MediaCodec via NDK (no JavaVM in a standalone process) --
  --enable-jni
  --enable-mediacodec

  --enable-decoder="$DECODERS"
  --enable-encoder="$ENCODERS"
  --enable-demuxer="$DEMUXERS"
  --enable-muxer="$MUXERS"
  --enable-parser="$PARSERS"
  --enable-bsf="$BSFS"
  --enable-filter="$FILTERS"
  --enable-protocol="$PROTOCOLS"

  --extra-cflags="-O3 -fPIC -I$PREFIX/include"
  --extra-cxxflags="-O3 -fPIC -I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib -Wl,--gc-sections -Wl,-z,max-page-size=16384"
  --extra-libs="-lm -ldl -lmediandk -landroid"
)

( cd "$BLD/ffmpeg" && "$SRC/ffmpeg-$FFMPEG_VER/configure" "${CONFIGURE_ARGS[@]}" )
make -C "$BLD/ffmpeg" -j$NPROC
"$STRIP" --strip-all -o "$OUT/libffmpeg.so" "$BLD/ffmpeg/ffmpeg"

# record the exact configure line for reproducibility
printf '%q ' "$SRC/ffmpeg-$FFMPEG_VER/configure" "${CONFIGURE_ARGS[@]}" > "$OUT/configure-cmdline.txt"

echo
echo "=========================================================="
ls -l "$OUT/libffmpeg.so"
echo "size: $(du -h "$OUT/libffmpeg.so" | cut -f1)"
file "$OUT/libffmpeg.so"
readelf -d "$OUT/libffmpeg.so" | grep NEEDED
echo "=========================================================="
