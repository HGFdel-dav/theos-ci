#!/usr/bin/env bash
# insulation 二进制修补 + ldid 重签 + 打包（云端等价于本地 fix2 全流程）
set -euo pipefail
cd "$(dirname "$0")"

command -v python3  >/dev/null || { echo '缺 python3'; exit 1; }
command -v ldid     >/dev/null || { echo '缺 ldid'; exit 1; }

rm -rf build stage
mkdir -p build stage

echo '--- 1. 修补 8 条指令 ---'
python3 patch.py original/insulation.dylib build/insulation.dylib

echo '--- 2. ad-hoc 重签（漏签就是 SIGKILL-CODESIGNING 崩） ---'
ldid -S build/insulation.dylib

echo '--- 3. 逐页哈希自校验（等价内核 AMFI 装载检查） ---'
python3 - build/insulation.dylib <<'PYEOF'
import struct, hashlib, sys

b = open(sys.argv[1], 'rb').read()
n = struct.unpack_from('>I', b, 4)[0]
slices = {}
for i in range(n):
    cpu, sub, off, size, al = struct.unpack_from('>IIIII', b, 8 + 20*i)
    arch = 'arm64e' if ((sub & 0xFFFFFF) == 2) else 'arm64'
    slices[arch] = b[off:off+size]

def lc_iter(sl):
    ncmds, pos = struct.unpack_from('<II', sl, 16)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', sl, pos)
        yield cmd, pos, size
        pos += size

for arch in sorted(slices):
    sl = slices[arch]
    dataoff = datasize = None
    for cmd, pos, size in lc_iter(sl):
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            dataoff, datasize = struct.unpack_from('<II', sl, pos + 8)
    assert dataoff, f'{arch}: 无 LC_CODE_SIGNATURE'
    blob = sl[dataoff:dataoff+datasize]
    magic, length, count = struct.unpack_from('>III', blob, 0)
    assert magic == 0xfade0cc0, f'{arch}: superblob magic {magic:#x}'
    assert length <= len(blob), f'{arch}: blob 长度 {length} > datasize {len(blob)}'
    blob = blob[:length]
    ents = [struct.unpack_from('>II', blob, 12 + 8*i) for i in range(count)]
    cd_off = next(o for t, o in ents if t == 0)
    cd = blob[cd_off:]
    assert struct.unpack_from('>I', cd, 0)[0] == 0xfade0c02, f'{arch}: CD magic 异常'
    version, flags, hash_off, ident_off, nspecial, ncode, code_limit = \
        struct.unpack_from('>IIIIIII', cd, 8)
    hash_size, hash_type = cd[36], cd[37]
    assert version in (0x20400, 0x20500), f'{arch}: CD 版本异常 {version:#x}'
    assert hash_type == 2, f'{arch}: hash type {hash_type} != SHA256'
    assert hash_size == 32, f'{arch}: hash size {hash_size} != 32'
    bad = []
    for k in range(ncode):
        seg = sl[k*4096 : min((k+1)*4096, code_limit)]
        want = cd[hash_off + k*32 : hash_off + (k+1)*32]
        if hashlib.sha256(seg).digest() != want:
            bad.append(k)
    assert not bad, f'{arch}: 页哈希不匹配页 {bad[:5]}'
    print(f'  ✓ {arch}: {ncode} 页哈希全覆盖 codeLimit={code_limit:#x} version={version:#06x}')
print('---签名校验通过---')
PYEOF

echo '--- 4. 组装 stage ---'
cp -R payload/. stage/
mkdir -p stage/DEBIAN
cp control postinst stage/DEBIAN/
cp build/insulation.dylib stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
find stage -type d -exec chmod 755 {} \;
find stage -type f -exec chmod 644 {} \;
chmod 755 stage/DEBIAN/postinst
chmod 755 stage/Library/MobileSubstrate/DynamicLibraries/insulation.dylib
chmod 755 stage/usr/bin/insulationctl
chmod 755 stage/Library/ControlCenter/Bundles/InsulationCC.bundle/InsulationCC
chmod 755 stage/Library/PreferenceBundles/InsulationPrefs.bundle/InsulationPrefs

echo '--- 5. 打包 ---'
DEB=com.be-huge.insulation_0.1.38.1-fix2_iphoneos-arm64e.deb
python3 mkdeb.py stage "$DEB"
ls -l "$DEB"

echo '--- 6. 噪声清理 ---'
rm -rf build stage
