#!/usr/bin/env bash
# nezha-kernel build: GKI 6.12 android16-6, 4k, BakaSU (manual hooks)
# Produces a kernel whose uname / /proc/version match stock HyperOS byte-for-byte,
# packaged as an AnyKernel3 zip (boot partition, dynamic slot selection).
#
# Usage: nezha/build.sh [clean]
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$SRC/out}"
DIST="${DIST:-$SRC/dist}"
TC="${TC:-$HOME/toolchain-k2025}"           # AOSP main-kernel-2025: clang-r536225 (14043575), rust 1.82.0.p2
BINDGEN_DIR="${BINDGEN_DIR:-$HOME/toolchain/bindgen}"
AK3_SRC="${AK3_SRC:-$HOME/AnyKernel3}"
JOBS="${JOBS:-$(nproc)}"

# ---- stock identity (from running stock kernel, HyperOS OS4.0.1.0 nezha_eea) ----
STOCK_SCM="-android16-6-g0a1dc0413ec7-ab16271006"   # placed before CONFIG_LOCALVERSION (-4k)
export KERNEL_SCM_OVERRIDE="$STOCK_SCM"
export KBUILD_BUILD_USER=kleaf
export KBUILD_BUILD_HOST=build-host
export KBUILD_BUILD_TIMESTAMP="Sat Sep  5 12:19:39 UTC 2026"
export KBUILD_BUILD_VERSION=1
# KMI symbol CRCs: kleaf runs gendwarfksyms in --stable mode. Without this every
# exported CRC differs from stock and vendor_dlkm/system_dlkm modules refuse to load.
export KBUILD_GENDWARFKSYMS_STABLE=1
STOCK_RELEASE="6.12.69-android16-6-g0a1dc0413ec7-ab16271006-4k"
STOCK_BANNER="Linux version 6.12.69-android16-6-g0a1dc0413ec7-ab16271006-4k (kleaf@build-host) (Android (14043575, +pgo, +bolt, +lto, +mlgo, based on r536225) clang version 19.0.1 (https://android.googlesource.com/toolchain/llvm-project b3a530ec6537146650e42be89f1089e9a3588460), LLD 19.0.1) #1 SMP PREEMPT Sat Sep  5 12:19:39 UTC 2026"

# ---- toolchain ----
# pahole: AOSP kernel/prebuilts/build-tools (main-kernel-2025), same tool as stock.
# Upstream pahole 1.25 aborts BTF at 4096 per-CPU vars; the AOSP build does not.
ABT="${AOSP_BUILD_TOOLS:-$HOME/toolchain/aosp-build-tools}"
[ -x "$ABT/bin/pahole" ] || { echo "missing AOSP pahole in $ABT" >&2; exit 1; }
WRAP="$(mktemp -d)"
printf '#!/bin/sh\nLD_LIBRARY_PATH="%s/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "%s/bin/pahole" "$@"\n' "$ABT" "$ABT" > "$WRAP/pahole"
chmod +x "$WRAP/pahole"
export PATH="$WRAP:$TC/clang/bin:$TC/rust/bin:$BINDGEN_DIR:$PATH"
# host libdw/libelf with zstd support (see nezha/build-elfutils.sh)
EU="${ELFUTILS_PREFIX:-$HOME/toolchain/elfutils}"
[ -f "$EU/include/elfutils/libdw.h" ] || { echo "run nezha/build-elfutils.sh first" >&2; exit 1; }
MAKE_ARGS=(-C "$SRC" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
           CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS"
           HOSTCFLAGS="-I$EU/include"
           HOSTLDFLAGS="-L$EU/lib -Wl,-rpath,$EU/lib")

for t in clang ld.lld rustc bindgen flex bison; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
[ -f "$SRC/KernelSU/kernel/Kconfig" ] || { echo "KernelSU missing at $SRC/KernelSU" >&2; exit 1; }

[ "${1:-}" = clean ] && rm -rf "$OUT"

# ---- config: gki_defconfig, LTO off like stock ----
make "${MAKE_ARGS[@]}" gki_defconfig
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str LOCALVERSION "-4k" -e LOCALVERSION_AUTO \
  -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL
make "${MAKE_ARGS[@]}" olddefconfig

# ---- build ----
make "${MAKE_ARGS[@]}" Image

# ---- verify identity ----
REL="$(cat "$OUT/include/config/kernel.release")"
echo "kernel.release: $REL"
if [ "$REL" != "$STOCK_RELEASE" ]; then
  echo "ERROR: release mismatch (want $STOCK_RELEASE)" >&2; exit 1
fi
# read banner from the flashed Image itself (no pipe: avoids SIGPIPE under pipefail)
BANNER="$(grep -a -o -m1 'Linux version [[:print:]]*' "$OUT/arch/arm64/boot/Image")"
BANNER="${BANNER%"${BANNER##*[![:space:]]}"}"
echo "banner: $BANNER"
if printf '%s' "$BANNER" | grep -qiE "kokuban|baka|ksu|kernelsu"; then
  echo "ERROR: root keyword in banner" >&2; exit 1
fi
if [ "$BANNER" != "$STOCK_BANNER" ]; then
  echo "WARNING: banner differs from stock /proc/version" >&2
  diff <(printf '%s\n' "$STOCK_BANNER") <(printf '%s\n' "$BANNER") >&2 || true
fi

# ---- package AnyKernel3 ----
COMMIT="$(git -C "$SRC" rev-parse --short=8 HEAD)"
STAMP="$(date +%Y%m%d-%H%M)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WRAP"' EXIT
rsync -a --exclude .git --exclude .github --exclude README.md \
  --exclude ramdisk --exclude patch --exclude modules "$AK3_SRC/" "$WORK/"
cp "$SRC/nezha/anykernel/anykernel.sh" "$WORK/anykernel.sh"
cp "$OUT/arch/arm64/boot/Image" "$WORK/Image"
mkdir -p "$DIST"
ZIP="$DIST/nezha-kernel-$COMMIT-$STAMP.zip"
(cd "$WORK" && zip -qr9 "$ZIP" . -x '.*')
echo "OK: $ZIP"
