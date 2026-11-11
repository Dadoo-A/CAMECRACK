#!/bin/bash
# CAMECRACK: rebuild the toolkit's ptzctl as a SMALL static binary (musl, -Os, LTO) for the
# Anyka AK3918EV330 (ARM926EJ-S, ARMv5TE, soft-float EABI), so PTZ can live in the 256 KB
# flash (no SD). The toolkit's own build is static glibc = ~600 KB.
#
#   docker run --rm -v <this dir>:/recipe:ro -v <toolkit>/ptzlib:/src:ro -v <out>:/out \
#     debian:bookworm bash /recipe/build-ptzctl.sh
# Output: /out/ptzctl (stripped), /out/ptzctl.xz (flash), /out/SHA256SUMS
set -euo pipefail

MUSL_VER=1.2.5
CROSS=arm-linux-gnueabi-
ARCHFLAGS="-march=armv5te -mtune=arm926ej-s -marm -mfloat-abi=soft"
# Same xz constraints as the AP bundle: small explicit dictionary, crc32, NO BCJ filter
# (the camera's busybox xzcat is xz-embedded with 32 MB of RAM).
XZ="xz --check=crc32 --lzma2=preset=9e,dict=256KiB"
OPT="-Os -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi linux-libc-dev-armel-cross make curl ca-certificates xz-utils file >/dev/null

W=/build; rm -rf $W; mkdir -p $W; cd $W
curl -sSfL https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz | tar xz
( cd musl-$MUSL_VER
  CC=${CROSS}gcc CFLAGS="$ARCHFLAGS -Os" ./configure --target=arm-linux-gnueabi \
     --prefix=/opt/musl --disable-shared --enable-wrapper=gcc >/dev/null
  make -j"$(nproc)" >/dev/null && make install >/dev/null )
KH=/usr/arm-linux-gnueabi/include
cp -r $KH/linux $KH/asm $KH/asm-generic /opt/musl/include/
MCC="/opt/musl/bin/musl-gcc"
export REALGCC=${CROSS}gcc
echo "musl OK: $($MCC -dumpmachine)"

$MCC $ARCHFLAGS $OPT -flto -static -D_GNU_SOURCE -I/src/src -Wl,--gc-sections \
  -o /out/ptzctl /src/src/*.c -lpthread
cp /out/ptzctl /out/ptzctl.unstripped
${CROSS}strip --strip-all -R .comment -R .note /out/ptzctl
$XZ -k -f /out/ptzctl

cd /out
file ptzctl
ls -l ptzctl ptzctl.xz
sha256sum ptzctl ptzctl.xz > SHA256SUMS
