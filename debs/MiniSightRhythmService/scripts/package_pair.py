#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Approved CI only: ONE standard Theos aggregate package, TWO native payloads.
Historical entry filename retained; never merges/repackages existing DEBs.
No install, service load, capture or respring operation is performed here.
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


def verify_deb(deb,plugin,service,scheme,expected_identity):
 from macho_audit import audit
 import io,tarfile
 arch='iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64'
 cpu='arm64e' if scheme=='roothide' else 'arm64'
 prefix='' if scheme=='roothide' else 'var/jb/'
 required={'Package':expected_identity[0],'Version':expected_identity[1],
  'Architecture':arch,'Depends':'mobilesubstrate, firmware (>= 15.5)',
  'Provides':'com.niubiprass.minisight.rhythmservice (= 0.1.0)',
  'Conflicts':'com.niubiprass.minisight.rhythmservice',
  'Replaces':'com.niubiprass.minisight.rhythmservice'}
 for key,want in required.items():
  assert subprocess.check_output(['dpkg-deb','-f',str(deb),key],text=True).strip()==want,key
 payload=prefix+'Library/MobileSubstrate/DynamicLibraries/'
 roots={'MiniSight':plugin,'MiniSightRhythmService':service}
 wanted={payload+name+suffix for name in roots for suffix in ['.dylib','.plist']}
 # Audit both archives before extraction: no symlinks, traversal, extra payload,
 # maintainer scripts, set-id bits, or changed permission/ownership encoding.
 for flag in ['--ctrl-tarfile','--fsys-tarfile']:
  raw=subprocess.check_output(['dpkg-deb',flag,str(deb)]);seen=set();files=set()
  with tarfile.open(fileobj=io.BytesIO(raw),mode='r:') as archive:
   for member in archive:
    name=member.name
    while name.startswith('./'):name=name[2:]
    name='' if name=='.' else name.rstrip('/')
    assert not name.startswith('/') and '..' not in Path(name).parts,'unsafe archive path'
    assert name not in seen,'duplicate archive entry'
    seen.add(name)
    assert (member.isdir() or member.isfile()) and not member.linkname,'links/special files forbidden'
    expected_mode=0o755 if member.isdir() or name.endswith('.dylib') else 0o644
    assert member.mode==expected_mode,'payload/control permission changed'
    assert (member.uid,member.gid,member.uname,member.gname) in [(0,0,'root','wheel'),(501,20,'root','wheel')],'unreviewed owner encoding'
    allowed={'control'} if flag=='--ctrl-tarfile' else wanted
    if member.isfile():files.add(name)
    assert name in allowed or not name or (member.isdir() and any(x.startswith(name+'/') for x in allowed)),'unexpected archive entry'
  assert files==({'control'} if flag=='--ctrl-tarfile' else wanted),'incomplete single package'
 rows=[]
 with tempfile.TemporaryDirectory() as td:
  subprocess.run(['dpkg-deb','-x',str(deb),td],check=True)
  tree=Path(td)
  for dylib,root in roots.items():
   binary=tree/(payload+dylib+'.dylib');filter_file=tree/(payload+dylib+'.plist')
   assert binary.is_file() and not binary.is_symlink(),'required native payload/layout missing'
   assert filter_file.is_file() and not filter_file.is_symlink(),'required filter/layout missing'
   verify_filter((root/(dylib+'.plist')).read_bytes(),filter_file.read_bytes(),dylib)
   native=audit(binary,cpu,minimum='15.0.0' if dylib=='MiniSight' else '15.5.0')
   rows.append({'target':dylib,'path':payload+dylib+'.dylib','filter':payload+dylib+'.plist','native_checked':True,'macho':native})
  assert {str(x.relative_to(tree)) for x in tree.rglob('*') if not x.is_dir()}==wanted,'unexpected extracted payload'
 return arch,cpu,rows

