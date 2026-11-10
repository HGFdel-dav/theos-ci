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
 asm=t/'native-vtable-arm64e.s'
 run([shutil.which('clang++') or 'clang++','--target=arm64e-apple-ios15.0','-O2','-S',str(ROOT/'tests/raw_vtable_call.cpp'),'-o',str(asm)])
 text=asm.read_text(); assert 'blr'+chr(9)+'x16' in text and 'braa'+chr(9) not in text and 'blraa'+chr(9) not in text
 print('ARM64E_UNSIGNED_XUL_VTABLE_CALL=PASS')
protected=json.loads((ROOT/'docs/BASELINE-PROTECTED.json').read_text())['files']
for name,digest in protected.items(): assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
print('PROTECTED_FILES='+str(len(protected)))
for p in ROOT.rglob('*.plist'): plistlib.loads(p.read_bytes())
print('PLISTS='+str(len(list(ROOT.rglob('*.plist')))))
print(run([sys.executable,str(ROOT/'tests/icon_check.py')],cwd=ROOT).splitlines()[-1])
assert not (ROOT/'layout').exists(),'extension layout must not be present'
for name in ['RDExtensionInstall.h','RDHandoffPayload.h']:
 assert not (ROOT/'Common'/name).exists(),name+' must not be present'
assert not (ROOT/'layout').exists(),'extension layout must not be present'
entry=(ROOT/'ReynardHook.xm').read_text(); router=(ROOT/'Common/RDClickRouter.h').read_text()
native=(ROOT/'Common/RDNativeLink.h').read_text()
assert 'dispatchToSwift:message:callback:' in entry and 'RDHandleClickNavigation' in router
assert 'RDNativeInstallXULHook' in entry and 'RDNativeOnLinkClick' in native
abi=(ROOT/'Common/RDGeckoABI.h').read_text()
assert 'RDGeckoCallUnsignedVTable3' in abi and 'blr x16' in abi
assert 'RDGeckoCallUnsignedVTable3(uri, &value)' in native
assert 'kRDExpectedXULUUID' in native and 'kRDLinkPrologue' in native
assert 'RDClickAllowed' not in router and 'RD_REDIRECT_FLAG' not in router
assert 'RDSeedExtensionsDatabase' not in native and 'signatures.required' not in native
assert 'native click gate' in native and 'route gate' in router
assert 'handoff.xpi' not in entry and 'WebExtension:InstallPrompt' not in entry
print('PLUGIN_ONLY_CANDIDATE=PASS')
print('LOCAL_CHECKS_PASS; iOS CI and device behavior still unverified')
