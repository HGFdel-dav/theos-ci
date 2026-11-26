#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Static-only Mach-O/CodeDirectory audit, adapted from the local .57 auditor.
Integrity does NOT prove trust, installation or successful runtime loading.
"""
import hashlib, math, pathlib, struct

def need(ok, message):
    if not ok: raise ValueError(message)

def version(n): return '.'.join(map(str, (n >> 16, (n >> 8) & 255, n & 255)))

def audit(path, expected, *, minimum):
    need(expected in ('arm64', 'arm64e'), 'unknown CPU contract')
    need(minimum in ('15.0.0', '15.5.0'), 'explicit minimum required')
    data = pathlib.Path(path).read_bytes()
    need(len(data) >= 32, 'truncated Mach-O')
    magic, cpu, sub, kind, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data)
    need(magic == 0xfeedfacf and cpu == 0x100000c, 'thin arm64 Mach-O required')
    need(sub == (0x80000002 if expected == 'arm64e' else 0), 'wrong CPU subtype/PAC ABI')
    need(kind == 6 and 0 < ncmds <= sizeofcmds // 8, 'invalid dylib/load commands')
    end = 32 + sizeofcmds
    need(end <= len(data), 'commands exceed file')
    pos = 32; builds = []; sig = None
    for _ in range(ncmds):
        need(pos + 8 <= end, 'truncated command')
        cmd, size = struct.unpack_from('<II', data, pos)
        need(size >= 8 and pos + size <= end, 'invalid command range')
        if cmd == 0x32:
            need(size >= 24, 'truncated build command')
            platform, minos, sdk, tools = struct.unpack_from('<4I', data, pos + 8)
            need(24 + 8 * tools <= size, 'truncated build tools')
            builds.append({'platform': platform, 'minOS': version(minos), 'SDK': version(sdk)})
        if cmd == 0x1d:
            need(size == 16 and sig is None, 'invalid/duplicate signature command')
            sig = struct.unpack_from('<II', data, pos + 8)
        pos += size
    need(pos == end, 'command size mismatch')
    need(len(builds) == 1 and builds[0] == {'platform': 2, 'minOS': minimum, 'SDK': '15.5.0'}, 'wrong platform/minOS/SDK')
    need(sig is not None, 'missing signature')
    offset, capacity = sig
    need(offset >= end and capacity >= 12 and offset + capacity == len(data), 'invalid signature range/unsigned trailing bytes')
    raw = data[offset:offset + capacity]
    magic, length, count = struct.unpack_from('>III', raw)
    need(magic == 0xfade0cc0 and 12 + 8 * count <= length <= len(raw), 'invalid SuperBlob')
    blobs = {}; ranges = []
    for i in range(count):
        slot, at = struct.unpack_from('>II', raw, 12 + i * 8)
        need(slot not in blobs and 12 + 8 * count <= at and at + 8 <= length, 'invalid signature index')
        bm, bl = struct.unpack_from('>II', raw, at)
        need(bl >= 8 and at + bl <= length, 'invalid signature blob')
        need(all(at + bl <= lo or at >= hi for lo, hi in ranges), 'overlapping signature blobs')
        ranges.append((at, at + bl)); blobs[slot] = (bm, raw[at:at + bl])
    need(set(blobs).issubset({0, 2, 0x1000}), 'unexpected signing slot/entitlement expansion')
    need(0 in blobs and blobs[0][0] == 0xfade0c02, 'missing primary CodeDirectory')
    for slot, (bm, _) in blobs.items():
        need(bm == (0xfade0c01 if slot == 2 else 0xfade0c02), 'wrong signing slot/blob type')
    directories = []
    for slot, (bm, cd) in blobs.items():
        if bm != 0xfade0c02: continue
        need(len(cd) >= 44, 'truncated CodeDirectory')
        _, clen, ver, cflags, hashoff, identoff, nspecial, ncode, limit = struct.unpack_from('>9I', cd)
        hsize, htype, platform, shift = struct.unpack_from('>4B', cd, 36)
        if ver >= 0x20300:
            need(len(cd) >= 64, 'truncated codeLimit64')
            large = struct.unpack_from('>Q', cd, 56)[0]
            if large: limit = large
        need(limit == offset, 'unsigned bytes before signature')
        need(htype in (1, 2, 3, 4) and shift <= 30, 'unsupported page hash')
        algorithm = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}[htype]
        need(hsize == {1: 20, 2: 32, 3: 20, 4: 48}[htype], 'invalid hash size')
        page = (1 << shift) if shift else limit
        need(ncode == math.ceil(limit / page), 'wrong page count')
        need(44 <= identoff < len(cd) and b'\0' in cd[identoff:], 'invalid identifier')
        need(hashoff - nspecial * hsize >= 44 and hashoff + ncode * hsize <= len(cd), 'invalid hash table')
        for i in range(ncode):
            digest = hashlib.new(algorithm, data[i * page:min((i + 1) * page, limit)]).digest()[:hsize]
            need(digest == cd[hashoff + i * hsize:hashoff + (i + 1) * hsize], 'CodeDirectory page %d mismatch' % i)
        checked = []
        for i in range(1, nspecial + 1):
            digest = cd[hashoff - i * hsize:hashoff - (i - 1) * hsize]
            if not any(digest): continue
            need(i in blobs, 'unverified external special slot')
            need(hashlib.new(algorithm, blobs[i][1]).digest()[:hsize] == digest, 'special slot mismatch')
            checked.append(i)
        directories.append({'slot': slot, 'hash': algorithm, 'codePages': ncode, 'pageHashes': 'PASS', 'specialSlotsChecked': checked})
    need(directories, 'missing CodeDirectory')
    return {'architecture': expected, 'build': builds, 'codeDirectories': directories, 'static_only': True}
