#!/usr/bin/env python3
"""Executable model tests, NOT execution of the Objective-C path resolver."""
from pathlib import Path
import os, plistlib, tempfile
checks=0
def need(ok):
    global checks
    assert ok
    checks+=1
def score(root):
    for n,p in ((3,'Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib'),(3,'var/mobile/Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib'),(2,'Library/MobileSubstrate'),(2,'var/mobile/Library/MobileSubstrate'),(1,'usr/lib')):
        if (root/p).exists():return n
    return 0
def select(roots,loaded=None,rootless=None):
    if loaded and score(loaded)>0:return loaded
    ordered=sorted((r for r in roots if r.is_dir() and not r.is_symlink()),key=lambda r:(-score(r),-r.stat().st_mtime_ns,str(r)))
    if ordered and score(ordered[0])>0:return ordered[0]
    return rootless if rootless and rootless.is_dir() else None
def derive_root(mapped_pref):
    suffix='/var/mobile/Library/Preferences/com.local.cleanstatus.plist'
    if not mapped_pref.endswith(suffix):return None
    prefix=mapped_pref[:-len(suffix)]
    return Path(prefix).resolve() if prefix else Path('/')
def contained(path,root):
    try:path.resolve().relative_to(root.resolve());return path.resolve()!=root.resolve()
    except ValueError:return False
def read(path):
    if path.is_symlink() or not path.is_file() or not 0<path.stat().st_size<=65536:return None
    try:value=plistlib.loads(path.read_bytes())
    except Exception:return None
    return value if isinstance(value,dict) else None
def migrate(target,candidates,fail=False,changed=None):
    rows=[(p,p.stat().st_mtime_ns,read(p)) for p in set(candidates+[target]) if read(p) is not None]
    if not rows:return True
    winner=max(rows,key=lambda row:(row[1],row[0]==target))
    if winner[0]!=target:
        if fail:return False
        target.parent.mkdir(parents=True,exist_ok=True)
        temp=target.with_suffix('.tmp');temp.write_bytes(plistlib.dumps(winner[2]));temp.replace(target)
    if read(target)!=winner[2]:return False
    result=True
    for p,mtime,value in rows:
        if p==target:continue
        if changed and p==changed:
            p.write_bytes(plistlib.dumps({'enabled':False,'hideVPN':True}))
        if read(p)!=value or p.stat().st_mtime_ns!=mtime:result=False;continue
        p.unlink()
    return result
with tempfile.TemporaryDirectory(prefix='lcs-path-model-') as temp:
    base=Path(temp);a=base/'.jbroot-A';b=base/'.jbroot-B';c=base/'.jbroot-C';fallback=base/'var/jb'
    for r in (a,b,c):r.mkdir()
    app_group=base/'var/mobile/Containers/Shared/AppGroup'; active=app_group/'.jbroot-A'
    active.mkdir(parents=True)
    mapped=str(active/'var/mobile/Library/Preferences/com.local.cleanstatus.plist')
    need(derive_root(mapped)==active.resolve())
    need(derive_root('/var/mobile/Library/Preferences/com.local.cleanstatus.plist')==Path('/'))
    need(contained(Path('/var/mobile/Library/Preferences/com.local.cleanstatus.plist'),Path('/')))
    need(derive_root('/var/mobile/other.plist') is None)
    need(select([a,b,c]) is None)
    (c/'usr/lib').mkdir(parents=True);need(select([a,b,c])==c)
    (b/'Library/MobileSubstrate').mkdir(parents=True);need(select([a,b,c])==b)
    (a/'Library/MobileSubstrate/DynamicLibraries').mkdir(parents=True)
    (a/'Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib').write_bytes(b'fixture')
    need(select([a,b,c])==a);need(select([a,b,c],loaded=c)==c)
    (b/'Library/MobileSubstrate/DynamicLibraries').mkdir()
    (b/'Library/MobileSubstrate/DynamicLibraries/LocalCleanStatus.dylib').write_bytes(b'fixture')
    os.utime(a,ns=(100,100));os.utime(b,ns=(200,200));need(select([a,b])==b)
    need(select([a,b],loaded=a)==a)
    fallback.mkdir(parents=True);need(select([],rootless=fallback)==fallback)
    need(select([]) is None)
    alias=base/'.jbroot-link';alias.symlink_to(a,target_is_directory=True)
    need(select([alias]) is None)
    good=a/'var/mobile/Library/Preferences/com.local.cleanstatus.plist'
    need(contained(good,a));need(not contained(base/'real/var/mobile/prefs.plist',a))
    outside=base/'outside';outside.mkdir();(a/'escape').symlink_to(outside,target_is_directory=True)
    need(not contained(a/'escape/prefs.plist',a))
    good.parent.mkdir(parents=True)
    legacy=base/'legacy.plist';bad=base/'bad.plist'
    bad.write_text('not plist');need(read(bad) is None)
    target_value={'enabled':False};old_value={'enabled':True,'hideLocation':True}
    good.write_bytes(plistlib.dumps(target_value));legacy.write_bytes(plistlib.dumps(old_value))
    os.utime(good,ns=(100,100));os.utime(legacy,ns=(200,200))
    need(not migrate(good,[legacy,bad],fail=True));need(legacy.exists());need(read(good)==target_value)
    need(migrate(good,[legacy,bad]));need(read(good)==old_value);need(not legacy.exists());need(bad.exists())
    legacy.write_bytes(plistlib.dumps(target_value));os.utime(legacy,ns=(50,50))
    need(migrate(good,[legacy]));need(read(good)==old_value);need(not legacy.exists())
    legacy.write_bytes(plistlib.dumps(target_value));os.utime(legacy,ns=(500,500));os.utime(good,ns=(500,500))
    need(migrate(good,[legacy]));need(read(good)==old_value)
    legacy.write_bytes(plistlib.dumps(target_value));os.utime(legacy,ns=(1000,1000));os.utime(good,ns=(500,500))
    need(not migrate(good,[legacy],changed=legacy));need(legacy.exists());need(read(legacy)['hideVPN'] is True)
print(f'PASS path/migration model: {checks} cases. Objective-C filesystem behavior remains unverified.')
