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

flash_boot; # kernel only, no ramdisk repack
## end boot install
