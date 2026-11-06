#!/usr/bin/env python3
"""Check stock .ko modules against a built kernel's vmlinux.symvers.

For every imported symbol a module records a CRC (modversions). The module
only loads if the running kernel exports that symbol with the same CRC.
Symbols exported by other modules (not vmlinux) are resolved from the
modules themselves and skipped here.

Reads both formats:
  - classic  __versions          : struct { unsigned long crc; char name[56]; }
  - extended __version_ext_crcs  : u32[]  + __version_ext_names: NUL-separated names

Usage: check-module-crcs.py [--allow mod.ko]... <vmlinux.symvers> <dir-with-ko> [more dirs...]

--allow: module (file name) whose failures are reported but do not fail the
         exit status, e.g. rust_binder.ko (Rust ABI can't match a stock build).
"""
import os
import struct
import sys


def elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise ValueError("not ELF64")
    end = "<" if data[5] == 1 else ">"
    shoff, = struct.unpack_from(end + "Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from(end + "HHH", data, 0x3A)
    hdrs = []
    for i in range(shnum):
        name, _typ, _flags, _addr, off, size = struct.unpack_from(
            end + "IIQQQQ", data, shoff + i * shentsize)
        hdrs.append((name, off, size))
    _, stroff, strsize = hdrs[shstrndx]
    strtab = data[stroff:stroff + strsize]
    out = {}
    for name, off, size in hdrs:
        n = strtab[name:strtab.index(b"\0", name)].decode()
        out[n] = data[off:off + size]
    return out, end


def module_imports(path):
    with open(path, "rb") as f:
        data = f.read()
    secs, end = elf_sections(data)
    imports = {}
    v = secs.get("__versions", b"")
    for i in range(0, len(v) - 63, 64):
        crc, = struct.unpack_from(end + "Q", v, i)
        name = v[i + 8:i + 64].split(b"\0", 1)[0].decode()
        if name:
            imports[name] = crc & 0xFFFFFFFF
    crcs = secs.get("__version_ext_crcs", b"")
    names = secs.get("__version_ext_names", b"")
    if crcs:
        nlist = [n.decode() for n in names.split(b"\0") if n]
        for idx, name in enumerate(nlist):
            crc, = struct.unpack_from(end + "I", crcs, idx * 4)
            imports[name] = crc
    modname = os.path.basename(path)
    return modname, imports


def module_exports(path):
    """Names a module exports (so other modules' imports of them are not vmlinux's job)."""
    with open(path, "rb") as f:
        data = f.read()
    secs, _ = elf_sections(data)
    names = set()
    for key in ("__ksymtab_strings",):
        names.update(n.decode() for n in secs.get(key, b"").split(b"\0") if n)
    return names


def main():
    args = sys.argv[1:]
    allowed = set()
    while len(args) >= 2 and args[0] == "--allow":
        allowed.add(args[1])
        args = args[2:]
    if len(args) < 2:
        sys.exit(__doc__)
    kernel = {}
    with open(args[0]) as f:
        for line in f:
            p = line.split("\t")
            if len(p) >= 2:
                kernel[p[1]] = int(p[0], 16)

    kos = []
    for d in args[1:]:
        for root, _, files in os.walk(d):
            kos += [os.path.join(root, x) for x in files if x.endswith(".ko")]
    if not kos:
        sys.exit("no .ko files found")

    mod_exported = set()
    for ko in kos:
        try:
            mod_exported |= module_exports(ko)
        except ValueError:
            pass

    bad_mods, missing_mods, ok = {}, {}, 0
    checked_syms = 0
    for ko in sorted(kos):
        try:
            name, imports = module_imports(ko)
        except ValueError as e:
            print(f"SKIP {ko}: {e}")
            continue
        mismatch, missing = [], []
        for sym, crc in imports.items():
            if sym == "module_layout":
                continue
            if sym in kernel:
                checked_syms += 1
                if kernel[sym] != crc:
                    mismatch.append((sym, crc, kernel[sym]))
            elif sym not in mod_exported:
                missing.append(sym)
        if mismatch:
            bad_mods[name] = mismatch
        if missing:
            missing_mods[name] = missing
        if not mismatch and not missing:
            ok += 1

    print(f"modules scanned : {len(kos)}")
    print(f"vmlinux imports checked: {checked_syms}")
    print(f"modules OK      : {ok}")
    print(f"CRC mismatches  : {len(bad_mods)} modules")
    print(f"missing exports : {len(missing_mods)} modules")
    all_bad = {}
    for m, lst in bad_mods.items():
        for sym, want, have in lst:
            all_bad.setdefault(sym, (want, have, []))[2].append(m)
    if all_bad:
        print("\n== CRC mismatches by symbol (stock_crc -> ours) ==")
        for sym, (want, have, mods) in sorted(all_bad.items(), key=lambda x: -len(x[1][2])):
            print(f"  {sym}: 0x{want:08x} -> 0x{have:08x}  ({len(mods)} modules: {', '.join(mods[:5])}{' ...' if len(mods) > 5 else ''})")
    if missing_mods:
        print("\n== symbols not exported by our kernel (nor by any scanned module) ==")
        allm = {}
        for m, syms in missing_mods.items():
            for s in syms:
                allm.setdefault(s, []).append(m)
        for s, mods in sorted(allm.items(), key=lambda x: -len(x[1])):
            print(f"  {s}  ({len(mods)} modules: {', '.join(mods[:5])}{' ...' if len(mods) > 5 else ''})")
    failed = (set(bad_mods) | set(missing_mods)) - allowed
    tolerated = (set(bad_mods) | set(missing_mods)) & allowed
    if tolerated:
        print(f"\nallowed failures: {', '.join(sorted(tolerated))}")
    print(f"RESULT: {'FAIL' if failed else 'PASS'}"
          + (f" ({len(failed)} modules: {', '.join(sorted(failed)[:10])})" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
