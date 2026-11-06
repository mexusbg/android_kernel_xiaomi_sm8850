### AnyKernel3 Ramdisk Mod Script
## nezha-kernel (Xiaomi 17 / sm8850, GKI 6.12 android16-6, 4k)

### AnyKernel setup
# global properties
properties() { '
kernel.string=nezha-kernel
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=nezha
device.name2=popsicle
device.name3=pandora
device.name4=pudding
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### Target slot selection
# Always flash the slot that will boot NEXT:
#   - first install / normal update: next boot = running slot  -> active
#   - OTA installed, not rebooted yet: update_engine has already marked the
#     other slot active for next boot                          -> inactive
#   - flashed as OTA postinstall (/postinstall/tmp)            -> inactive (AK3 core)
# Manual override: put "-active" or "-inactive" in the zip file name.
# (A firmware guard further down refuses a mismatched stock kernel.)
nezha_slot_reason="";
case "$(basename "$ZIPFILE" .zip)" in
  *-inactive*) SLOT_SELECT=inactive; nezha_slot_reason="forced by zip name";;
  *-active*)   SLOT_SELECT=active;   nezha_slot_reason="forced by zip name";;
esac;

if [ ! "$SLOT_SELECT" -a ! -d /postinstall/tmp ]; then
  nezha_cur=$(getprop ro.boot.slot_suffix 2>/dev/null);
  nezha_next="";
  # 1) boot control HAL: which slot is marked active for next boot
  if command -v bootctl >/dev/null 2>&1; then
    case "$(bootctl get-active-boot-slot 2>/dev/null)" in
      0) nezha_next=_a;;
      1) nezha_next=_b;;
    esac;
  fi;
  if [ "$nezha_cur" -a "$nezha_next" ]; then
    if [ "$nezha_next" != "$nezha_cur" ]; then
      SLOT_SELECT=inactive; nezha_slot_reason="pending OTA: next boot slot $nezha_next (running $nezha_cur)";
    else
      SLOT_SELECT=active; nezha_slot_reason="no pending OTA: next boot slot = running $nezha_cur";
    fi;
  # 2) fallback: update_engine status
  elif command -v update_engine_client >/dev/null 2>&1 \
       && update_engine_client --status 2>&1 | grep -q UPDATED_NEED_REBOOT; then
    SLOT_SELECT=inactive; nezha_slot_reason="update_engine: UPDATED_NEED_REBOOT";
  else
    SLOT_SELECT=active; nezha_slot_reason="no OTA signal found (default)";
  fi;
fi;
[ "$nezha_slot_reason" ] || nezha_slot_reason="OTA postinstall environment";


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables (GKI kernel lives in boot; ramdisk is in init_boot, untouched)
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

ui_print " " "Target slot: ${SLOT:-?} (${SLOT_SELECT:-active})" "Reason: $nezha_slot_reason" " ";

# boot install
split_boot; # kernel only, no ramdisk unpack

### Drop stock's appended DTB
# This device gets its DTB from dtbo/vendor_boot; the running kernel boots with
# no DTB appended inside boot. magiskboot splits stock's appended DTB out to
# split_img/kernel_dtb and would re-append it on repack, making the boot ~20MB
# larger and structurally unlike the proven image. Remove it so the repacked
# boot is our Image only (kernel_sz matches what boots now).
[ -f "$SPLITIMG/kernel_dtb" ] && { ui_print "Dropping stock appended DTB (device uses dtbo)"; rm -f "$SPLITIMG/kernel_dtb"; }

### Firmware guard
# This kernel matches ONE stock kernel (KMI + identity), recorded at build
# time in nezha-stock-release. OTAs normally keep the same stock kernel, so
# this passes silently. It only blocks when the target slot holds a stock
# kernel of another sublevel or KMI generation (e.g. 6.12.69-android16-6 ->
# 6.12.80-android16-6): its vendor modules may need symbols this build lacks
# (no wifi/modem, or no boot). Same sublevel + KMI generation with another
# build number only warns: the KMI is frozen and this build exports the full
# symbol set. A non-stock kernel in the slot can't tell us the firmware, so
# only warn. Override: "-force" in the zip name.
nezha_want=$(cat $AKHOME/nezha-stock-release 2>/dev/null);
nezha_have=$(strings $SPLITIMG/kernel 2>/dev/null | grep -m1 '^Linux version ' | cut -d' ' -f3);
nezha_wkmi=$(echo "$nezha_want" | cut -d- -f1-3); # 6.12.69-android16-6
case "$(basename "$ZIPFILE" .zip)" in *-force*) nezha_force=1;; esac;
if [ ! "$nezha_want" -o ! "$nezha_have" ]; then
  ui_print "Firmware guard: cannot read kernel versions, skipped";
elif [ "$nezha_have" = "$nezha_want" ]; then
  ui_print "Firmware guard: OK ($nezha_have)";
else
  case "$nezha_have" in
    "$nezha_wkmi"-g*-ab*)
      ui_print "Firmware guard: stock build changed, same KMI ($nezha_wkmi)" \
        "  was $nezha_want" "  now $nezha_have" "  flashing (KMI frozen)";;
    *-android*-g*-ab*)
      if [ "$nezha_force" ]; then
        ui_print "Firmware guard: MISMATCH, forced by zip name";
      else
        abort "Firmware mismatch - nothing flashed." \
          "Slot $SLOT stock kernel: $nezha_have" \
          "This zip is built for:  $nezha_want" \
          "Rebuild for the new firmware (nezha/fetch-stock.sh)," \
          "or add -force to the zip name.";
      fi;;
    *) ui_print "Firmware guard: slot has custom kernel ($nezha_have)" \
         "  cannot verify firmware; this zip is for $nezha_want";;
  esac;
fi;

flash_boot; # kernel only, no ramdisk repack
## end boot install
