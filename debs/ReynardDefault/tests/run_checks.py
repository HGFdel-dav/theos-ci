#!/usr/bin/env python3
"""Host checks only: no iOS compilation, credentials, network or device access."""
from pathlib import Path
import subprocess, json, tempfile, os, random, urllib.parse, hashlib, plistlib, shutil, sys
ROOT=Path(__file__).resolve().parents[1]
clang=os.environ.get('CC') or shutil.which('clang') or '/usr/lib/llvm19/bin/clang-19'
node=shutil.which('node') or '/usr/bin/node'
def run(args,**kw):
 p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,**kw)
 if p.returncode: raise RuntimeError(f'{args[0]} failed ({p.returncode}):\n{p.stdout}\n{p.stderr}')
 return p.stdout
with tempfile.TemporaryDirectory(prefix='rd-click-') as temp:
 t=Path(temp);env=os.environ.copy();env['RD_TEST_CASES']=str(t/'cases.json')
 print(run([node,str(ROOT/'tests/click_script.test.js')],env=env).splitlines()[-1])
 print(run([node,str(ROOT/'tests/background.test.js')]).strip())
 cpp=t/'policy-cpp.o'
 run([clang,'-x','c++','-std=c++17','-Wall','-Wextra','-Werror','-c',str(ROOT/'tests/policy_test.c'),'-o',str(cpp)])
 print('CPP_POLICY_COMPILE=PASS')
 for optimize in ['-O0','-O2']:
  exe=t/('policy'+optimize)
  run([clang,'-std=c11','-Wall','-Wextra','-Werror',optimize,str(ROOT/'tests/policy_test.c'),'-o',str(exe)])
  print(optimize,run([str(exe)]).strip())
  fixtures=json.loads((t/'cases.json').read_text());number=0
  for case in fixtures:
   result=run([str(exe),urllib.parse.urlsplit(case['uri']).fragment]).splitlines()
   assert result[1]==case['expectedApp'],(case,result)
   number+=1
  random.seed(926)
  for i in range(250):
   token=''.join(random.choice('abXYZ012%&=#?+:/._-') for _ in range(80))
   app='demo://item?payload='+urllib.parse.quote(token,safe='')+'#fragment'
   web='https://shop.example/items?a=1&b=2#details'
   encode=lambda value:urllib.parse.quote(value,safe="~()*!.'-")
   fragment='v=2&id='+'ab'*16+'&ts=1794217455000&a='+encode(app)+'&h='+encode(web)
   result=run([str(exe),fragment]).splitlines()
   assert result[1]==app and result[2]==web,(app,result)
   number+=1
  print(optimize,'JS-to-production-parser and encoding roundtrips:',number)
# Preserve first feature, control center icons/text/logic, settings UI/values.
protected=json.loads((ROOT/'docs/BASELINE-PROTECTED.json').read_text())['files']
for name,digest in protected.items():
 assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest, 'Protected file changed: '+name
print('PROTECTED_FILES='+str(len(protected)))
plists=list(ROOT.rglob('*.plist'))
for p in plists: plistlib.loads(p.read_bytes())
print('PLISTS='+str(len(plists)))
print(run([sys.executable,str(ROOT/'tests/icon_check.py')],cwd=ROOT).splitlines()[-1])
if '--allow-pending-signature' in sys.argv:
 p=subprocess.run([sys.executable,str(ROOT/'tests/verify_payload.py')],capture_output=True,text=True)
 assert p.returncode!=0 and 'signed XPI differs' in p.stdout
 print('STALE_SIGNED_PAYLOAD_REJECTED=YES (pending signature)')
else:
 print(run([sys.executable,str(ROOT/'tests/verify_payload.py')]).strip())
 # Verify the gate rejects a changed source without altering the actual candidate.
 with tempfile.TemporaryDirectory(prefix='rd-payload-gate-') as temp:
  copy=Path(temp)/'source';shutil.copytree(ROOT,copy)
  f=copy/'layout/Library/ReynardDefault/handoff/handoff.js'
  f.write_text(f.read_text()+'\n// mutation must be rejected\n')
  p=subprocess.run([sys.executable,str(copy/'tests/verify_payload.py')],capture_output=True,text=True)
  assert p.returncode!=0 and 'differs from edited handoff.js' in p.stdout
 print('STALE_SIGNED_PAYLOAD_REJECTED=YES')
print('LOCAL_CHECKS_PASS; these tests do not establish iOS device behavior')
