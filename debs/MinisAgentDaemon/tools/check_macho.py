#!/usr/bin/env python3
"""Static checks for one packaged daemon binary: arch, code signature,
ad-hoc flag and entitlements. Usage: check_macho.py BINARY arm64|arm64e"""
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = sys.argv[2]
data = path.read_bytes()

magic, cputype, cpusub, _, ncmds = struct.unpack_from("<IiiII", data, 0)
assert magic == 0xFEEDFACF, "not a 64-bit Mach-O"
assert cputype == 0x0100000C, f"wrong cpu type {cputype:#x}"
actual = "arm64e" if (cpusub & 0xFF) == 2 else "arm64"
assert actual == expected, f"subtype says {actual}, expected {expected}"

sig = None
at = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, at)
    if cmd == 0x1D:
        sig = struct.unpack_from("<II", data, at + 8)
    at += size
assert sig, "missing LC_CODE_SIGNATURE"

offset, length = sig
assert length and offset + length <= len(data), "signature outside file"
assert struct.unpack_from(">I", data, offset)[0] == 0xFADE0CC0, "no embedded signature"

count = struct.unpack_from(">I", data, offset + 8)[0]
assert count, "empty superblob"
flags_seen = False
ents = False
for index in range(count):
    btype, boff = struct.unpack_from(">II", data, offset + 12 + index * 8)
    blob = offset + boff
    if btype == 0x00000002:
        cd_flags = struct.unpack_from(">I", data, blob + 12)[0]
        flags_seen = bool(cd_flags & 0x2)
    if btype == 0x00000005:
        ents = True

assert flags_seen, "CodeDirectory flags lack CS_ADHOC (0x2)"
assert ents, "no entitlements blob"
print(f"ok {path.name}: {actual} signed adhoc, entitlements present")
