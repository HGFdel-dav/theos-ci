#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Future approved CI only. Builds two clean packages, then hard-requires both.
No workflow, install, service load or respring operation is performed here.
"""
from pathlib import Path
import argparse,hashlib,json,os,plistlib,re,shutil,subprocess,sys,tempfile
if not __debug__:sys.exit('REFUSED: Python assertion checks must not be disabled')

def identity(root):
 fields=dict(line.split(':',1) for line in (root/'control').read_text().splitlines() if ':' in line)
 package=fields.get('Package','').strip();version=fields.get('Version','').strip()
 assert re.fullmatch(r'[a-z0-9][a-z0-9+.-]+',package),'final package identity required'
 assert version and not any(x in (package+' '+version).lower() for x in ['local-candidate','source-only','placeholder']),'parent must finalize service control/version before release build'
 return package,version

def verify_filter(source_bytes,packaged_bytes,dylib):
 # Theos emits binary/XML plists from these two pinned OpenStep source files.
 # Do not parse an arbitrary source dialect or accept a broader injection scope.
 expected={
  'MiniSight':(b'{ Filter = { Bundles = ( "com.apple.springboard" ); }; }',
               {'Filter':{'Bundles':['com.apple.springboard']}}),
  'MiniSightRhythmService':(b'Filter = { Executables = ("mediaserverd"); };',
               {'Filter':{'Executables':['mediaserverd']}})}
 assert dylib in expected,'unknown injection target'
 source,scope=expected[dylib]
 assert source_bytes.strip()==source,'source filter scope changed'
 try:actual=plistlib.loads(packaged_bytes)
 except Exception as error:raise AssertionError('invalid packaged filter plist') from error
 assert actual==scope,'packaged filter scope changed'


def verify_deb(deb,root,dylib,scheme,expected_identity):
 arch='iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64'
 cpu='arm64e' if scheme=='roothide' else 'arm64'
 prefix='' if scheme=='roothide' else 'var/jb/'
 architecture=subprocess.check_output(['dpkg-deb','-f',str(deb),'Architecture'],text=True).strip()
 assert architecture==arch,(architecture,arch)
 for key,want in zip(['Package','Version'],expected_identity):
  assert subprocess.check_output(['dpkg-deb','-f',str(deb),key],text=True).strip()==want,key
 with tempfile.TemporaryDirectory() as td:
  subprocess.run(['dpkg-deb','-x',str(deb),td],check=True)
  tree=Path(td);payload=tree/(prefix+'Library/MobileSubstrate/DynamicLibraries')
  binary=payload/(dylib+'.dylib');filter_file=payload/(dylib+'.plist')
  assert binary.is_file() and not binary.is_symlink(),'required native payload/layout missing'
  assert filter_file.is_file() and not filter_file.is_symlink(),'required filter/layout missing'
  verify_filter((root/(dylib+'.plist')).read_bytes(),filter_file.read_bytes(),dylib)
  assert len(list(tree.rglob(dylib+'.dylib')))==len(list(tree.rglob(dylib+'.plist')))==1,'duplicate payload'
  if scheme=='roothide': assert not (tree/'var/jb').exists(),'RootHide must not use rootless layout'
  actual_cpu=subprocess.check_output(['xcrun','lipo','-archs',str(binary)],text=True).strip()
  assert actual_cpu==cpu,('native slice',actual_cpu,cpu)
  load=subprocess.check_output(['xcrun','otool','-l',str(binary)],text=True)
  assert 'LC_BUILD_VERSION' in load and re.search(r'\bsdk\s+15\.5(?:\.0)?\s',load),'native SDK15.5 required'
  minimum=re.findall(r'\bminos\s+(\d+)\.(\d+)',load)
  assert minimum and all((int(ma),int(mi))<=(15,5) for ma,mi in minimum),'deployment exceeds iOS15.5'
 return architecture,cpu

p=argparse.ArgumentParser();p.add_argument('--service',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--mode',choices=['LIVE'],required=True);p.add_argument('--scheme',choices=['roothide','rootless'],required=True);p.add_argument('--build',action='store_true');a=p.parse_args()
if not (a.build and os.environ.get('CI')=='true' and os.environ.get('MINISIGHT_RHYTHM_CI_BUILD_APPROVED')=='1'):
 sys.exit('REFUSED: future CI plus explicit MINISIGHT_RHYTHM_CI_BUILD_APPROVED=1 required; local source-only scope')
s=a.service.resolve();plugin=s.parent/'MiniSight';out=a.output.resolve()
assert a.output.is_absolute() and not a.output.is_symlink(),'explicit absolute fresh non-symlink output directory required'
assert not out.exists(),'refuse stale artifacts/output directory'
for root in [s,plugin]:assert (root/'Makefile').is_file() and (root/'control').is_file(),root
# This gate intentionally blocks today's placeholder; source tests NEVER remove it.
identities={root:identity(root) for root in [s,plugin]}
assert identities[s][0]!=identities[plugin][0],'two distinct required package identities'
subprocess.run([sys.executable,str(s/'scripts/check_contract.py'),'--service',str(s),'--mode','LIVE','--capture','1','--transport','1'],check=True)
out.parent.mkdir(parents=True,exist_ok=True)
staging=Path(tempfile.mkdtemp(prefix='.rhythm-pair-',dir=out.parent));rows=[]
flags=['MINISIGHT_RHYTHM_MODE=LIVE','MINISIGHT_ENABLE_RHYTHM_CAPTURE=1','MINISIGHT_ENABLE_RHYTHM_TRANSPORT=1','MINISIGHT_RHYTHM_LIVE_BUILD=1','THEOS_PACKAGE_SCHEME='+a.scheme,'FINALPACKAGE=1']
try:
 for name,root,dylib in [('service',s,'MiniSightRhythmService'),('plugin',plugin,'MiniSight')]:
  dest=staging/name;dest.mkdir()
  # Both clean builds are mandatory; no source0 objects or old DEB globs reused.
  subprocess.run(['make','-C',str(root),'clean',*flags],check=True)
  subprocess.run(['make','-C',str(root),'package',*flags,'THEOS_PACKAGE_DIR='+str(dest)],check=True)
  packages=list(dest.glob('*.deb'));assert len(packages)==1,f'{name}: exactly one fresh DEB required'
  deb=packages[0];assert deb.is_file() and not deb.is_symlink() and deb.stat().st_size>0,'empty or symlink artifact'
  architecture,cpu=verify_deb(deb,root,dylib,a.scheme,identities[root])
  rows.append({'role':name,'path':str(deb.relative_to(staging)),'sha256':hashlib.sha256(deb.read_bytes()).hexdigest(),'bytes':deb.stat().st_size,'architecture':architecture,'native_slice':cpu,'package':identities[root][0],'version':identities[root][1],'native_checked':True})
 assert {x['role'] for x in rows}=={'service','plugin'},'BOTH required, never continue-on-error'
 (staging/'PAIR-ARTIFACTS.json').write_text(json.dumps({'mode':'LIVE','scheme':a.scheme,'capture':1,'transport':1,'live_build':1,'source_manifest_sha256':hashlib.sha256((s/'MANIFEST.json').read_bytes()).hexdigest(),'required':rows,'device_validated':False},indent=2)+'\n')
 (staging/'SHA256SUMS').write_text(''.join(x['sha256']+'  '+x['path']+'\n' for x in rows))
 assert not out.exists(),'refuse raced/stale output'
 staging.rename(out) # No uploadable output exists until BOTH native payloads pass.
finally:
 if staging.exists():shutil.rmtree(staging)
print(json.dumps({'status':'PASS','paired_artifacts_required':True,'scheme':a.scheme,'manifest':str(out/'PAIR-ARTIFACTS.json')}))
