#!/usr/bin/env python3
"""Extract the vendor ramdisk (all fragments) from a vendor_boot v3/v4 image.

Writes the raw (still compressed) ramdisk blob; decompress with `lz4 -dc` and
unpack with `cpio -idm`.

Usage: extract-vendor-ramdisk.py <vendor_boot.img> <out.ramdisk>
"""
import struct
import sys

img = open(sys.argv[1], "rb").read()
if img[:8] != b"VNDRBOOT":
    sys.exit("not a vendor_boot image")
version, page_size, _kaddr, _raddr, rd_size = struct.unpack_from("<5I", img, 8)
# after: cmdline[2048], tags_addr u32, name[16], header_size u32, dtb_size u32, dtb_addr u64
off = 8 + 5 * 4 + 2048 + 4 + 16
header_size, = struct.unpack_from("<I", img, off)
print(f"vendor_boot v{version}, page_size={page_size}, header_size={header_size}, vendor_ramdisk_size={rd_size}")
start = -(-header_size // page_size) * page_size
open(sys.argv[2], "wb").write(img[start:start + rd_size])
print(f"wrote {rd_size} bytes from offset {start} -> {sys.argv[2]}")
