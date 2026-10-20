#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯 Python 的 .deb 打包器（不依赖 dpkg-deb，云端 macos runner / 本地行为一致）。
等价 dpkg-deb --root-owner-group：所有条目 uid/gid=0（root:wheel），mtime=0（可复现）。

deb 结构要求：
  control.tar.gz  → 条目必须在根：./control ./postinst
  data.tar.gz     → 条目为实际安装路径 ./Library/... ./usr/...，绝不能含 DEBIAN
用法：python3 mkdeb.py <stage目录> <输出.deb>
"""
import io, os, sys, tarfile

STAGE, OUT = sys.argv[1], sys.argv[2]
DEBIAN = 'DEBIAN'


def add(tar, path, arcname):
    st = os.stat(path, follow_symlinks=False)
    ti = tarfile.TarInfo(arcname)
    ti.size = st.st_size
    ti.mtime = 0
    ti.mode = st.st_mode & 0o7777
    ti.uid = 0; ti.gid = 0
    ti.uname = 'root'; ti.gname = 'wheel'
    if os.path.isdir(path):
        ti.type = tarfile.DIRTYPE
        tar.addfile(ti)
    else:
        ti.type = tarfile.REGTYPE
        with open(path, 'rb') as f:
            tar.addfile(ti, f)


# --- control.tar.gz：control / postinst 放在根 ---
cbuf = io.BytesIO()
cnames = []
with tarfile.open(fileobj=cbuf, mode='w:gz') as tar:
    for name in sorted(os.listdir(os.path.join(STAGE, DEBIAN))):
        p = os.path.join(STAGE, DEBIAN, name)
        add(tar, p, './' + name)
        cnames.append(name)

# --- data.tar.gz：STAGE 下除 DEBIAN 外全部，路径即安装路径 ---
dbuf = io.BytesIO()
dnames = []
with tarfile.open(fileobj=dbuf, mode='w:gz') as tar:
    for root_, dirs, files in os.walk(STAGE):
        dirs.sort(); files.sort()
        # DEBIAN 整支剔除（含目录项本身），data.tar 里绝不能出现
        if DEBIAN in dirs:
            dirs.remove(DEBIAN)
        rel_root = os.path.relpath(root_, STAGE)
        if rel_root == DEBIAN or rel_root.startswith(DEBIAN + os.sep):
            continue
        for name in dirs + files:
            p = os.path.join(root_, name)
            rel = os.path.relpath(p, STAGE)
            if rel == DEBIAN or rel.startswith(DEBIAN + os.sep):
                continue
            add(tar, p, './' + rel)
            dnames.append(rel)

# --- 自检 ---
assert 'control' in cnames, 'control.tar 缺 control'
assert 'postinst' in cnames, 'control.tar 缺 postinst'
assert not any(n == DEBIAN or n.startswith(DEBIAN + os.sep) for n in dnames), \
    'data.tar 混入了 DEBIAN'
assert 'Library/MobileSubstrate/DynamicLibraries/insulation.dylib' in dnames, \
    'data.tar 缺 insulation.dylib'
assert 'usr/bin/insulationctl' in dnames, 'data.tar 缺 insulationctl'
assert 'Library/PreferenceBundles/InsulationPrefs.bundle/Root.plist' in dnames, \
    'data.tar 缺 InsulationPrefs Root.plist'
assert 'Library/ControlCenter/Bundles/InsulationCC.bundle/InsulationCC' in dnames, \
    'data.tar 缺 InsulationCC'


def ar_member(name, payload):
    hdr = name.ljust(16).encode()                 # 16 字节名（带 / 结尾）
    hdr += '0'.rjust(12).encode()                  # mtime（固定 0，可复现）
    hdr += b'0'.rjust(6)                           # uid
    hdr += b'0'.rjust(6)                           # gid
    hdr += oct(0o100644)[2:].rjust(8).encode()     # mode
    hdr += str(len(payload)).rjust(10).encode()    # size
    hdr += b'`\n'
    pad = b'\n' if len(payload) % 2 else b''
    return hdr + payload + pad


with open(OUT, 'wb') as f:
    f.write(b'!<arch>\n')
    f.write(ar_member('debian-binary/', b'2.0\n'))
    f.write(ar_member('control.tar.gz/', cbuf.getvalue()))
    f.write(ar_member('data.tar.gz/', dbuf.getvalue()))
print(f'  ✓ 打包完成 {OUT} ({os.path.getsize(OUT)} bytes, control={cnames}, data={len(dnames)}项)')
