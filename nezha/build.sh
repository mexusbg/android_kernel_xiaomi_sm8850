#!/usr/bin/env bash
# nezha-kernel build: GKI 6.12 android16-6, 4k, BakaSU (manual hooks)
#
# Builds a kernel that presents as one stock HyperOS firmware: uname,
# /proc/version and /proc/config.gz byte-identical, KMI CRCs equal so the
# firmware's vendor modules load. Packages an AnyKernel3 zip (boot partition,
# dynamic slot selection, firmware guard).
#
# The firmware is described by a profile, nezha/stock/<fw>/{banner,config},
# made by nezha/fetch-stock.sh. Its .ko files (for the CRC gate) live in
# $STOCK_ROOT/<fw>/modules/.
#
# Usage: [STOCK_FW=<fw>] nezha/build.sh [clean]
#   STOCK_FW    profile name (default: nezha/stock/DEFAULT)
#   STOCK_ROOT  stock module store (default: /mnt/d/MyProjects/nezha-kernel/stock)
#   SKIP_CRC=1  skip the module CRC gate (not recommended)
#   NO_CCACHE=1 build without ccache
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$SRC/out}"
DIST="${DIST:-$SRC/dist}"
TC="${TC:-$HOME/toolchain-k2025}"           # AOSP main-kernel-2025: clang-r536225 (14043575), rust 1.82.0.p2
BINDGEN_DIR="${BINDGEN_DIR:-$HOME/toolchain/bindgen}"
AK3_SRC="${AK3_SRC:-$HOME/AnyKernel3}"
STOCK_ROOT="${STOCK_ROOT:-/mnt/d/MyProjects/nezha-kernel/stock}"
JOBS="${JOBS:-$(nproc)}"
die() { echo "ERROR: $*" >&2; exit 1; }

# ---- stock firmware profile ----
STOCK_FW="${STOCK_FW:-$(cat "$SRC/nezha/stock/DEFAULT")}"
PROFILE="$SRC/nezha/stock/$STOCK_FW"
[ -f "$PROFILE/banner" ] && [ -f "$PROFILE/config" ] || die "no profile $PROFILE (run nezha/fetch-stock.sh)"
STOCK_BANNER="$(head -n1 "$PROFILE/banner")"
STOCK_CONFIG="$PROFILE/config"
re='^Linux version ([^ ]+) \(([^@]+)@([^)]+)\) \(.*\) #([0-9]+) SMP PREEMPT (.+)$'
[[ $STOCK_BANNER =~ $re ]] || die "cannot parse stock banner: $STOCK_BANNER"
STOCK_RELEASE="${BASH_REMATCH[1]}"
export KBUILD_BUILD_USER="${BASH_REMATCH[2]}"
export KBUILD_BUILD_HOST="${BASH_REMATCH[3]}"
export KBUILD_BUILD_VERSION="${BASH_REMATCH[4]}"
export KBUILD_BUILD_TIMESTAMP="${BASH_REMATCH[5]}"
[[ $STOCK_BANNER =~ Android\ \(([0-9]+), ]] || die "no clang build id in stock banner"
STOCK_CLANG_BUILD="${BASH_REMATCH[1]}"
STOCK_LOCALVERSION="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$STOCK_CONFIG")"
KVER="$(make -s -C "$SRC" kernelversion)"
case "$STOCK_RELEASE" in
  "$KVER"-*"$STOCK_LOCALVERSION") ;;
  *) die "stock kernel $STOCK_RELEASE is not $KVER*$STOCK_LOCALVERSION: sync the source to the new sublevel first";;
esac
STOCK_SCM="${STOCK_RELEASE#"$KVER"}"
export KERNEL_SCM_OVERRIDE="${STOCK_SCM%"$STOCK_LOCALVERSION"}"   # scripts/setlocalversion
export IKCONFIG_SOURCE="$STOCK_CONFIG"                            # /proc/config.gz = stock
# KMI symbol CRCs: kleaf runs gendwarfksyms in --stable mode. Without this every
# exported CRC differs from stock and vendor_dlkm/system_dlkm modules refuse to load.
export KBUILD_GENDWARFKSYMS_STABLE=1
echo "firmware: $STOCK_FW -> $STOCK_RELEASE"

