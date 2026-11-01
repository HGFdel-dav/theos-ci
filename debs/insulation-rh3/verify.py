#!/usr/bin/env python3
"""Verify a rebuilt DEB: paths, version, modes, and every code-signature page.
Usage: verify.py <deb> <scheme>
"""
import sys,pathlib,subprocess,tempfile,struct,hashlib,json,os
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from objc_abi import MachO
EXPECT_CORE=json.loads((HERE/'expected.json').read_text())

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

def main():
 deb,scheme=pathlib.Path(sys.argv[1]),sys.argv[2]
 assert scheme in ('roothide','rootless')
 want=EXPECT_CORE.get('deb_sha256',{}).get(scheme)
 if want:assert hashlib.sha256(deb.read_bytes()).hexdigest()==want,'deb sha'
 tmp=pathlib.Path(tempfile.mkdtemp(prefix='ins-verify-'))
 run('dpkg-deb','-e',str(deb),str(tmp/'DEBIAN'));run('dpkg-deb','-x',str(deb),str(tmp))
 ctl=(tmp/'DEBIAN/control').read_text()
 assert 'Version: 0.1.38.1-rh3' in ctl
 assert f"Architecture: {'iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64'}" in ctl
 root=tmp/'var/jb' if scheme=='rootless' else tmp
 assert not (tmp/'root').exists() and not (tmp/'tmp').exists(),'stray files'
 if scheme=='rootless':assert not (tmp/'Library').exists(),'rootless payload leaked outside /var/jb'
 for rel,info in EXPECT_CORE['files'].items():
  p=root/rel;assert p.is_file() and not p.is_symlink(),rel
  assert hashlib.sha256(p.read_bytes()).hexdigest()==info['sha256'],'changed '+rel
  assert p.stat().st_mode&0o777==info['mode'],'mode '+rel
 assert (root/'usr/bin/ins').is_symlink() and os.readlink(root/'usr/bin/ins')=='insulationctl'
 core=root/'Library/MobileSubstrate/DynamicLibraries/insulation.dylib'
 assert hashlib.sha256(core.read_bytes()).hexdigest()==EXPECT_CORE['core_signed_sha256'][scheme]
 for arch in ('arm64','arm64e'):
  m=MachO(str(core),arch)
  assert m.uuid==EXPECT_CORE['uuid'][arch],arch+' uuid'
  for a in EXPECT_CORE['patch_addr'][arch]:
   assert m.raw(a,4)==bytes.fromhex('1f2003d5'),f'{arch} NOP at {a:#x}'
  assert m.raw(EXPECT_CORE['ret_addr'][arch],4)==bytes.fromhex('c0035fd6'),arch+' RET'
  f=EXPECT_CORE['floor_addr'][arch]
  assert m.raw(f,4)==bytes.fromhex('004b8052'),arch+' floor 600'
  assert m.raw(f+4,4)==bytes.fromhex('1f2003d5'),arch+' floor high half NOP'
  n,h=pages(m.b,arch);print(arch,'signature pages',n,'hashType',h)
 for f in ('DEBIAN/postinst',):
  assert (tmp/f).stat().st_mode&0o777==0o755
 assert not any(p.name.endswith('.part') for p in tmp.rglob('*'))
 print(json.dumps({'ok':True,'scheme':scheme,'sha256':hashlib.sha256(deb.read_bytes()).hexdigest()}))
if __name__=='__main__':main()
