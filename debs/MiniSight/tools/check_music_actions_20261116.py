#!/usr/bin/env python3
"""Local portable C checks; Apple compile/run only with --ci on approved runner.
No network requests, device, package install, signing or workflow dispatch.
"""
import argparse
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--ci', action='store_true')
p.add_argument('--ios-sdk')
a = p.parse_args()
compiler = shutil.which('cc') or shutil.which('clang')
if not compiler:
    raise SystemExit('Portable C compiler required')
with tempfile.TemporaryDirectory(prefix='minisight-policy-') as t:
    target = Path(t) / 'policy'
    subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I', str(ROOT),
        str(ROOT / 'tests/liveliness_policy_20261116.c'), '-lm', '-o', str(target)], check=True)
    subprocess.run([str(target)], check=True)
if not a.ci:
    print('SKIP native UIKit/ImageIO/Foundation: CI authorization and Apple SDK required')
    raise SystemExit(0)
if platform.system() != 'Darwin' or not shutil.which('xcrun') or os.environ.get('CI', '').lower() not in ('1','true','yes'):
    raise SystemExit('Apple native checks reserved for an explicitly authorized CI runner')
if not a.ios_sdk or Path(a.ios_sdk).name != 'iPhoneOS15.5.sdk' or not Path(a.ios_sdk).is_dir():
    raise SystemExit('The exact iPhoneOS15.5.sdk is required, not a newer relabelled SDK')
failures = []
def checked(label, command, timeout):
    print('CHECK ' + label, flush=True)
    try:
        result = subprocess.run(command, cwd=ROOT, timeout=timeout)
        if result.returncode:
            failures.append(label)
    except subprocess.TimeoutExpired:
        failures.append(label + ' timeout')
# Collect independent diagnostics in one run, but fail closed before packaging.
# Never suppress a failed typecheck or replace real native tests with assertions.
for arch in ['arm64', 'arm64e']:
    for file in sorted(ROOT.glob('*.m')):
        checked(arch + ' ' + file.name, ['xcrun','clang','-std=gnu11','-fobjc-arc','-fblocks','-fsyntax-only',
            '-Wall','-Wextra','-Werror=return-type','-Werror=unguarded-availability-new',
            '-Werror=objc-method-access','-Werror=implicit-function-declaration',
            '-Werror=incompatible-pointer-types','-Werror=enum-conversion',
            '-Wno-deprecated-declarations','-target',arch + '-apple-ios15.5','-isysroot',a.ios_sdk,
            '-I',str(ROOT),str(file)], 120)
    for language, standard in [('objective-c', 'gnu11'), ('objective-c++', 'gnu++14')]:
        checked(arch + ' all production policies ' + language,
            ['xcrun','clang','-x',language,'-std=' + standard,'-fobjc-arc','-fblocks','-fsyntax-only',
             '-Wall','-Wextra','-Werror','-Werror=unguarded-availability-new',
             '-target',arch + '-apple-ios15.5','-isysroot',a.ios_sdk,'-I',str(ROOT),
             str(ROOT/'tests/native_policy_compile_20261116.mm')], 120)
checked('native ActionLibrary', ['python3','scripts/test_minisight_action_library_20261116.py','--root',str(ROOT.parent.parent),
    '--ci','--ios-sdk',a.ios_sdk], 540)
# Full required lyrics baseline + compiled negative suite was measured at 486s
# in the preceding Portable step. Keep a bounded budget that permits the SAME
# complete suite here; do not skip tests or accept an incomplete native run.
checked('native Foundation lyrics', ['python3','scripts/test_minisight_lyrics_20261116.py','--require-native'], 900)
checked('native Foundation music', ['python3','scripts/test_minisight_music_monitor_20261116.py','--require-native'], 150)
checked('native shared-cache music symbols', ['python3','scripts/test_minisight_music_symbols_20261118.py','--require-native'], 300)
checked('atlas restore source gate', ['python3','scripts/test_minisight_atlas_restore_20261118.py'], 60)
checked('portable pet edge bounds', ['python3','scripts/test_minisight_pet_bounds_20261118.py','--portable-only'], 300)
checked('native bubble restore and approval', ['python3','scripts/test_minisight_bubble_edge_20261118.py','--require-native'], 600)
checked('native presentation readback', ['python3','scripts/test_minisight_presentation_readback_20261116.py','--require-native'], 300)
checked('native shown/name state chain', ['python3','scripts/test_minisight_shown_name_20261117.py','--require-native'], 360)
checked('native PetEffects', ['python3','scripts/test_minisight_effects_runtime_20261116.py','--root',str(ROOT),'--require-native'], 180)
if failures:
    raise SystemExit('FAIL closed before package: ' + '; '.join(failures))
print('PASS exact iPhoneOS15.5 types + ObjC/ObjC++ policies + real Foundation/ImageIO tests; not device acceptance')
