#!/usr/bin/env python3
"""Static CodeDirectory page-integrity check; NOT an AMFI/trust/load proof."""
import hashlib
import json
import struct
import sys
from pathlib import Path
from verify_macho import View, slices, Invalid

HASH = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256}
def require(ok, message):
    if not ok:
        raise ValueError(message)
def verify(path):
    data = Path(path).read_bytes()
    report = {'stage': 'signature_page_integrity_only', 'passed': False, 'slices': [], 'errors': []}
    try:
        _, descriptors = slices(View(data))
        for base, size, cpu, subtype in descriptors:
            image = data[base:base + size]
            require(len(image) >= 32, 'truncated Mach-O header')
            count, commands_size = struct.unpack_from('<II', image, 16)
            end, pos, signature = 32 + commands_size, 32, None
            require(end <= size, 'load commands exceed slice')
            for _ in range(count):
                require(pos + 8 <= end, 'truncated load command')
                cmd, length = struct.unpack_from('<II', image, pos)
                require(length >= 8 and pos + length <= end, 'invalid load command')
                if cmd == 0x1d:
                    require(length >= 16 and signature is None, 'invalid/duplicate code signature command')
                    signature = struct.unpack_from('<II', image, pos + 8)
                pos += length
            require(pos == end and signature, 'missing code signature')
            offset, sig_size = signature
            require(offset > end and offset + sig_size <= size, 'signature outside slice')
            blob = image[offset:offset + sig_size]
            require(len(blob) >= 12, 'truncated signature superblob')
            magic, length, count = struct.unpack_from('>III', blob)
            require(magic == 0xfade0cc0 and 12 + count * 8 <= length <= len(blob), 'invalid signature superblob')
            blob = blob[:length]
            entries, directories = {}, []
            for index in range(count):
                kind, off = struct.unpack_from('>II', blob, 12 + index * 8)
                require(off >= 12 + count * 8 and off + 8 <= length, 'invalid signature subblob offset')
                typ, length_sub = struct.unpack_from('>II', blob, off)
                require(length_sub >= 8 and off + length_sub <= length, 'invalid signature subblob length')
                require(kind not in entries, 'duplicate signature slot')
                sub = blob[off:off + length_sub]
                entries[kind] = sub
                if kind == 0 or 0x1000 <= kind < 0x2000:
                    require(typ == 0xfade0c02, 'CodeDirectory slot has wrong magic')
                    directories.append((kind, sub))
            require(directories, 'no CodeDirectory')
            out = {'architecture': 'arm64e' if subtype & 0xffffff == 2 else 'other', 'directories': []}
            has_sha256 = False
            for kind, cd in directories:
                require(len(cd) >= 44, 'truncated CodeDirectory')
                version, flags, hash_off, ident_off, special, pages, limit = struct.unpack_from('>7I', cd, 8)
                hash_size, hash_type, platform, exponent = cd[36:40]
                require(hash_type in HASH and exponent <= 20, 'unsupported signature hash/page size')
                expected_size = 20 if hash_type in (1, 3) else 32
                require(hash_size == expected_size, 'hash size/type mismatch')
                if version >= 0x20300 and limit == 0xffffffff:
                    require(len(cd) >= 64, 'missing 64-bit code limit')
                    limit = struct.unpack_from('>Q', cd, 56)[0]
                require(limit == offset, 'CodeDirectory must cover the entire unsigned slice prefix')
                page_size = 1 << exponent if exponent else limit
                expected_pages = (limit + page_size - 1) // page_size if limit else 0
                require(pages == expected_pages, 'page count/code limit mismatch')
                require(hash_off >= special * hash_size and hash_off + pages * hash_size <= len(cd), 'hash table outside CodeDirectory')
                require(ident_off < len(cd) and b'\0' in cd[ident_off:], 'invalid signing identifier')
                hasher = HASH[hash_type]
                for page in range(pages):
                    actual = hasher(image[page * page_size:min((page + 1) * page_size, limit)]).digest()[:hash_size]
                    wanted = cd[hash_off + page * hash_size:hash_off + (page + 1) * hash_size]
                    require(actual == wanted, 'CodeDirectory slot %d page %d hash mismatch' % (kind, page))
                for slot, sub in entries.items():
                    if 0 < slot <= special:
                        wanted = cd[hash_off - slot * hash_size:hash_off - (slot - 1) * hash_size]
                        require(hasher(sub).digest()[:hash_size] == wanted, 'embedded special-slot hash mismatch')
                has_sha256 |= hash_type == 2
                out['directories'].append({'slot': kind, 'hash_type': hash_type, 'pages': pages, 'page_size': page_size, 'code_limit': limit})
            require(has_sha256, 'no full SHA256 CodeDirectory')
            report['slices'].append(out)
        report['passed'] = True
    except (OSError, ValueError, struct.error, Invalid) as exc:
        report['errors'].append(str(exc))
    return report

if __name__ == '__main__':
    result = verify(sys.argv[1])
    print(json.dumps(result, indent=2))
    raise SystemExit(not result['passed'])