# ---- toolchain ----
# pahole: AOSP kernel/prebuilts/build-tools (main-kernel-2025), same tool as stock.
# Upstream pahole 1.25 aborts BTF at 4096 per-CPU vars; the AOSP build does not.
ABT="${AOSP_BUILD_TOOLS:-$HOME/toolchain/aosp-build-tools}"
[ -x "$ABT/bin/pahole" ] || die "missing AOSP pahole in $ABT"
WRAP="$(mktemp -d)"
WORK=""
trap 'rm -rf "$WRAP" ${WORK:+"$WORK"}' EXIT
printf '#!/bin/sh\nLD_LIBRARY_PATH="%s/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "%s/bin/pahole" "$@"\n' "$ABT" "$ABT" > "$WRAP/pahole"
chmod +x "$WRAP/pahole"
export PATH="$WRAP:$TC/clang/bin:$TC/rust/bin:$BINDGEN_DIR:$PATH"
# Pin bindgen's libclang to the clang prebuilt. clang-sys (inside bindgen)
# otherwise auto-discovers a system libclang (e.g. on CI runners), and a
# mismatched libclang mis-parses task_struct into an opaque type -> the Rust
# kernel crate fails with "no field ... on type bindings::task_struct".
export LIBCLANG_PATH="${LIBCLANG_PATH:-$TC/clang/lib}"
# host libdw/libelf with zstd support (see nezha/build-elfutils.sh)
EU="${ELFUTILS_PREFIX:-$HOME/toolchain/elfutils}"
[ -f "$EU/include/elfutils/libdw.h" ] || die "run nezha/build-elfutils.sh first"

for t in clang ld.lld rustc bindgen flex bison; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
clang --version | head -n1 | grep -q "Android ($STOCK_CLANG_BUILD," \
  || die "clang is not build $STOCK_CLANG_BUILD (stock): $(clang --version | head -n1)"
[ -f "$SRC/KernelSU/kernel/Kconfig" ] || die "KernelSU missing at $SRC/KernelSU"

MAKE_ARGS=(-C "$SRC" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
           CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS"
           HOSTCFLAGS="-I$EU/include"
           HOSTLDFLAGS="-L$EU/lib -Wl,-rpath,$EU/lib")
if [ -z "${NO_CCACHE:-}" ] && command -v ccache >/dev/null; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/nezha-ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
  export CCACHE_BASEDIR="$SRC"
  MAKE_ARGS+=(CC="ccache clang")
  ccache -z >/dev/null
fi

[ "${1:-}" = clean ] && rm -rf "$OUT"

# ---- config: gki_defconfig, LTO off like stock ----
make "${MAKE_ARGS[@]}" gki_defconfig
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str LOCALVERSION "$STOCK_LOCALVERSION" -e LOCALVERSION_AUTO \
  -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL \
  -e HMA_UIDFAKE
make "${MAKE_ARGS[@]}" olddefconfig

# ---- build ----
rm -f "$OUT/vmlinux.symvers"
make "${MAKE_ARGS[@]}" Image
IMAGE="$OUT/arch/arm64/boot/Image"
[ -n "${CCACHE_DIR:-}" ] && ccache -s | grep -iE '^ *(hits|misses|cache hit|cache miss)' || true

