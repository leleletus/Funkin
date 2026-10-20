#!/usr/bin/env bash
# Builds the minimal FFmpeg used by the Switch video player: LGPL 2.1+, H.264, HEVC and VP9 decoders, MP4 and
# Matroska demuxers, swscale and nothing else (~3 MB, against ~34 MB of heap for devkitPro's GPL switch-ffmpeg).
# HEVC, VP9 and Matroska are there for the official files as they ship (2Hot is HEVC 1080p, Darnell VP9, Week 7 MKV).
#
#   ./tools/nx-tools/build_ffmpeg_nx.sh          # build if missing or outdated
#   ./tools/nx-tools/build_ffmpeg_nx.sh --force  # rebuild from a clean tree
#
# Output (not versioned): export/nx-generated/ffmpeg/{include,lib}. The libraries carry the suffix
# "_nx" (libavcodec_nx.a, ...) so the stock package in portlibs, searched first, never shadows them.
set -euo pipefail

VERSION=7.1
SHA256=40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/export/nx-generated/ffmpeg"
SRC="$WORK/src/ffmpeg-$VERSION"
PATCH="$ROOT/tools/nx-tools/ffmpeg/horizon.patch"
TARBALL="$WORK/src/ffmpeg-$VERSION.tar.xz"
STAMP="$WORK/.build-stamp"

: "${DEVKITPRO:=/opt/devkitpro}"
export PATH="$DEVKITPRO/devkitA64/bin:$PATH"

CONFIGURE_FLAGS=(
  --prefix="$WORK" --build-suffix=_nx
  --enable-cross-compile --cross-prefix=aarch64-none-elf- --arch=aarch64 --cpu=cortex-a57 --target-os=horizon
  --enable-static --disable-shared --enable-pic --enable-asm --enable-neon --disable-runtime-cpudetect
  --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug
  --disable-avdevice --disable-avfilter --disable-swresample --disable-postproc --disable-network
  --disable-zlib --disable-bzlib --disable-iconv --disable-lzma
  --enable-pthreads --enable-swscale
  --enable-decoder=h264,hevc,vp9 --enable-parser=h264,hevc,vp9 --enable-demuxer=mov,matroska --enable-protocol=file
  --extra-cflags="-D__SWITCH__ -D_GNU_SOURCE -march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIC -ftls-model=local-exec -ffunction-sections -fdata-sections -I$DEVKITPRO/libnx/include"
  --extra-ldflags="-fPIE -L$DEVKITPRO/libnx/lib"
)

want="$VERSION $SHA256 $(sha256sum "$PATCH" "$0" | cut -c1-16 | tr '\n' ' ')"
if [[ "${1:-}" != "--force" && -f "$STAMP" && "$(cat "$STAMP")" == "$want" ]]; then
  echo "[build_ffmpeg_nx] up to date: $WORK"
  exit 0
fi

mkdir -p "$WORK/src"
if [[ ! -f "$TARBALL" ]] || ! echo "$SHA256  $TARBALL" | sha256sum -c --status; then
  echo "[build_ffmpeg_nx] downloading ffmpeg-$VERSION"
  curl -fsSL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  echo "$SHA256  $TARBALL" | sha256sum -c --status || { echo "[build_ffmpeg_nx] checksum mismatch" >&2; exit 1; }
fi

rm -rf "$SRC" "$WORK/include" "$WORK/lib"
tar -xf "$TARBALL" -C "$WORK/src"
patch -d "$SRC" -Np1 -s -i "$PATCH"

cd "$SRC"
./configure "${CONFIGURE_FLAGS[@]}" > "$WORK/configure.log" 2>&1 || { tail -n 30 "$WORK/configure.log"; tail -n 40 ffbuild/config.log; exit 1; }
make -j"$(nproc)" > "$WORK/make.log" 2>&1 || { tail -n 40 "$WORK/make.log"; exit 1; }
make install > /dev/null

for lib in avcodec avformat avutil swscale; do
  [[ -f "$WORK/lib/lib${lib}_nx.a" ]] || { echo "[build_ffmpeg_nx] missing lib${lib}_nx.a" >&2; exit 1; }
done
# grep -c reads everything: with pipefail, grep -q would end strings with SIGPIPE and fail the check.
if ! strings "$WORK/lib/libavcodec_nx.a" | grep -c "LGPL version 2.1 or later" > /dev/null; then
  echo "[build_ffmpeg_nx] libavcodec_nx.a is not LGPL" >&2
  exit 1
fi
rm -rf "$WORK/share"
echo "$want" > "$STAMP"
du -ch "$WORK"/lib/*.a | tail -n1 | sed "s|total|[build_ffmpeg_nx] built in $WORK/lib|"
