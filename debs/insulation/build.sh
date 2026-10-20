#!/usr/bin/env bash
# insulation 二进制修补 + ldid 重签 + 打包（云端等价于本地 fix2 全流程）
set -euo pipefail
cd "$(dirname "$0")"

# 需要 macos runner: python3 / ldid（Setup 步骤 brew install ldid）/ dpkg-deb
command -v python3 ldid dpkg-deb >/dev/null || { echo '缺 ldid 或 dpkg-deb'; exit 1; }

rm -rf build stage
mkdir -p build stage

echo '--- 1. 修补 8 条指令 ---'
python3 patch.py original/insulation.dylib build/insulation.dylib

echo '--- 2. ad-hoc 重签（漏签就是 SIGKILL-CODESIGNING 崩） ---'
ldid -S -H sha256 build/insulation.dylib

echo '--- 3. 逐页哈希自校验（等价内核 AMFI 装载检查） ---'
python3 - build/insulation.dylib <<'PY'
import struct, hashlib, sys
b = open(sys.argv[1], 'rb').read()
n = struct.unpack_from('>I', b, 4)[0]
slices = {}
for i in range(n):
    cpu, sub, off, size, al = struct.unpack_from('>IIIII', b, 8 + 20*i)
    slices['arm64e' if (sub & 0xFFFFFF) == 2 else 'arm64'] = b[off:off+size]
def lc_iter(sl):
    ncmds, off = struct.unpack_from('<II', sl, 16)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', sl, off)
        yield cmd, off, size
        off += size
for arch, sl in sorted(slices.items()):
    dataoff = datasize = None
    for cmd, off, size in lc_iter(sl):
        if cmd == 0x1D:
            dataoff, datasize = struct.unpack_from('<II', sl, off + 8)
    assert dataoff, f'{arch}: 无 LC_CODE_SIGNATURE'
    blob = sl[dataoff:dataoff+datasize][:struct.unpack('>I', sl[dataoff+4:dataoff+8])[0]]
    magic, length, count = struct.unpack_from('>III', blob, 0)
    assert magic == 0xfade0cc0 and length == len(blob)
    cd_off = next(o for t, o in (struct.unpack_from('>II', blob, 12 + 8*i) for i in range(count)) if t == 0)
    cd = blob[cd_off:]
    assert struct.unpack_from('>I', cd, 0)[0] == 0xfade0c02
    version, flags, hash_off, ident_off, nspecial, ncode, code_limit, hash_size, hash_type = \
        struct.unpack_from('>IIIIIIIIBB', cd, 8)[:9]
    assert version == 0x00020400 and hash_type == 2 and hash_size == 32
    ok = all(cd[hash_off + k*32 : hash_off + (k+1)*32] ==
             hashlib.sha256(sl[k*4096:min((k+1)*4096, code_limit)]).digest()
             for k in range(ncode))
    assert ok, f'{arch}: 页哈希校验失败'
    print(f'  ✓ {arch}: {ncode} 页哈希全覆盖 codeLimit={code_limit:#x}')
PY

echo '--- 3. 组装 stage ---'
cp -R payload/. stage/
mkdir -p stage/DEBIAN
cp control postinst stage/DEBIAN/
chmod 755 stage/DEBIAN/postinst
chmod 644 stage/DEBIAN/control
cp build/insulation.dylib stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
chmod 755 stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
find stage -type d -exec chmod 755 {} \;

echo '--- 4. 打包 ---'
DEB=com.be-huge.insulation_0.1.38.1-fix2_iphoneos-arm64e.deb
dpkg-deb --root-owner-group --build stage "$DEB"
ls -l "$DEB"
echo '--- 5. 噪声清理 ---'
rm -rf build stage
