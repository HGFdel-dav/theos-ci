#!/usr/bin/env python3
"""Static package integrity checks, not AMFI/kernel acceptance or runtime proof."""
from pathlib import Path
import sys,struct,hashlib,subprocess,json,plistlib

def u32(b,p,end='<'):return struct.unpack_from(end+'I',b,p)[0]
def slices(b):
 magic=b[:4]
 if magic==b'\xca\xfe\xba\xbe':
  n=u32(b,4,'>');assert 0<n<8
  out=[]
  for i in range(n):
   cpu,sub,off,size,align=struct.unpack_from('>IIIII',b,8+20*i)
   assert off+size<=len(b);out.append((sub&0xffffff,b[off:off+size]))
  return out
 assert magic==b'\xcf\xfa\xed\xfe','expected little-endian Mach-O64 or fat'
 return [(u32(b,8)&0xffffff,b)]

def verify_bin(path):
 arches=[]
 for sub,b in slices(path.read_bytes()):
  assert b[:4]==b'\xcf\xfa\xed\xfe';assert u32(b,4)==0x100000c
  arch={0:'arm64',2:'arm64e'}.get(sub)
  assert arch;arches.append(arch)
  nc=u32(b,16);pos=32;sig=None;deps=[]
  for _ in range(nc):
   cmd,size=struct.unpack_from('<II',b,pos);assert size>=8 and pos+size<=len(b)
   if cmd==0x1d:sig=struct.unpack_from('<II',b,pos+8)
   if cmd in (0xc,0x80000018,0x8000001f):
    o=u32(b,pos+8);deps.append(b[pos+o:pos+size].split(b'\0')[0].decode())
   pos+=size
  assert sig,'missing code signature'
  off,size=sig;blob=b[off:off+size]
  magic,length,count=struct.unpack_from('>III',blob);assert magic==0xfade0cc0 and length<=len(blob)
  cdtypes=[];pages=0
  for i in range(count):
   slot,offset=struct.unpack_from('>II',blob,12+i*8)
   if slot!=0 and not 0x1000<=slot<0x2000:continue
   assert u32(blob,offset,'>')==0xfade0c02
   cdlen=u32(blob,offset+4,'>');cd=blob[offset:offset+cdlen]
   version,flags,hashoff,ident,ns,ncode,limit=struct.unpack_from('>7I',cd,8)
   hs,ht,platform,ps=struct.unpack_from('4B',cd,36)
   if version>=0x20300 and limit==0xffffffff:limit=struct.unpack_from('>Q',cd,56)[0]
   hasher={1:hashlib.sha1,2:hashlib.sha256,3:hashlib.sha256}.get(ht)
   assert hasher and 0<hs<=hasher().digest_size and ps<=20
   page=1<<ps if ps else limit
   assert limit<=off and (ncode==(limit+page-1)//page if page else ncode==0)
   assert hashoff+ncode*hs<=len(cd)
   for k in range(ncode):
    want=cd[hashoff+k*hs:hashoff+(k+1)*hs]
    actual=hasher(b[k*page:min((k+1)*page,limit)]).digest()[:hs]
    assert actual==want,f'{path.name} {arch} signature page {k} mismatch'
   cdtypes.append(ht);pages=max(pages,ncode)
  assert 2 in cdtypes,'SHA256 CodeDirectory required'
  print(f'PASS {path.name} {arch} signature pages={pages} types={cdtypes}')
  for dep in deps:
   assert not dep.startswith('/Users/') and 'iPhoneOS16' not in dep
 assert set(arches)=={'arm64','arm64e'},f'missing slices: {arches}'
 return arches

def verify_deb(deb,out):
 pkg,version,arch=subprocess.check_output(['dpkg-deb','-f',str(deb),'Package','Version','Architecture'],text=True).splitlines()
 # dpkg-deb prefixes field labels when multiple fields were requested.
 vals=[x.split(': ',1)[-1] for x in (pkg,version,arch)];pkg,version,arch=vals
 assert pkg=='com.niubiprass.particlex' and version=='0.1.0dev1'
 assert arch in ('iphoneos-arm64e','iphoneos-arm64')
 target=out/arch;target.mkdir(parents=True,exist_ok=True)
 payload=target/'payload';control=target/'control'
 subprocess.run(['dpkg-deb','-x',str(deb),str(payload)],check=True)
 subprocess.run(['dpkg-deb','-e',str(deb),str(control)],check=True)
 files=sorted(p.relative_to(payload).as_posix() for p in payload.rglob('*') if p.is_file())
 prefix='' if arch=='iphoneos-arm64e' else 'var/jb/'
 assert all(x.startswith(prefix+'Library/') for x in files),files
 for script in ('preinst','postinst','prerm','postrm'):
  assert not (control/script).exists(),'unexpected maintainer script; must inspect before release'
 f=payload/(prefix+'Library/MobileSubstrate/DynamicLibraries/ParticleX.plist')
 assert plistlib.loads(f.read_bytes())=={'Filter':{'Bundles':['com.apple.springboard']}}
 for binary in [payload/(prefix+'Library/MobileSubstrate/DynamicLibraries/ParticleX.dylib'),payload/(prefix+'Library/PreferenceBundles/ParticleXPrefs.bundle/ParticleXPrefs')]:verify_bin(binary)
 (target/'payload-list.txt').write_text('\n'.join(files)+'\n')
 print('PASS package',pkg,version,arch,'files',len(files),'no maintainer scripts')
 return {'package':pkg,'version':version,'architecture':arch,'files':len(files),'sha256':hashlib.sha256(deb.read_bytes()).hexdigest()}
if __name__=='__main__':
 out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
 rows=[verify_deb(Path(x),out) for x in sys.argv[2:]]
 assert rows,'no DEB supplied'
 (out/'verification.json').write_text(json.dumps(rows,indent=2))