p=argparse.ArgumentParser();p.add_argument('--service',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--mode',choices=['LIVE'],required=True);p.add_argument('--scheme',choices=['roothide','rootless'],required=True);p.add_argument('--build',action='store_true');a=p.parse_args()
if not (a.build and os.environ.get('CI')=='true' and os.environ.get('MINISIGHT_RHYTHM_CI_BUILD_APPROVED')=='1'):
 sys.exit('REFUSED: future CI plus explicit MINISIGHT_RHYTHM_CI_BUILD_APPROVED=1 required; local source-only scope')
s=a.service.resolve();plugin=s.parent/'MiniSight';out=a.output.resolve()
sys.path.insert(0,str(Path(__file__).resolve().parent))
assert a.output.is_absolute() and not a.output.is_symlink(),'explicit absolute fresh non-symlink output directory required'
assert not out.exists(),'refuse stale artifacts/output directory'
for root in [s,plugin]:assert (root/'Makefile').is_file() and (root/'control').is_file(),root
expected_identity=identity(plugin)
assert expected_identity==('com.niubiprass.minisight','0.8.58'),'reviewed unified package identity required'
assert identity(s)==('com.niubiprass.minisight.rhythmservice','0.1.0'),'reviewed bundled service identity required'
subprocess.run([sys.executable,str(s/'scripts/check_contract.py'),'--service',str(s),'--mode','LIVE','--capture','1','--transport','1'],check=True)
out.parent.mkdir(parents=True,exist_ok=True)
staging=Path(tempfile.mkdtemp(prefix='.minisight-single-',dir=out.parent))
flags=['MINISIGHT_RHYTHM_MODE=LIVE','MINISIGHT_ENABLE_RHYTHM_CAPTURE=1','MINISIGHT_ENABLE_RHYTHM_TRANSPORT=1','MINISIGHT_RHYTHM_LIVE_BUILD=1','THEOS_PACKAGE_SCHEME='+a.scheme,'FINALPACKAGE=1']
# Cancellation removes private staging and never publishes a partial output.
import signal
def cancelled(signum,frame):raise InterruptedError('single package cancelled')
previous={n:signal.signal(n,cancelled) for n in [signal.SIGINT,signal.SIGTERM]}
try:
 # Official aggregate.mk recurses clean/all/internal-stage into the service;
 # only top-level MiniSight runs package, with one control and shared staging.
 subprocess.run(['make','-C',str(plugin),'clean',*flags],check=True)
 subprocess.run(['make','-C',str(plugin),'package',*flags,'THEOS_PACKAGE_DIR='+str(staging)],check=True)
 packages=list(staging.glob('*.deb'));assert len(packages)==1,'exactly ONE fresh DEB required'
 deb=packages[0];assert deb.is_file() and not deb.is_symlink() and deb.stat().st_size>0,'empty or symlink artifact'
 architecture,cpu,rows=verify_deb(deb,plugin,s,a.scheme,expected_identity)
 assert {x['target'] for x in rows}=={'MiniSight','MiniSightRhythmService'},'BOTH native targets required'
 digest=hashlib.sha256(deb.read_bytes()).hexdigest()
 manifest={'mode':'LIVE','scheme':a.scheme,'capture':1,'transport':1,'live_build':1,'package':expected_identity[0],'version':expected_identity[1],'path':deb.name,'sha256':digest,'bytes':deb.stat().st_size,'architecture':architecture,'native_slice':cpu,'source_manifest_sha256':hashlib.sha256((s/'MANIFEST.json').read_bytes()).hexdigest(),'required':rows,'single_deb':True,'device_validated':False,'ownership_caveat':'Inherited 501:20 root/wheel encoding remains conditional on target name resolution; not device-validated.'}
 (staging/'SINGLE-ARTIFACT.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (staging/'SHA256SUMS').write_text(digest+'  '+deb.name+'\n')
 assert set(x.name for x in staging.iterdir())=={deb.name,'SINGLE-ARTIFACT.json','SHA256SUMS'},'extra build output forbidden'
 assert not out.exists(),'refuse raced/stale output'
 staging.rename(out) # The only public output appears after BOTH native audits.
finally:
 for n,handler in previous.items():signal.signal(n,handler)
 if staging.exists():shutil.rmtree(staging)
print(json.dumps({'status':'PASS','single_deb':True,'both_native_targets_required':True,'scheme':a.scheme,'manifest':str(out/'SINGLE-ARTIFACT.json')}))
