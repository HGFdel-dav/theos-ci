#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 dylib 的 ad-hoc 签名：结构 + 全部 CodeDirectory 的逐页哈希。
等价内核 AMFI 装载检查。iOS 15 的 arm64e 需要 SHA256 CodeDirectory；
两种合法形状都接受：
  A) slot0 = SHA256 CD（只有一张 CD，-Hsha256 产出）
  B) slot0 = SHA1 CD + alternate 槽(0x1000) = SHA256 CD（上游原厂包的形状）
所有 CD 的页哈希都必须与当前字节一致（防止签完又被改动）。
退出码 0 = 通过。
"""
import hashlib, struct, sys

CS_HASHTYPE_SHA1 = 1
CS_HASHTYPE_SHA256 = 2
CSSLOT_CODEDIRECTORY = 0
CSSLOT_ALTERNATE = 0x1000
HASHERS = {CS_HASHTYPE_SHA1: hashlib.sha1, CS_HASHTYPE_SHA256: hashlib.sha256}


def lc_iter(sl):
    ncmds, pos = struct.unpack_from('<II', sl, 16)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', sl, pos)
        yield cmd, pos, size
        pos += size


def check_arch(arch, sl):
    dataoff = datasize = None
    for cmd, pos, size in lc_iter(sl):
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack_from('<II', sl, pos + 8)
    if not dataoff:
        print(f'  ✗ {arch}: 无 LC_CODE_SIGNATURE（未签名）')
        return False
    blob = sl[dataoff:dataoff+datasize]
    magic, length, count = struct.unpack_from('>III', blob, 0)
    if magic != 0xfade0cc0:
        print(f'  ✗ {arch}: superblob magic {magic:#x}')
        return False
    if length > len(blob):
        print(f'  ✗ {arch}: blob 长度异常 {length}')
        return False
    blob = blob[:length]
    ents = [struct.unpack_from('>II', blob, 12 + 8*i) for i in range(count)]

    cds = []
    for t, o in ents:
        if not (t == CSSLOT_CODEDIRECTORY or CSSLOT_ALTERNATE <= t < CSSLOT_ALTERNATE + 0x1000):
            continue
        if o + 4 > len(blob) or struct.unpack_from('>I', blob, o)[0] != 0xfade0c02:
            continue
        cd = blob[o:]
        version, flags, hash_off, ident_off, nspecial, ncode, code_limit = \
            struct.unpack_from('>IIIIIII', cd, 8)
        hash_size, hash_type = cd[36], cd[37]
        cds.append((t, o, version, hash_off, ncode, code_limit, hash_size, hash_type))
    if not cds:
        print(f'  ✗ {arch}: 无 CodeDirectory')
        return False

    desc = ' | '.join(
        f'slot{t} hashType={ht} hashSize={hs} v{v:#06x} pages={nc}'
        for t, o, v, ho, nc, cl, hs, ht in cds)

    if not any(c[7] == CS_HASHTYPE_SHA256 for c in cds):
        print(f'  ✗ {arch}: 无 SHA256 CodeDirectory（{desc}）—— iOS 15 arm64e 拒收')
        return False

    for t, o, version, hash_off, ncode, code_limit, hash_size, hash_type in cds:
        if hash_type not in HASHERS:
            print(f'  ✗ {arch}: slot{t} 未知 hashType {hash_type}')
            return False
        if version not in (0x20400, 0x20500):
            print(f'  ✗ {arch}: slot{t} CD 版本异常 {version:#x}')
            return False
        cd = blob[o:]
        hasher = HASHERS[hash_type]
        bad = []
        for k in range(ncode):
            seg = sl[k*4096 : min((k+1)*4096, code_limit)]
            want = cd[hash_off + k*hash_size : hash_off + (k+1)*hash_size]
            if hasher(seg).digest() != want:
                bad.append(k)
        if bad:
            print(f'  ✗ {arch}: slot{t} (hashType={hash_type}) 页哈希不匹配 {bad[:5]}'
                  f' —— 签名未覆盖当前字节')
            return False
    print(f'  ✓ {arch}: 全部 CD 页哈希一致，SHA256 CD 存在 pages={cds[0][4]} '
          f'codeLimit={cds[0][5]:#x}  [{desc}]')
    return True


def main(path):
    b = open(path, 'rb').read()
    n = struct.unpack_from('>I', b, 4)[0]
    slices = {}
    for i in range(n):
        cpu, sub, off, size, al = struct.unpack_from('>IIIII', b, 8 + 20*i)
        arch = 'arm64e' if ((sub & 0xFFFFFF) == 2) else 'arm64'
        slices[arch] = b[off:off+size]
    ok = True
    for arch in sorted(slices):
        if not check_arch(arch, slices[arch]):
            ok = False
    if ok:
        print('---签名校验通过---')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
