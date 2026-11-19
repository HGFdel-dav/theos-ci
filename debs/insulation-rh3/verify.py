#!/usr/bin/env python3
"""Verify a rebuilt DEB: paths, version, modes, and every code-signature page.
Usage: verify.py <deb> <scheme>

rh6 adds exactly one payload item to the rh5 package:
  Library/MobileSubstrate/DynamicLibraries/InsulationDisplay.dylib (+ .plist)
It is checked here for presence, mode, a thermalmonitord-only filter, both
arm64e and arm64 slices, and a valid per-page code signature -- using
debs/insulation/verify_sig.py, the same checker the core dylib is held to.
The rh5 core payload is verified exactly as before: unchanged file hashes,
UUIDs, patch bytes, the 600 backlight floor, and page hashes.
"""
import sys,pathlib,subprocess,tempfile,struct,hashlib,json,os,plistlib
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from objc_abi import MachO
EXPECT_CORE=json.loads((HERE/'expected.json').read_text())
VERSION='0.1.38.1-rh6'
DISPLAY='InsulationDisplay'
DYLIB_DIR='Library/MobileSubstrate/DynamicLibraries'
VERIFY_SIG=HERE.parent/'insulation'/'verify_sig.py'
# The 18-entry patch table is a hard constraint: pin the file so any edit to
# patch_scalar_abi.py (especially the 600 backlight floor or the core UUIDs the
# display library gates on) fails verification instead of shipping silently.
PATCH_TABLE_SHA256='3f5a477c9548d2e4339809fd6f4c93a39ba48fe448f9db1431915947601eb0f8'

def run(*a):
 r=subprocess.run(a,capture_output=True,text=True)
 assert r.returncode==0,f'{a}: {r.stderr}'
 return r.stdout

def pages(thin,arch):
 m=MachO.__new__(MachO)
 # MachO on a thin file: wrap so slices() sees one arch is unnecessary.
 b=thin
 assert struct.unpack_from('<I',b)[0]==0xfeedfacf
 p=32;cd=None
 for _ in range(struct.unpack_from('<I',b,16)[0]):
  c,z=struct.unpack_from('<II',b,p)
  if c==0x1d:cd=p
  p+=z
 assert cd,'missing signature'
 so=struct.unpack_from('<I',b,cd+8)[0]
 magic,length,count=struct.unpack_from('>III',b,so)
 assert b[so:so+4]==bytes.fromhex('fade0cc0'),(arch,'bad SuperBlob magic')
 for j in range(count):
  t,o=struct.unpack_from('>II',b,so+12+8*j)
  if t==0:break
 else:raise AssertionError((arch,'no CodeDirectory in SuperBlob'))
 cd=so+o
 magic,length,version,flags,ho,io,ns,nc,cl=struct.unpack_from('>9I',b,cd)
 hs,ht=b[cd+36],b[cd+37]
 assert b[cd:cd+4]==bytes.fromhex('fade0c02'),(arch,'bad CodeDirectory magic')
 ps=b[cd+39];size=1<<ps
 assert cl==so,(arch,'codeLimit must equal signature offset')
 for i in range(nc):
  start=i*size;end=min(start+size,cl)
  want=b[cd+ho+i*hs:cd+ho+(i+1)*hs]
  h={1:hashlib.sha1,2:hashlib.sha256,3:hashlib.sha256}[ht]
  assert h(thin[start:end]).digest()==want,(arch,'page',i)
 return nc,ht

def fat_slices(blob):
 """Split a fat Mach-O into {arch: thin bytes}; only arm64/arm64e accepted."""
 assert blob[:4]==b'\xca\xfe\xba\xbe','not a fat Mach-O'
 n=struct.unpack_from('>I',blob,4)[0]
 assert 0<n<=8,'bad fat arch count'
 out={}
 for i in range(n):
  ct,cs,off,size,al=struct.unpack_from('>IIIII',blob,8+20*i)
  assert ct&0xffffff==12,'not an arm64 cputype'
  sub=cs&0xffffff
  name={2:'arm64e',0:'arm64'}.get(sub)
  assert name,'unexpected cpusubtype %#x'%sub
  assert name not in out,'duplicate %s slice'%name
  assert off+size<=len(blob),'slice out of bounds'
  out[name]=blob[off:off+size]
 return out

