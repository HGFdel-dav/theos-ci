#!/usr/bin/env python3
"""Source contracts and mock-only packaging. Never runs make/xcrun/dpkg/audio."""
from pathlib import Path
import ast,contextlib,io,json,os,runpy,sys,tempfile
from unittest.mock import patch
S=Path(__file__).resolve().parents[1]
code=(S/'scripts/package_pair.py').read_text()
workflow=(S.parents[1]/'.github/workflows/build-minisight.yml').read_text()
assert "- 'debs/MiniSightRhythmService/**'" in workflow
assert '            debs/MiniSightRhythmService' in workflow
assert 'scheme: [roothide, rootless]' in workflow
assert 'check_music_actions_20261116.py --ci --ios-sdk "$SDK_PATH"' in workflow
assert 'live-package THEOS_PACKAGE_SCHEME=${{ matrix.scheme }}' in workflow
assert 'if: always()' not in workflow and 'if-no-files-found: error' in workflow
assert 'cp packages/*.deb' not in workflow
assert workflow.index('if [ "$checks_status" -ne 0 ]; then') < workflow.index('live-package THEOS_PACKAGE_SCHEME=')
assert 'test -s out/PAIR-ARTIFACTS.json' in workflow and 'shasum -a 256 -c SHA256SUMS' in workflow
make=(S/'Makefile').read_text();pair=(S/'build/Pair.mk').read_text()
assert 'THEOS_PACKAGE_SCHEME ?= roothide' in make
assert 'ifeq ($(THEOS_PACKAGE_SCHEME),rootless)\nARCHS = arm64\nelse ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\nARCHS = arm64e' in make
assert '--scheme "$(THEOS_PACKAGE_SCHEME)"' in pair
assert 'MINISIGHT_RHYTHM_CI_BUILD_APPROVED' in code and "'local-candidate','source-only','placeholder'" in code
ast.parse(code)
# Identity gate is exercised without importing the executable CLI or changing control.
node=next(n for n in ast.parse(code).body if isinstance(n,ast.FunctionDef) and n.name=='identity')
ns={'re':__import__('re')};exec(compile(ast.Module(body=[node],type_ignores=[]),'identity','exec'),ns)
current_identity_blocked=False
try: ns['identity'](S)
except AssertionError: current_identity_blocked=True
cases=[]
if any(x in (S/'control').read_text() for x in ['local-candidate','source-only','placeholder']):assert current_identity_blocked,'placeholder must refuse packaging'
for scheme,failure in [('roothide',None),('rootless',None),('roothide','plugin-build'),('rootless','missing-service'),('roothide','missing-plugin'),('rootless','duplicate-package'),('rootless','wrong-arch'),('roothide','wrong-slice'),('rootless','wrong-sdk'),('roothide','wrong-prefix'),('rootless','wrong-filter'),('roothide','stale')]:
 with tempfile.TemporaryDirectory() as td:
  base=Path(td);service=base/'MiniSightRhythmService';plugin=base/'MiniSight';out=base/'out';calls=[]
  for root,name in [(service,'MiniSightRhythmService'),(plugin,'MiniSight')]:
   root.mkdir();(root/'Makefile').write_text('# mock only\n')
   (root/'control').write_text('Package: org.mock.'+name.lower()+'\nVersion: 1.0\n')
   (root/(name+'.plist')).write_text('Filter = { mock = 1; };\n')
  (service/'MANIFEST.json').write_text('{}')
  if failure=='stale':out.mkdir();(out/'sentinel').write_text('preserve')
  def fake_run(cmd,**kw):
   calls.append(cmd)
   if cmd[0]==sys.executable and cmd[1].endswith('/scripts/check_contract.py'):return
   if cmd[0]=='make':
    assert 'THEOS_PACKAGE_SCHEME='+scheme in cmd
    for flag in ['MINISIGHT_ENABLE_RHYTHM_CAPTURE=1','MINISIGHT_ENABLE_RHYTHM_TRANSPORT=1','MINISIGHT_RHYTHM_LIVE_BUILD=1']:assert flag in cmd
    if cmd[3]=='package':
     if failure=='plugin-build' and Path(cmd[2])==plugin:raise RuntimeError('mock plugin failed')
     dest=Path(next(x.split('=',1)[1] for x in cmd if x.startswith('THEOS_PACKAGE_DIR=')))
     if (failure=='missing-service' and Path(cmd[2])==service) or (failure=='missing-plugin' and Path(cmd[2])==plugin):return
     (dest/'mock.deb').write_bytes(b'MOCK, NOT A DEB')
     if failure=='duplicate-package':(dest/'duplicate.deb').write_bytes(b'MOCK, NOT A DEB')
    else:assert cmd[3]=='clean'
    return
   if cmd[:2]==['dpkg-deb','-x']:
    role=Path(cmd[2]).parent.name;name='MiniSightRhythmService' if role=='service' else 'MiniSight'
    prefix='var/jb/' if scheme=='rootless' else ''
    if failure=='wrong-prefix':prefix='var/jb/'
    p=Path(cmd[3])/(prefix+'Library/MobileSubstrate/DynamicLibraries');p.mkdir(parents=True)
    (p/(name+'.dylib')).write_bytes(b'MOCK, NOT MACH-O')
    (p/(name+'.plist')).write_text('changed' if failure=='wrong-filter' else 'Filter = { mock = 1; };\n')
    return
   raise AssertionError(('unexpected command (NOT executed)',cmd))
  def fake_output(cmd,**kw):
   calls.append(cmd)
   if cmd[:2]==['dpkg-deb','-f']:
    role=Path(cmd[2]).parent.name;name='minisightrhythmservice' if role=='service' else 'minisight'
    if cmd[3]=='Architecture':return 'bad' if failure=='wrong-arch' else ('iphoneos-arm64e' if scheme=='roothide' else 'iphoneos-arm64')
    return {'Package':'org.mock.'+name,'Version':'1.0'}[cmd[3]]
   if cmd[:3]==['xcrun','lipo','-archs']:return 'bad' if failure=='wrong-slice' else ('arm64e' if scheme=='roothide' else 'arm64')
   if cmd[:3]==['xcrun','otool','-l']:return 'cmd LC_BUILD_VERSION\n minos 15.5\n sdk '+('16.0' if failure=='wrong-sdk' else '15.5')+'\n'
   raise AssertionError(('unexpected command (NOT executed)',cmd))
  failed=False
  with patch.object(sys,'argv',['package_pair.py','--service',str(service),'--output',str(out),'--mode','LIVE','--scheme',scheme,'--build']),patch.dict(os.environ,{'CI':'true','MINISIGHT_RHYTHM_CI_BUILD_APPROVED':'1'}),patch('subprocess.run',fake_run),patch('subprocess.check_output',fake_output),contextlib.redirect_stdout(io.StringIO()):
   try:runpy.run_path(str(S/'scripts/package_pair.py'),run_name='__main__')
   except (AssertionError,RuntimeError):failed=True
  assert failed==bool(failure),(scheme,failure,failed)
  if not failure:
   m=json.loads((out/'PAIR-ARTIFACTS.json').read_text())
   assert {x['role'] for x in m['required']}=={'service','plugin'} and m['scheme']==scheme
   assert len([x for x in calls if x[0]=='make'])==4
   assert all(x['native_checked'] for x in m['required']) and len((out/'SHA256SUMS').read_text().splitlines())==2
  elif failure=='stale':assert (out/'sentinel').read_text()=='preserve' and not calls
  else:assert not out.exists(),failure
  assert not list(base.glob('.rhythm-pair-*')),'partial staging leaked'
  cases.append({'scheme':scheme,'failure':failure,'passed':True})
print(json.dumps({'status':'PASS','scope':'SOURCE_AND_MOCK_ONLY','mock_cases':cases,'current_placeholder_blocks_packaging':current_identity_blocked,'both_packages_required':True,'no_commands_executed':True,'not_ios_or_device_validated':True}))
