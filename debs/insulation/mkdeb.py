#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯 Python 的 .deb 打包器（不依赖 dpkg-deb，云端 macos runner / 本地均一致）。
等价 dpkg-deb --root-owner-group：所有条目 uid/gid=0（root:wheel），mtime=0（可复现）。
用法：python3 mkdeb.py <stage目录> <输出.deb>
"""
import gzip, io, lzma, os, sys, tarfile, time

STAGE, OUT = sys.argv[1], sys.argv[2]

def make_tar(base, sub, comp):
    root = os.path.join(base, sub) if sub else base
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=comp) as tar:
        for root_, dirs, files in os.walk(root):
            for name in sorted(dirs) + sorted(files):
                p = os.path.join(root_, name)
                rel = os.path.relpath(p, root)   # control.tar 里条目须是 ./control 而非 ./DEBIAN/control
                st = os.stat(p, follow_symlinks=False)
                ti = tarfile.TarInfo('./' + rel)
                ti.size = st.st_size
                ti.mtime = 0
                ti.mode = st.st_mode & 0o7777
                ti.uid = 0; ti.gid = 0
                ti.uname = 'root'; ti.gname = 'wheel'
                ti.type = tarfile.DIRTYPE if os.path.isdir(p) else tarfile.REGTYPE
                if ti.type == tarfile.DIRTYPE:
                    tar.addfile(ti)
                else:
                    with open(p, 'rb') as f:
                        tar.addfile(ti, f)
    return buf.getvalue()

control = make_tar(STAGE, 'DEBIAN', 'w:gz')
data    = make_tar(STAGE, '', 'w:xz')

def ar_member(name, payload):
    hdr = name.ljust(16).encode()          # 16 字节文件名（带 / 结尾）
    hdr += '0'.rjust(12).encode()          # mtime（固定 0，保证可复现）
    hdr += b'0'.rjust(6)                   # uid
    hdr += b'0'.rjust(6)                   # gid
    hdr += oct(0o100644)[2:].rjust(8).encode()  # mode
    hdr += str(len(payload)).rjust(10).encode() # size
    hdr += b'`\n'
    pad = b'\n' if len(payload) % 2 else b''
    return hdr + payload + pad

with open(OUT, 'wb') as f:
    f.write(b'!<arch>\n')
    f.write(ar_member('debian-binary/', b'2.0\n'))
    f.write(ar_member('control.tar.gz/', control))
    f.write(ar_member('data.tar.xz/', data))
print(f'  ✓ 打包完成 {OUT} ({os.path.getsize(OUT)} bytes)')