# ---- gates: the kernel must present as $STOCK_FW ----
REL="$(cat "$OUT/include/config/kernel.release")"
echo "kernel.release: $REL"
[ "$REL" = "$STOCK_RELEASE" ] || die "release mismatch (want $STOCK_RELEASE)"
# read banner from the Image itself (no pipe: avoids SIGPIPE under pipefail)
BANNER="$(grep -a -o -m1 'Linux version [[:print:]]*' "$IMAGE")"
BANNER="${BANNER%"${BANNER##*[![:space:]]}"}"
if printf '%s' "$BANNER" | grep -qiE "kokuban|baka|ksu|kernelsu"; then
  die "root keyword in banner: $BANNER"
fi
if [ "$BANNER" != "$STOCK_BANNER" ]; then
  diff <(printf '%s\n' "$STOCK_BANNER") <(printf '%s\n' "$BANNER") >&2 || true
  die "banner differs from stock /proc/version"
fi
echo "banner: identical to $STOCK_FW"
"$SRC/scripts/extract-ikconfig" "$IMAGE" | cmp -s - "$STOCK_CONFIG" \
  || die "/proc/config.gz payload differs from stock config"
echo "config.gz: identical to $STOCK_FW"

MODS="$STOCK_ROOT/$STOCK_FW/modules"
if [ -n "${SKIP_CRC:-}" ]; then
  echo "WARNING: module CRC gate skipped (SKIP_CRC)" >&2
else
  [ -f "$OUT/vmlinux.symvers" ] || die "no vmlinux.symvers from this build"
  [ -d "$MODS" ] || die "no stock modules in $MODS (run nezha/fetch-stock.sh, or SKIP_CRC=1)"
  # rust_binder.ko: Rust crate-hash ABI can't match a non-stock build; it is
  # dormant (builtin C binder serves /dev/binder), so it may fail.
  if ! python3 -I "$SRC/nezha/check-module-crcs.py" --allow rust_binder.ko \
       "$OUT/vmlinux.symvers" "$MODS"/*/ > "$OUT/crc-report.txt"; then
    tail -n 30 "$OUT/crc-report.txt" >&2
    die "stock modules would not load (full report: $OUT/crc-report.txt)"
  fi
  grep -E '^(modules scanned|modules OK|RESULT)' "$OUT/crc-report.txt"
fi

# ---- package AnyKernel3 ----
COMMIT="$(git -C "$SRC" rev-parse --short=8 HEAD)"
STAMP="$(date +%Y%m%d-%H%M)"
WORK="$(mktemp -d)"
rsync -a --exclude .git --exclude .github --exclude README.md \
  --exclude ramdisk --exclude patch --exclude modules "$AK3_SRC/" "$WORK/"
cp "$SRC/nezha/anykernel/anykernel.sh" "$WORK/anykernel.sh"
# Name it Image-dtb (not Image): ak3-core's flash_boot then drops the stock
# appended kernel_dtb (case *-dtb) instead of re-appending it, so the repacked
# boot is our Image only. This device gets its DTB from dtbo and boots with none
# appended inside boot (proven). Our Image carries no appended DTB itself.
cp "$IMAGE" "$WORK/Image-dtb"
# nezha (sm8850, ARMv9) is 64-bit-only: AArch32 is gone. A 32-bit ARM busybox
# or magiskboot can't exec on-device and the AK3 installer dies ("Busybox setup
# failed" / magiskboot "syntax error"). Refuse to ship a zip with 32-bit tools.
for t in busybox magiskboot; do
  [ -f "$WORK/tools/$t" ] || die "AK3 tools/$t missing in $AK3_SRC"
  file -b "$WORK/tools/$t" | grep -q "ARM aarch64" \
    || die "AK3 tools/$t is not aarch64 (device is 64-bit-only); put an arm64 build in $AK3_SRC/tools"
done
printf '%s\n' "$STOCK_RELEASE" > "$WORK/nezha-stock-release"   # firmware guard
mkdir -p "$DIST"
ZIP="$DIST/nezha-kernel-$COMMIT-$STAMP.zip"   # generic name; stock identity is inside (nezha-stock-release + config.gz), not the filename
(cd "$WORK" && zip -qr9 "$ZIP" . -x '.*')
echo "OK: $ZIP"
