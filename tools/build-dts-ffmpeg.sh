#!/bin/sh
export TMPDIR="${TMPDIR:-/tmp}"
TMPDIR="${TMPDIR%/}"
# Minimal static LGPL FFmpeg: DTS decode, stereo AAC and AC3 5.1 encode (no GPL/nonfree). No FFmpeg
# network/TLS protocols or software video decoders enter the TV executable.
#
# NUVIO_DTS_TARGET picks the build:
#   webos (default) cross build with the LG SDK (tools/Dockerfile); DTS + TrueHD decode.
#   tpk             Samsung .tpk (tools/tpk.sh). ARM32 build inside the selected SDK
#                   container, from the source tree tpk.sh already downloaded and checked on the
#                   host (NUVIO_DTS_SRC; the container has no curl). Adds what the Samsung loopback
#                   converter needs: mpegts/matroska/mp4 muxers and zlib.
# TrueHD/MLP decoders, mlp/ac3 parsers and the truehd_core bsf are enabled for every target.
set -eu
VERSION=7.1.5
SHA256=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
PREFIX=${NUVIO_DTS_ROOT:-/opt/nuvio-dts}
BUILD=${NUVIO_DTS_BUILD:-${TMPDIR:-/tmp}/nuvio-dts-build}
TARGET=${NUVIO_DTS_TARGET:-webos}
DECODERS=dca,truehd,mlp,dvdsub,pgssub,ass,ssa,subrip,movtext,webvtt
MUXERS=
PARSERS=dca,mlp,ac3,h264,hevc,aac
BSFS=h264_mp4toannexb,hevc_mp4toannexb,dca_core,truehd_core
ZLIB=
mkdir -p "$BUILD" "$PREFIX"
if [ "$TARGET" = tpk ]; then
  SRC=${NUVIO_DTS_SRC:?tools/tpk.sh passes the extracted ffmpeg-$VERSION source}
  CC=${CC:-gcc}
  MUXERS=mpegts,matroska,mp4
  # zlib: Matroska tracks stored zlib-compressed (ContentCompression) and MP4
  # with a compressed header (cmov) arrive raw without it ("Unsupported encoding
  # type"). The .tpk already links the SDK's static libz.a (tools/tpk.sh, also
  # used by epg.c), so this adds no new dependency on the TV.
  ZLIB=--enable-zlib
  # Out of tree: the source stays clean in the host cache.
  mkdir -p "$BUILD/obj"
  cd "$BUILD/obj"
  set -- --cc="$CC"
  if [ "${NUVIO_TPK_CROSS:-0}" = 1 ]; then
    set -- "$@" --enable-cross-compile --arch=arm --target-os=linux \
      --cross-prefix=arm-linux-gnueabi-
  fi
else
  CC=${CC:-arm-webos-linux-gnueabi-gcc}
  archive="$BUILD/ffmpeg-$VERSION.tar.xz"
  if [ ! -f "$archive" ]; then
    for i in 1 2 3 4 5 6; do
      curl -fsSL --tlsv1.2 --connect-timeout 20 \
        "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$archive" && break
      echo "download falhou (tentativa $i), aguardando..." >&2
      rm -f "$archive"
      sleep $((i * 10))
    done
  fi
  printf '%s  %s\n' "$SHA256" "$archive" | sha256sum -c -
  tar -xf "$archive" -C "$BUILD"
  SRC=.
  cd "$BUILD/ffmpeg-$VERSION"
  # NUVIO_DTS_HOST=1 builds the identical components for fixture tests.
  if [ "${NUVIO_DTS_HOST:-0}" = 1 ]; then
    set -- --cc="$CC" --disable-x86asm
  else
    set -- --enable-cross-compile --arch=arm --target-os=linux \
      --cross-prefix="${CC%-gcc}-" --cc="$CC" --sysroot="${NUVIO_SYSROOT:?SDK sysroot required}"
  fi
fi
# --enable-muxer must come AFTER --disable-everything and --enable-zlib after
# --disable-autodetect (configure applies them in order). Unquoted on purpose:
# both empty for webOS, so its configure line is unchanged.
"$SRC/configure" "$@" --prefix="$PREFIX" --disable-everything ${MUXERS:+--enable-muxer=$MUXERS} \
  --disable-autodetect $ZLIB --disable-shared --enable-static --enable-pic \
  --disable-programs --disable-doc --disable-debug --disable-network \
  --disable-avdevice --disable-avfilter --disable-swscale --disable-postproc \
  --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
  --enable-decoder="$DECODERS" --enable-encoder=aac,ac3 \
  --enable-demuxer=matroska,mov --enable-parser="$PARSERS" \
  --enable-bsf="$BSFS" \
  --extra-cflags="${CFLAGS:--O2}"
make -j"${NUVIO_DTS_JOBS:-2}"
make install
# Include license text and pin provenance for redistribution of static LGPL libs.
cp "$SRC/COPYING.LGPLv2.1" "$PREFIX/"
printf 'FFmpeg %s\nhttps://ffmpeg.org/releases/ffmpeg-%s.tar.xz\nSHA256 %s\n' "$VERSION" "$VERSION" "$SHA256" > "$PREFIX/SOURCE.txt"
if [ "$TARGET" = tpk ]; then
  # Exact configure line next to the source pin: what a relink needs to rebuild the same libs.
  printf 'configure: ' >> "$PREFIX/SOURCE.txt"
  sed -n 's/^FFMPEG_CONFIGURATION=//p' ffbuild/config.mak >> "$PREFIX/SOURCE.txt"
fi
