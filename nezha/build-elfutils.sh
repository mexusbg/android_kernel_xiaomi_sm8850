#!/usr/bin/env bash
# Build elfutils >= 0.189 (zstd-compressed DWARF support) for kernel host tools.
# Ubuntu 22.04 ships 0.186, which makes scripts/gendwarfksyms fail on objects built
# with CONFIG_DEBUG_INFO_COMPRESSED_ZSTD=y (stock GKI setting).
# Requires: libzstd-dev, zlib1g-dev
set -euo pipefail
VER="${ELFUTILS_VER:-0.191}"
SRCDIR="${SRCDIR:-$HOME/toolchain/src}"
PREFIX="${ELFUTILS_PREFIX:-$HOME/toolchain/elfutils}"

[ -e /usr/include/zstd.h ] || { echo "missing libzstd-dev (zstd.h)" >&2; exit 1; }
mkdir -p "$SRCDIR"; cd "$SRCDIR"
[ -f "elfutils-$VER.tar.bz2" ] || curl -fsSLO "https://sourceware.org/elfutils/ftp/$VER/elfutils-$VER.tar.bz2"
rm -rf "elfutils-$VER"; tar -xjf "elfutils-$VER.tar.bz2"
cd "elfutils-$VER"
./configure --prefix="$PREFIX" --with-zstd --disable-werror \
  --disable-debuginfod --disable-libdebuginfod --disable-nls --program-prefix=eu-
make -j"$(nproc)"
make install
grep -q "define USE_ZSTD 1" config.h || { echo "elfutils built without zstd" >&2; exit 1; }
echo "elfutils $VER installed to $PREFIX (zstd enabled)"
