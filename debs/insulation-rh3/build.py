#!/usr/bin/env python3
"""Rebuild an installable DEB from the pinned 0.1.38.1 baseline.
Usage: build.py <baseline.deb> <scheme: roothide|rootless> <out.deb>
CI and local use the same script. No phone operations.
"""
import sys,pathlib,subprocess,tempfile,shutil,os,hashlib,json
BASE_SHA='75d9920232145bae39c8a3217091e8cb3dec60d0074df265fbfa86a7d44e19c9'
VERSION='0.1.38.1-rh3'
HERE=pathlib.Path(__file__).resolve().parent

def run(*a,**kw):
 r=subprocess.run(a,capture_output=True,text=True,**kw)
 if r.returncode:raise SystemExit(f'FAIL {a[0]}: {r.stdout}{r.stderr}')
 return r

def main():
 base,scheme,out=pathlib.Path(sys.argv[1]),sys.argv[2],pathlib.Path(sys.argv[3])
 assert hashlib.sha256(base.read_bytes()).hexdigest()==BASE_SHA,'baseline hash'
 assert scheme in ('roothide','rootless') and not out.exists()
 work=pathlib.Path(tempfile.mkdtemp(prefix='ins-build-'));payload=work/'payload';tmp=work/'tmp'
 payload.mkdir();tmp.mkdir()
 run('dpkg-deb','-e',str(base),str(payload/'DEBIAN'));run('dpkg-deb','-x',str(base),str(payload))
 core=payload/'Library/MobileSubstrate/DynamicLibraries/insulation.dylib'
 patched=tmp/'patched.dylib'
 run(sys.executable,str(HERE/'patch_scalar_abi.py'),str(core),str(patched),'--manifest',str(tmp/'patch.json'))
 if hashlib.sha256(patched.read_bytes()).hexdigest()!=json.loads((tmp/'patch.json').read_text())['unsigned_sha256']:
  raise SystemExit('patch-manifest mismatch')
 core.write_bytes(patched.read_bytes())
 run('ldid','-S',str(core))
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
 print(json.dumps({'scheme':scheme,'version':VERSION,'out':str(out),'sha256':hashlib.sha256(out.read_bytes()).hexdigest()},indent=2))
if __name__=='__main__':main()