def check_display(root):
 """rh6: the extra output-layer library and its thermalmonitord-only filter."""
 dylib=root/DYLIB_DIR/f'{DISPLAY}.dylib'
 plist=root/DYLIB_DIR/f'{DISPLAY}.plist'
 assert dylib.is_file() and not dylib.is_symlink(),'display dylib missing'
 assert plist.is_file() and not plist.is_symlink(),'display plist missing'
 assert dylib.stat().st_mode&0o777==0o755,'display dylib mode %o'%(dylib.stat().st_mode&0o777)
 assert plist.stat().st_mode&0o777==0o644,'display plist mode %o'%(plist.stat().st_mode&0o777)
 try:
  filt=(plistlib.loads(plist.read_bytes()) or {}).get('Filter') or {}
 except Exception as e:
  raise AssertionError('display plist unparsable: %r'%e)
 assert filt.get('Executables')==['thermalmonitord'],'filter must be thermalmonitord only'
 assert 'Bundles' not in filt,'filter must not target bundles'
 blob=dylib.read_bytes()
 assert b'InsulationDisplay' in blob,'marker string missing'
 assert b'InsulationThermalDimmingBypassActive' in blob,'core switch symbol missing'
 assert b'setBrightnessKey:value:' in blob,'hooked selector missing'
 assert b'defaultAction' not in blob,'must not hook defaultAction'
 slices=fat_slices(blob)
 assert set(slices)=={'arm64','arm64e'},'display archs %s'%sorted(slices)
 for arch in ('arm64','arm64e'):
  assert struct.unpack_from('<I',slices[arch])[0]==0xfeedfacf,arch+' not Mach-O64'
 # same checker the core dylib uses (structure + every CD page hash)
 r=subprocess.run([sys.executable,str(VERIFY_SIG),str(dylib)],capture_output=True,text=True)
 assert r.returncode==0,'verify_sig.py rejected the display dylib\n'+r.stdout+r.stderr
 print(r.stdout.strip())
 return {'path':str(dylib.relative_to(root)),
         'sha256':hashlib.sha256(blob).hexdigest(),
         'plist_sha256':hashlib.sha256(plist.read_bytes()).hexdigest(),
         'archs':sorted(slices),
         'filter':filt.get('Executables')}

def main():
 deb,scheme=pathlib.Path(sys.argv[1]),sys.argv[2]
 assert scheme in ('roothide','rootless')
 want=EXPECT_CORE.get('deb_sha256',{}).get(scheme)
 if want:assert hashlib.sha256(deb.read_bytes()).hexdigest()==want,'deb sha'
 assert hashlib.sha256((HERE/'patch_scalar_abi.py').read_bytes()).hexdigest()==PATCH_TABLE_SHA256,'patch table changed'
 tmp=pathlib.Path(tempfile.mkdtemp(prefix='ins-verify-'))
 run('dpkg-deb','-e',str(deb),str(tmp/'DEBIAN'));run('dpkg-deb','-x',str(deb),str(tmp))
 ctl=(tmp/'DEBIAN/control').read_text()
 assert f'Version: {VERSION}' in ctl,'control version is not '+VERSION
 assert f"Architecture: {'iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64'}" in ctl
 root=tmp/'var/jb' if scheme=='rootless' else tmp
 assert not (tmp/'root').exists() and not (tmp/'tmp').exists(),'stray files'
 if scheme=='rootless':assert not (tmp/'Library').exists(),'rootless payload leaked outside /var/jb'
 for rel,info in EXPECT_CORE['files'].items():
  p=root/rel;assert p.is_file() and not p.is_symlink(),rel
  assert hashlib.sha256(p.read_bytes()).hexdigest()==info['sha256'],'changed '+rel
  assert p.stat().st_mode&0o777==info['mode'],'mode '+rel
 assert (root/'usr/bin/ins').is_symlink() and os.readlink(root/'usr/bin/ins')=='insulationctl'
 core=root/DYLIB_DIR/'insulation.dylib'
 wantc=EXPECT_CORE.get('core_signed_sha256',{}).get(scheme)
 if wantc:assert hashlib.sha256(core.read_bytes()).hexdigest()==wantc,'signed core sha'
 for arch in ('arm64','arm64e'):
  m=MachO(str(core),arch)
  assert m.uuid==EXPECT_CORE['uuid'][arch],arch+' uuid'
  for a in EXPECT_CORE['patch_addr'][arch]:
   assert m.raw(a,4)==bytes.fromhex('1f2003d5'),f'{arch} NOP at {a:#x}'
  assert m.raw(EXPECT_CORE['ret_addr'][arch],4)==bytes.fromhex('c0035fd6'),arch+' RET'
  f=EXPECT_CORE['floor_addr'][arch]
  assert m.raw(f,4)==bytes.fromhex('004b8052'),arch+' floor 600'
  assert m.raw(f+4,4)==bytes.fromhex('1f2003d5'),arch+' floor high half NOP'
  for a in EXPECT_CORE['tsf_addr'][arch]:
   assert m.raw(a,4)==bytes.fromhex('1f2003d5'),f'{arch} stock-key NOP at {a:#x}'
  n,h=pages(m.b,arch);print(arch,'signature pages',n,'hashType',h)
 for f in ('DEBIAN/postinst',):
  assert (tmp/f).stat().st_mode&0o777==0o755
 assert not any(p.name.endswith('.part') for p in tmp.rglob('*'))
 display=check_display(root)
 print(json.dumps({'ok':True,'scheme':scheme,'version':VERSION,
                   'sha256':hashlib.sha256(deb.read_bytes()).hexdigest(),
                   'display':display}))
if __name__=='__main__':main()
