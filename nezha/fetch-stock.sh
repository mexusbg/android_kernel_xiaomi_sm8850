#!/usr/bin/env bash
# Capture a stock firmware profile for nezha/build.sh.
#
#   nezha/stock/<name>/banner   stock /proc/version line   (committed)
#   nezha/stock/<name>/config   stock /proc/config.gz text (committed)
#   nezha/stock/DEFAULT         profile build.sh uses when STOCK_FW is unset
#   $STOCK_ROOT/<name>/modules/ vendor .ko files for the CRC gate
#                               (vendor blobs: kept OUT of the repo)
#
# Everything is read from the stock kernel image itself, never from the running
# kernel (which may be ours). A slot that already holds a KernelSU kernel is
# refused.
#
# Device mode (adb + root):
#   nezha/fetch-stock.sh <name> [--slot _a|_b] [--running-dlkm]
#     Reads boot/vendor_boot of --slot (default: running slot) from the block
#     device. After an OTA, before rebooting, use the pending slot: its
#     boot/vendor_boot are already written. vendor_dlkm/system_dlkm modules are
#     taken from the RUNNING system, so they are only fetched when --slot is the
#     running slot, or with --running-dlkm when both slots hold the same firmware.
#   ADB_SERIAL=<serial> selects the device.
#
# Image mode (e.g. images extracted from an OTA payload):
#   nezha/fetch-stock.sh <name> --boot boot.img --vendor-boot vendor_boot.img
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
STOCK_ROOT="${STOCK_ROOT:-/mnt/d/MyProjects/nezha-kernel/stock}"

die() { echo "ERROR: $*" >&2; exit 1; }
[ $# -ge 1 ] && [[ $1 != -* ]] || die "usage: $0 <name> [--slot _a|_b] [--running-dlkm] | [--boot IMG --vendor-boot IMG]"
NAME="$1"; shift
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "bad profile name: $NAME"
SLOT="" BOOT_IMG="" VBOOT_IMG="" RUNNING_DLKM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) SLOT="$2"; shift 2;;
    --boot) BOOT_IMG="$2"; shift 2;;
    --vendor-boot) VBOOT_IMG="$2"; shift 2;;
    --running-dlkm) RUNNING_DLKM=1; shift;;
    *) die "unknown option $1";;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dlkm"

if [ -n "$BOOT_IMG" ]; then
  [ -n "$VBOOT_IMG" ] || die "--boot needs --vendor-boot"
  cp "$BOOT_IMG" "$TMP/boot.img"
  cp "$VBOOT_IMG" "$TMP/vendor_boot.img"
else
  ADB="${ADB:-$(command -v adb || command -v adb.exe || true)}"
  [ -n "$ADB" ] || die "adb not found (set ADB=)"
  A=("$ADB"); [ -n "${ADB_SERIAL:-}" ] && A+=(-s "$ADB_SERIAL")
  "${A[@]}" get-state >/dev/null || die "no device"
  sh_() { "${A[@]}" shell "$1" | tr -d '\r'; }
  su_out() { "${A[@]}" exec-out "su -c '$1'"; }
  sh_ 'su -c id' | grep -q 'uid=0' || die "no root over adb: grant Shell root in the KernelSU manager"
  CUR="$(sh_ 'getprop ro.boot.slot_suffix')"
  SLOT="${SLOT:-$CUR}"
  [[ $SLOT == _a || $SLOT == _b ]] || die "bad slot: $SLOT"
  echo "device: running slot $CUR, reading slot $SLOT ($(sh_ 'getprop ro.build.version.incremental') running)"
  for p in boot vendor_boot; do
    su_out "dd if=/dev/block/by-name/$p$SLOT bs=1048576 2>/dev/null" > "$TMP/$p.img"
    echo "  $p$SLOT: $(stat -c%s "$TMP/$p.img") bytes"
  done
  if [ "$SLOT" = "$CUR" ] || [ -n "$RUNNING_DLKM" ]; then
    su_out "tar -cf - -C / vendor_dlkm/lib/modules system_dlkm/lib/modules 2>/dev/null" | tar -x -C "$TMP/dlkm"
  else
    echo "  NOTE: slot $SLOT is not running: vendor_dlkm/system_dlkm modules not fetched"
    echo "        (pending OTA dlkm partitions are unreadable until reboot; re-run then)"
  fi
fi

# ---- identity from the stock kernel image ----
python3 -I "$SRC/nezha/boot-kernel.py" "$TMP/boot.img" "$TMP/kernel" >/dev/null
BANNER="$(grep -a -o -m1 'Linux version [[:print:]]*' "$TMP/kernel")" || die "no banner in kernel"
BANNER="${BANNER%"${BANNER##*[![:space:]]}"}"
"$SRC/scripts/extract-ikconfig" "$TMP/kernel" > "$TMP/config" || die "no IKCONFIG in kernel"
if grep -qE '^CONFIG_KSU=y' "$TMP/config"; then
  die "that slot holds a KernelSU kernel, not stock (use the other slot or stock images)"
fi

# ---- first-stage modules from vendor_boot ramdisk ----
python3 -I "$SRC/nezha/extract-vendor-ramdisk.py" "$TMP/vendor_boot.img" "$TMP/ramdisk" >/dev/null
case "$(head -c4 "$TMP/ramdisk" | od -An -tx1 | tr -d ' ')" in
  02214c18) lz4 -dc "$TMP/ramdisk" > "$TMP/ramdisk.cpio";;
  1f8b*)    gzip -dc "$TMP/ramdisk" > "$TMP/ramdisk.cpio";;
  *)        cp "$TMP/ramdisk" "$TMP/ramdisk.cpio";;
esac
mkdir -p "$TMP/vb"
(cd "$TMP/vb" && cpio -idm --quiet < "$TMP/ramdisk.cpio") || die "vendor ramdisk unpack failed"

# ---- write profile + modules ----
P="$SRC/nezha/stock/$NAME"
M="$STOCK_ROOT/$NAME/modules"
mkdir -p "$P"
printf '%s\n' "$BANNER" > "$P/banner"
cp "$TMP/config" "$P/config"
echo "$NAME" > "$SRC/nezha/stock/DEFAULT"

rm -rf "$M/vendor_boot"; mkdir -p "$M/vendor_boot"
find "$TMP/vb" -name '*.ko' -exec cp {} "$M/vendor_boot/" \;
for d in vendor_dlkm system_dlkm; do
  if [ -d "$TMP/dlkm/$d/lib/modules" ]; then
    rm -rf "${M:?}/$d"; mkdir -p "$M/$d"
    find "$TMP/dlkm/$d/lib/modules" -name '*.ko' -exec cp {} "$M/$d/" \;
  fi
done

echo
echo "profile : $P"
echo "release : $(echo "$BANNER" | cut -d' ' -f3)"
echo "clang   : $(echo "$BANNER" | grep -o 'Android ([0-9]*' | tr -d '(')"
for d in vendor_boot vendor_dlkm system_dlkm; do
  printf 'modules : %-12s %s\n' "$d" "$(find "$M/$d" -name '*.ko' 2>/dev/null | wc -l)"
done
echo "next    : nezha/build.sh   (STOCK_FW=$NAME is now the default)"
