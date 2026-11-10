#!/usr/bin/env python3
"""Host-only checks for the plugin-only GeckoView click-router candidate."""
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
assert not (ROOT/'layout').exists(),'extension layout must not be present'
for name in ['RDExtensionInstall.h','RDHandoffPayload.h','RDNativeLink.h']:
 assert not (ROOT/'Common'/name).exists(),name+' must not be present'
assert not (ROOT/'tests/native_xul_hook_test.mm').exists(),'obsolete XUL test must not be present'
assert not (ROOT/'tests/policy_test.c').exists(),'obsolete XUL policy test must not be present'
entry=(ROOT/'ReynardHook.xm').read_text(); router=(ROOT/'Common/RDClickRouter.h').read_text()
assert 'RDClickRouter.h' in entry and 'dispatchToSwift:message:callback:' in entry
assert 'RDInstallNativeXULHook' not in entry and 'WebExtension' not in entry and 'ExtensionInstall' not in entry
assert 'RDHandleClickNavigation' in router and 'OnPreNavigation' in entry
assert 'sendSuccess:@(handled)' in router
assert 'RD_XUL_ON_LINK_CLICK' not in router and 'signatures.required' not in entry
print('PLUGIN_ONLY_CANDIDATE=PASS')
print('LOCAL_CHECKS_PASS; iOS CI and device behavior still unverified')
