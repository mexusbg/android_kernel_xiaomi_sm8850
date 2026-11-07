# nezha-kernel — Xiaomi 17 (nezha / sm8850), GKI 6.12

A custom **GKI 6.12 `android16-6` (4k pages)** kernel for the Xiaomi 17 (codename
**nezha**, SoC **sm8850**), built to present as **one specific stock HyperOS
firmware** while shipping a built-in root + hiding stack.

The point of the build is *indistinguishability*: `uname -r`, `/proc/version`
and `/proc/config.gz` are **byte-identical to stock**, and the exported KMI
symbol CRCs match stock so the firmware's own vendor modules load unchanged.

## Target firmware

`6.12.69-android16-6-g0a1dc0413ec7-ab16271006-4k` — HyperOS `OS4.0.1.0.XPAEUXM`.

The stock identity is described by a profile under `nezha/stock/<fw>/`
(`banner`, `config`); the build fails closed if the result doesn't match it.

## What's in it

- **Stock-identical identity.** Banner / `/proc/version` / `/proc/config.gz`
  match stock byte-for-byte (the AOSP `main-kernel-2025` toolchain, clang
  `r536225`, reproduces the stock banner exactly; `/proc/config.gz` is sourced
  from the stock config, so it never leaks build-only options).
- **KMI-matched.** `gendwarfksyms --stable` keeps every exported CRC equal to
  stock, so `vendor_dlkm` / `system_dlkm` modules load (wifi/modem/audio intact).
- **BakaSU** (KernelSU-family root with manual hooks).
- **selinux_hide**, one-pass policy parsing (KernelSU PR
  [#3936](https://github.com/tiann/KernelSU/pull/3936)) plus an app-zygote
  `attr/current` timing-side-channel reduction, so SELinux-oracle detectors stop
  flagging the backup-policy parse.
- **hma-uidfake, built in** (`CONFIG_HMA_UIDFAKE`): a kernel-side UID-existence
  guard (getpriority / ioprio / setuid tagging). No module artifact, no ABI
  profile matching — it loads at boot and is a pass-through no-op until fed a
  policy. Rules come from the helper module below.

Result: current detector suites come back clean and Play Integrity returns
**MEETS_STRONG_INTEGRITY** on the stock fingerprint.

## Helper module

The built-in `hma-uidfake` hook needs a small userspace feeder to push the
hidden-UID list (from HMA-OSS) over its netlink family:

➡️ **[mexusbg/hma-uidfake-feeder](https://github.com/mexusbg/hma-uidfake-feeder)**

Flash it alongside the kernel; it starts `sync-tool` at boot. No `.ko`, no
per-kernel rebuild.

## Building

```sh
# prerequisites: AOSP main-kernel-2025 toolchain in ~/toolchain-k2025,
# AOSP build-tools pahole, host elfutils with zstd, AnyKernel3 (arm64 tools).
# KernelSU checked out next to the tree (drivers/kernelsu -> ../KernelSU/kernel).
nezha/build.sh            # -> dist/nezha-kernel-<shortsha>-<date>.zip
```

The build runs fatal gates: banner, `/proc/config.gz` payload, clang build id,
and a per-module CRC check against the stock `.ko` set (kept out of this repo).
See `nezha/build.sh` for the full pipeline and `nezha/fetch-stock.sh` for making
a firmware profile from a stock kernel image.

## Flashing

An AnyKernel3 zip that patches the `boot` partition (GKI; the ramdisk lives in
`init_boot` and is left alone). It selects the slot that will boot next, drops
the stock appended DTB (the device takes its DTB from `dtbo`), and carries a
firmware guard that refuses a slot holding a different stock kernel. Flash with
Kernel Flasher or the BakaSU manager's AnyKernel3 tab.

## Credits

- [YuzakiKokuban/android_kernel_xiaomi_sm8850](https://github.com/YuzakiKokuban/android_kernel_xiaomi_sm8850) — base tree
- [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) and [tiann/KernelSU](https://github.com/tiann/KernelSU) — root + selinux_hide
- [Mobilelegends74/hma-uidfake](https://github.com/Mobilelegends74/hma-uidfake) — uidfake hook source
- SukiSU-Ultra — upstream fixes

## License

GPL-2.0, matching the Linux kernel and the components above.
