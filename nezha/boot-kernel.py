#!/usr/bin/env python3
"""Extract the kernel from an Android boot image (header v0-v4).

Writes the kernel payload, decompressed if it is gzip, so the
"Linux version" banner and the IKCONFIG blob can be read from it.

Usage: boot-kernel.py <boot.img> <out-kernel>
"""
import gzip
import struct
import sys

img = open(sys.argv[1], "rb").read()
if img[:8] != b"ANDROID!":
    sys.exit("not an Android boot image")
hdr_ver, = struct.unpack_from("<I", img, 40)
kernel_size, = struct.unpack_from("<I", img, 8)
page = 4096 if hdr_ver >= 3 else struct.unpack_from("<I", img, 36)[0]
kernel = img[page:page + kernel_size]
if kernel[:2] == b"\x1f\x8b":
    kernel = gzip.decompress(kernel)
elif kernel[56:60] != b"ARM\x64":
    sys.exit(f"unknown kernel format (magic {kernel[:4]!r})")
open(sys.argv[2], "wb").write(kernel)
print(f"boot v{hdr_ver}: kernel {len(kernel)} bytes -> {sys.argv[2]}")
