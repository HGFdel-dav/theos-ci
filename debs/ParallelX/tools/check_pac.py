#!/usr/bin/env python3
"""Inspect Mach-O __text without building or executing the image.

clone0.4's Apple arm64e CI binary double-signed x30 without changing SP,
then attempted to authenticate that signed PAC as if it were a raw return
address. Fail on this precise class of return-address ABI corruption.
"""
import argparse
import json
import struct
from pathlib import Path

FAT_MAGIC = b"\xca\xfe\xba\xbe"
FAT64_MAGIC = b"\xca\xfe\xba\xbf"
SIGNS = {0xD503237F: "pacibsp", 0xD503233F: "paciasp"}
AUTHS = {0xD50323FF: "autibsp", 0xD50323BF: "autiasp"}
RET_AUTH = {0xD65F0FFF: "retab", 0xD65F0BFF: "retaa"}
NOP = 0xD503201F
BTI = {0xD503241F, 0xD503245F, 0xD503249F, 0xD50324DF}


def slices(blob):
    if blob[:4] in (FAT_MAGIC, FAT64_MAGIC):
        is64 = blob[:4] == FAT64_MAGIC
        count = struct.unpack_from(">I", blob, 4)[0]
        entry_size = 32 if is64 else 20
        for i in range(count):
            at = 8 + i * entry_size
            if is64:
                _, _, offset, size, _, _ = struct.unpack_from(">IIQQII", blob, at)
            else:
                _, _, offset, size, _ = struct.unpack_from(">IIIII", blob, at)
            if offset + size > len(blob):
                raise ValueError("fat slice outside image")
            yield offset, blob[offset:offset + size]
    else:
        yield 0, blob


def text_sections(blob):
    if len(blob) < 32 or blob[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("expected little-endian 64-bit Mach-O")
    _, cpu, subtype, _, count, _, _, _ = struct.unpack_from("<8I", blob)
    pos = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", blob, pos)
        if size < 8 or pos + size > len(blob):
            raise ValueError("invalid load command")
        if command == 0x19:
            nsects = struct.unpack_from("<I", blob, pos + 64)[0]
            for index in range(nsects):
                off = pos + 72 + index * 80
                name, segment = struct.unpack_from("<16s16s", blob, off)
                addr, length, fileoff, _ = struct.unpack_from("<QQII", blob, off + 32)
                if name.rstrip(b"\0") == b"__text":
                    if fileoff + length > len(blob):
                        raise ValueError("text section outside image")
                    yield cpu, subtype, addr, blob[fileoff:fileoff + length]
        pos += size


def scan_text(code, address=0):
    issues = []
    signs = auths = 0
    previous = None
    for offset in range(0, len(code) - 3, 4):
        word = struct.unpack_from("<I", code, offset)[0]
        if word in SIGNS:
            signs += 1
        if word in AUTHS or word in RET_AUTH:
            auths += 1
        if word == NOP or word in BTI:
            continue
        if previous:
            prior, prior_offset = previous
            kind = None
            if prior in SIGNS and word in SIGNS:
                kind = "double-sign"
            elif prior in AUTHS and (word in AUTHS or word in RET_AUTH):
                kind = "double-authenticate"
            if kind:
                issues.append({"kind": kind, "address": hex(address + prior_offset),
                               "next": hex(address + offset)})
        previous = word, offset
    return {"signs": signs, "authentications": auths, "issues": issues}


def inspect(path, expected_arch=None):
    blob = Path(path).read_bytes()
    results = []
    sections = 0
    for file_offset, image in slices(blob):
        for cpu, subtype, address, code in text_sections(image):
            sections += 1
            arm64e = cpu == 0x100000C and (subtype & 0xFFFFFF) == 2
            arch = "arm64e" if arm64e else "arm64" if cpu == 0x100000C else hex(cpu)
            if expected_arch and arch != expected_arch:
                raise ValueError(f"expected {expected_arch}, found {arch}")
            result = scan_text(code, address)
            result.update({"path": str(path), "arch": arch,
                           "slice_offset": file_offset, "text_address": hex(address)})
            if arm64e and not result["signs"]:
                result["issues"].append({"kind": "arm64e-without-return-pac"})
            results.append(result)
    if not sections:
        raise ValueError("no __text section found")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+")
    parser.add_argument("--expect-arch", choices=("arm64", "arm64e"))
    args = parser.parse_args()
    failed = False
    for image in args.images:
        try:
            for result in inspect(image, args.expect_arch):
                print(json.dumps(result, ensure_ascii=False))
                failed |= bool(result["issues"])
        except (ValueError, OSError, struct.error) as error:
            print(json.dumps({"path": image, "error": str(error)}))
            failed = True
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
