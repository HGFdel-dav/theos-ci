#!/usr/bin/env python3
"""ldid omits the ad-hoc CodeDirectory flag on some toolchains; iOS AMFI then
kills the binary. Set flag 0x2 on every CodeDirectory of a thin or fat Mach-O."""
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())


def patch_thin(base, size):
    if size < 32:
        return False
    magic = struct.unpack_from("<I", data, base)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        return False
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    at = base + (32 if magic == 0xFEEDFACF else 28)
    hit = False
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from("<II", data, at)
        if cmd == 0x1D:
            off, ssize = struct.unpack_from("<II", data, at + 8)
            sig = base + off
            count = struct.unpack_from(">I", data, sig + 8)[0]
            for index in range(count):
                entry = sig + 12 + index * 20
                if entry + 20 > sig + ssize:
                    break
                flags_at = entry + 16
                flags = struct.unpack_from(">I", data, flags_at)[0]
                struct.pack_into(">I", data, flags_at, flags | 0x2)
                hit = True
        at += cs
    return hit


magic = struct.unpack_from(">I", data, 0)[0]
if magic in (0xCAFEBABE, 0xCAFEBABF):
    fat_count = struct.unpack_from(">I", data, 4)[0]
    for index in range(fat_count):
        off, size = struct.unpack_from(">II", data, 16 + index * 20)
        patch_thin(off, size)
else:
    patch_thin(0, len(data))

path.write_bytes(data)
print(f"adhoc flag set: {path}")
