#!/usr/bin/env python3
"""Rebuild an installable DEB from the pinned 0.1.38.1 baseline.

Usage: build.py <baseline.deb> <scheme: roothide|rootless> <out.deb>

rh6 payload = the rh5 payload plus one extra library:

  1. insulation.dylib keeps the frozen 18-entry patch set from
     patch_scalar_abi.py. This script never edits that table: the backlight
     power floor stays 600 (movz w0,#600) and the core keeps the rh5 UUIDs
     (arm64e b05c6dcc-1c2f-52c6-8c43-600f34f52d0e). That UUID is what the new
     library gates on, so rh6 and rh5 must ship the same core bytes.
  2. InsulationDisplay.dylib is compiled here from <repo>/src for arm64e and
     arm64, lipo'ed into one fat dylib, signed with ldid and page-verified by
     debs/insulation/verify_sig.py -- the same checker the core dylib uses.
     It ships with InsulationDisplay.plist, a MobileSubstrate filter whose
     Executables list is exactly ['thermalmonitord'].

Needs macOS with the Xcode iphoneos SDK (xcrun clang / lipo) plus dpkg-deb and
ldid. No phone operations.
"""
import sys,pathlib,subprocess,tempfile,shutil,os,hashlib,json
BASE_SHA='75d9920232145bae39c8a3217091e8cb3dec60d0074df265fbfa86a7d44e19c9'
VERSION='0.1.38.1-rh6'
DISPLAY='InsulationDisplay'
DYLIB_DIR='Library/MobileSubstrate/DynamicLibraries'
ARCHS=('arm64','arm64e')
HERE=pathlib.Path(__file__).resolve().parent
REPO=HERE.parents[1]
SRC=REPO/'src'/'ISDisplayRuntime.m'
PLIST=HERE/f'{DISPLAY}.plist'
VERIFY_SIG=REPO/'debs'/'insulation'/'verify_sig.py'

def run(*a,**kw):
 r=subprocess.run(a,capture_output=True,text=True,**kw)
 if r.returncode:raise SystemExit(f'FAIL {a[0]}: {r.stdout}{r.stderr}')
 return r

def sign_display(fat):
 """ldid -S, then let the existing checker decide if the result is loadable.

 Same standard as debs/insulation/build.sh: iOS 15 arm64e needs a SHA256
 CodeDirectory, and every page hash must match the bytes we are about to ship.
 """
 last=''
 for flags in (['-Hsha256'],[]):
  # A ldid build without -H support must not abort the run: sign, then let the
  # checker below decide. Same tolerance as debs/insulation/build.sh.
  subprocess.run(['ldid',*flags,'-S',str(fat)],capture_output=True,text=True)
  r=subprocess.run([sys.executable,str(VERIFY_SIG),str(fat)],capture_output=True,text=True)
  last=(r.stdout+r.stderr).strip()
  if r.returncode==0:return last
 raise SystemExit(f'ldid could not produce an iOS 15 loadable signature for {DISPLAY}\n{last}')

def compile_display(tmp):
 """arm64 + arm64e thin dylibs -> one fat dylib -> ldid -> page check.

 Same arch organisation as the core insulation.dylib (one fat file carrying
 both slices), so the deb stays arch-consistent under either scheme.
 """
 for p in (SRC,PLIST,VERIFY_SIG):
  if not p.is_file():raise SystemExit(f'missing build input: {p}')
 thin=[]
 for arch in ARCHS:
  out=tmp/f'{DISPLAY}-{arch}.dylib'
  run('xcrun','--sdk','iphoneos','clang','-arch',arch,
      '-mios-version-min=15.0','-dynamiclib','-fobjc-arc','-fblocks',
      '-I',str(SRC.parent),
      '-install_name',f'/{DYLIB_DIR}/{DISPLAY}.dylib',
      '-framework','Foundation','-o',str(out),str(SRC))
  thin.append(out)
 fat=tmp/f'{DISPLAY}.dylib'
 run('xcrun','lipo','-create',*[str(p) for p in thin],'-output',str(fat))
 report=sign_display(fat)
 return fat,report

def install_display(payload,fat):
 """Add the dylib (0755) and its filter plist (0644) under the payload root.

 Called before the rootless relocation, so the scheme handling below moves them
 into var/jb together with the rest of Library/ -- no hardcoded prefix here.
 """
 target=payload/DYLIB_DIR
 target.mkdir(parents=True,exist_ok=True)
 dylib=target/f'{DISPLAY}.dylib'
 if dylib.exists():raise SystemExit(f'{dylib} already present in baseline payload')
 shutil.copyfile(fat,dylib);dylib.chmod(0o755)
 plist=target/f'{DISPLAY}.plist'
 shutil.copyfile(PLIST,plist);plist.chmod(0o644)
 return dylib,plist

def main():
 base,scheme,out=pathlib.Path(sys.argv[1]),sys.argv[2],pathlib.Path(sys.argv[3])
 assert hashlib.sha256(base.read_bytes()).hexdigest()==BASE_SHA,'baseline hash'
 assert scheme in ('roothide','rootless') and not out.exists()
 work=pathlib.Path(tempfile.mkdtemp(prefix='ins-build-'));payload=work/'payload';tmp=work/'tmp'
 payload.mkdir();tmp.mkdir()
 run('dpkg-deb','-e',str(base),str(payload/'DEBIAN'));run('dpkg-deb','-x',str(base),str(payload))
 core=payload/DYLIB_DIR/'insulation.dylib'
 patched=tmp/'patched.dylib'
 run(sys.executable,str(HERE/'patch_scalar_abi.py'),str(core),str(patched),'--manifest',str(tmp/'patch.json'))
 if hashlib.sha256(patched.read_bytes()).hexdigest()!=json.loads((tmp/'patch.json').read_text())['unsigned_sha256']:
  raise SystemExit('patch-manifest mismatch')
 core.write_bytes(patched.read_bytes())
 run('ldid','-S',str(core))
 fat,sig=compile_display(tmp)
 dylib,plist=install_display(payload,fat)
 ctl=payload/'DEBIAN';ctext=(ctl/'control').read_text()
 def setfield(text,key,value):
  lines=[l for l in text.splitlines() if not l.lower().startswith(key.lower()+':')]
  return '\n'.join(lines+[f'{key}: {value}'])+'\n'
 (ctl/'control').write_text(setfield(setfield(ctext,'Version',VERSION),'Architecture','iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64'))
 if scheme=='rootless':
  jb=payload/'var/jb';jb.mkdir(parents=True)
  for name in ('Library','usr'):shutil.move(str(payload/name),str(jb/name))
 final=payload/'var/jb' if scheme=='rootless' else payload
 meta=json.loads((HERE/'payload-metadata.json').read_text())
 for rel,info in meta['files'].items():(final/rel).chmod(info['mode'])
 (final/meta['core']['path']).chmod(meta['core']['mode'])
 os.chmod(ctl/'postinst',0o755);os.chmod(ctl/'control',0o644)
 run('dpkg-deb','--root-owner-group','-b',str(payload),str(out))
 print(json.dumps({'scheme':scheme,'version':VERSION,'out':str(out),
  'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),
  'core_sha256':hashlib.sha256(core.read_bytes()).hexdigest(),
  'display':{'install_path':str((final/DYLIB_DIR/f'{DISPLAY}.dylib').relative_to(payload)),
             'dylib_sha256':hashlib.sha256(dylib.read_bytes()).hexdigest(),
             'plist_sha256':hashlib.sha256(plist.read_bytes()).hexdigest(),
             'signature':sig}},indent=2))
if __name__=='__main__':main()
