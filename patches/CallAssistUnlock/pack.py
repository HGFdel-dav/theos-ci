#!/usr/bin/env python3
import gzip
import io
import os
import pathlib
import subprocess
import tarfile

HERE = pathlib.Path(__file__).resolve().parent
WORK = HERE / '.work'
ROOT = WORK / 'root'
CTL = WORK / 'ctl'
OUT = HERE / 'CallAssist-2.5.1-unlock1.deb'

EXEC = {
    'Library/MobileSubstrate/DynamicLibraries/CallAssist.dylib',
    'Library/PreferenceBundles/CallAssistSetting.bundle/CallAssistSetting',
    'usr/local/bin/CallAudioService',
    'usr/local/bin/CallassistTool',
}


def add(tf, path, arc, key):
    ti = tf.gettarinfo(str(path), arcname=arc)
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = 'root'
    ti.mode = 0o755 if (ti.isdir() or key in EXEC) else 0o644
    if ti.isdir():
        tf.addfile(ti)
    else:
        with open(path, 'rb') as fh:
            tf.addfile(ti, fh)


def build_data():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as tf:
        add(tf, ROOT, '.', '.')
        for dirpath, dirs, files in os.walk(ROOT):
            dirs.sort()
            files.sort()
            for name in dirs + files:
                p = pathlib.Path(dirpath) / name
                key = str(p.relative_to(ROOT))
                add(tf, p, './' + key, key)
    with open(WORK / 'data.tar.xz', 'wb') as fh:
        import lzma
        fh.write(lzma.compress(buf.getvalue(), preset=6))


def build_control():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as tf:
        for name in ('control', 'postinst', 'prerm'):
            p = CTL / name
            ti = tarfile.TarInfo(name)
            ti.size = p.stat().st_size
            ti.mode = 0o755 if name != 'control' else 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            tf.addfile(ti, open(p, 'rb'))
    with open(WORK / 'control.tar.gz', 'wb') as rawf:
        f = gzip.GzipFile(fileobj=rawf, mode='wb', mtime=0)
        f.write(buf.getvalue())
        f.close()


def main():
    build_data()
    build_control()
    (WORK / 'debian-binary').write_text('2.0\n')
    if OUT.exists():
        OUT.unlink()
    subprocess.run(['ar', 'rc', str(OUT), str(WORK / 'debian-binary'),
                    str(WORK / 'control.tar.gz'), str(WORK / 'data.tar.xz')], check=True)
    subprocess.run(['dpkg-deb', '-c', str(OUT)], check=True)
    subprocess.run(['dpkg-deb', '-f', str(OUT), 'Package', 'Version', 'Architecture'], check=True)
    print(OUT)


if __name__ == '__main__':
    main()
