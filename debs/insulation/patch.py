#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""insulation 0.1.38.1 参数误用修补（8 条指令）
- getPotentialForcedThermalLevel: 的 replacement IMP 原版把 uint64 标量参数/返回值当对象
  objc_retain / objc_retainAutoreleasedReturnValue / objc_release，thermalmonitord 一调用
  就 EXC_BAD_ACCESS(0x11) 循环崩，看门狗 180s 无心跳 → userspace panic。
- 只改对象生命周期处理这 8 条指令，任何功能判断分支不动。
用法：python3 patch.py <original.dylib> <out.dylib>   out 必须先不存在
"""
import struct, os, sys

SRC, DST = sys.argv[1], sys.argv[2]
NOP   = 0xD503201F
RETAB = 0xD65F0FFF
PATCHES = [
    ("arm64e", 0x08D64, 0x940006D2, NOP,   "不要 objc_retain(标量参数)"),
    ("arm64e", 0x08D94, 0x940006CE, NOP,   "不要 objc_retainAutoreleasedReturnValue(标量返回值)"),
    ("arm64e", 0x08DA8, 0x940006BD, NOP,   "不要 objc_release(标量参数)"),
    ("arm64e", 0x08DD4, 0x1400068E, RETAB, "标量返回值直接 retab"),
    ("arm64",  0x0C6C8, 0x9400065A, NOP,   "同上的 arm64 切片"),
    ("arm64",  0x0C6F8, 0x94000654, NOP,   ""),
    ("arm64",  0x0C70C, 0x94000646, NOP,   ""),
    ("arm64",  0x0C728, 0x14000624, RETAB, ""),
]

def load(path):
    buf = open(path, 'rb').read()
    magic, cnt = struct.unpack_from('>II', buf, 0)
    assert magic in (0xCAFEBABE, 0xCAFEBABF), '不是 fat Mach-O'
    slices = []
    for i in range(cnt):
        cpu, sub, off, size, al = struct.unpack_from('>IIIII', buf, 8 + 20*i)
        name = 'arm64e' if (sub & 0xFFFFFF) == 2 else 'arm64'
        slices.append({'name': name, 'cpu': cpu, 'sub': sub,
                       'off': off, 'size': size, 'align': al,
                       'raw': bytearray(buf[off:off+size])})
    return cnt, slices

def repack(data, slices):
    out = bytearray(data[:4])
    out += struct.pack('>I', len(slices))
    cursor = 0x4000
    infos = []
    for s in slices:
        infos.append((s['cpu'], s['sub'], cursor, len(s['raw']), s['align'], s))
        cursor += (len(s['raw']) + 0x3FFF) & ~0x3FFF
    for cpu, sub, off, size, align, _ in infos:
        out += struct.pack('>IIIII', cpu, sub, off, size, align)
    out += b'\x00' * (0x4000 - len(out))
    for cpu, sub, off, size, align, s in infos:
        while len(out) < off:
            out += b'\x00'
        out += s['raw']
    return bytes(out)

def main():
    assert not os.path.exists(DST), '目标已存在: ' + DST
    with open(SRC, 'rb') as f:
        data = f.read()
    slices_by_name = {s['name']: s for s in load(SRC)[1]}
    for arch, off, expect, repl, note in PATCHES:
        s = slices_by_name[arch]
        cur = struct.unpack_from('<I', s['raw'], off)[0]
        assert cur == expect, f'{arch}@{off:#x} 期望 {expect:08X} 实际 {cur:08X}'
        struct.pack_into('<I', s['raw'], off, repl)
        print(f'  ✓ {arch:<6} @{off:#06x}  {expect:08X} → {repl:08X}  {note}')
    # 写盘
    tmp = DST + '.part'
    with open(tmp, 'wb') as f:
        f.write(repack(data, [slices_by_name['arm64'], slices_by_name['arm64e']]))
    os.rename(tmp, DST)
    # 写后读回复核
    with open(DST, 'rb') as f:
        again = f.read()
    _, rs = load_again = (None, )
    rx = [{ 'name': ('arm64e' if ((struct.unpack_from('>IIIII', again, 8+20*j)[1] & 0xFFFFFF) == 2) else 'arm64'),
            'off': struct.unpack_from('>IIIII', again, 8+20*j)[2],
            'size': struct.unpack_from('>IIIII', again, 8+20*j)[3]} for j in range(2)]
    sl = {x['name']: again[x['off']:x['off']+x['size']] for x in rx}
    for arch, off, expect, repl, note in PATCHES:
        got = struct.unpack_from('<I', sl[arch], off)[0]
        assert got == repl, f'写后读校验失败 {arch}@{off:#x}: {got:08X}'
    print(f'  ✓ 写后读回：8 处修补全部在 {DST}')

if __name__ == '__main__':
    main()
