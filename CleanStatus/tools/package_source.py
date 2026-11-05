#!/usr/bin/env python3
from pathlib import Path
import sys, zipfile, hashlib, re
ROOT=Path(__file__).resolve().parents[1]
EXCLUDED={'.git','.theos','packages','out','checks','__pycache__','.DS_Store','.env','.ssh','node_modules'}
SECRET_PATTERN=re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}')
def source_files():
    for p in sorted(ROOT.rglob('*')):
        r=p.relative_to(ROOT)
        if any(x in EXCLUDED for x in r.parts) or p.suffix.lower() in ('.deb','.zip','.pyc','.p12','.mobileprovision','.key'): continue
        if not p.is_file(): continue
        if p.is_symlink(): raise ValueError('Unexpected source symlink: '+str(r))
        data=p.read_bytes()
        if p.suffix in ('.m','.h','.xm','.json','.py','.sh','.yml','.md','.plist') or p.name in ('Makefile','control'):
            s=data.decode('utf-8')
            if SECRET_PATTERN.search(s): raise ValueError('Potential secret: '+str(r))
        yield p,r,data
def package(destination):
    destination=Path(destination); destination.parent.mkdir(parents=True,exist_ok=True)
    files=list(source_files())
    with zipfile.ZipFile(destination,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for p,r,data in files:
            info=zipfile.ZipInfo('CleanStatus-0.1.5/'+r.as_posix(),date_time=(2026,11,4,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=(0o100755 if p.suffix=='.sh' else 0o100644)<<16
            z.writestr(info,data)
    with zipfile.ZipFile(destination) as z:
        assert z.testzip() is None
        for name in z.namelist(): assert not any(part in EXCLUDED for part in Path(name).parts)
    print(f'PASS source archive: {len(files)} files; SHA256 '+hashlib.sha256(destination.read_bytes()).hexdigest())
if __name__=='__main__':
    if len(sys.argv)!=2: raise SystemExit('usage: package_source.py destination.zip')
    package(sys.argv[1])
