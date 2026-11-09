#!/usr/bin/env python3
"""Host-only checks for the native Gecko click-router candidate."""
from pathlib import Path
import subprocess, tempfile, os, hashlib, plistlib, shutil, json, sys
ROOT=Path(__file__).resolve().parents[1]
clang=os.environ.get('CC') or shutil.which('clang') or '/usr/lib/llvm19/bin/clang-19'
def run(args,**kw):
 p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,**kw)
 if p.returncode: raise RuntimeError(f'{args[0]} failed ({p.returncode}):\n{p.stdout}\n{p.stderr}')
 return p.stdout
with tempfile.TemporaryDirectory(prefix='rd-native-') as temp:
 t=Path(temp)
 for opt in ['-O0','-O2']:
  exe=t/('native-policy'+opt)
  run([clang,'-std=c11','-Wall','-Wextra','-Werror',opt,str(ROOT/'tests/native_policy.c'),'-o',str(exe)])
  print(opt,run([str(exe)]).strip())
 cpp=t/'policy-cpp.o';run([clang,'-x','c++','-std=c++17','-Wall','-Wextra','-Werror','-c',str(ROOT/'tests/native_policy.c'),'-o',str(cpp)])
 print('CPP_POLICY_COMPILE=PASS')
protected=json.loads((ROOT/'docs/BASELINE-PROTECTED.json').read_text())['files']
for name,digest in protected.items(): assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
print('PROTECTED_FILES='+str(len(protected)))
for p in ROOT.rglob('*.plist'): plistlib.loads(p.read_bytes())
print('PLISTS='+str(len(list(ROOT.rglob('*.plist')))))
print(run([sys.executable,str(ROOT/'tests/icon_check.py')],cwd=ROOT).splitlines()[-1])
assert not (ROOT/'layout').exists(),'extension layout must not be present in native-only candidate'
assert not (ROOT/'Common/RDExtensionInstall.h').exists(),'extension installer must not be present'
assert not (ROOT/'Common/RDHandoffPayload.h').exists(),'embedded XPI must not be present'
native=(ROOT/'Common/RDNativeLink.h').read_text()
assert 'RDInstallNativeXULHook' in native
assert 'RD_XUL_ON_LINK_CLICK' in native and 'kRDExpectedXULUUID' in native
assert 'RDSeedExtensionsDatabase' not in native and 'signatures.required' not in native
print('NATIVE_ONLY_CANDIDATE=PASS')
print('LOCAL_CHECKS_PASS; XUL ABI/device behavior still unverified')
