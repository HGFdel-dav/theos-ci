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
for arch in ['arm64','arm64e']:
    for file in ['MiniSightPet.m','MiniSightPetEffects.m','MiniSightActionLibrary.m','MiniSightLyrics.m','MiniSightMusicMonitor.m']:
        subprocess.run(['xcrun','clang','-std=gnu11','-fobjc-arc','-fblocks','-fsyntax-only',
            '-Wall','-Wextra','-Werror=return-type','-Werror=unguarded-availability-new',
            '-Wno-deprecated-declarations','-target',arch + '-apple-ios15.5','-isysroot',a.ios_sdk,
            '-I',str(ROOT),str(ROOT/file)],check=True,timeout=120)
subprocess.run(['python3','scripts/test_minisight_action_library_20261116.py','--root',str(ROOT.parent.parent),
    '--ci','--ios-sdk',a.ios_sdk],cwd=ROOT,check=True,timeout=540)
subprocess.run(['python3','scripts/test_minisight_lyrics_20261116.py','--require-native'],cwd=ROOT,check=True,timeout=300)
subprocess.run(['python3','scripts/test_minisight_music_monitor_20261116.py','--require-native'],cwd=ROOT,check=True,timeout=150)
subprocess.run(['python3','scripts/test_minisight_effects_runtime_20261116.py','--root',str(ROOT),'--require-native'],cwd=ROOT,check=True,timeout=180)
print('PASS exact iPhoneOS15.5 types + real Foundation/ImageIO tests; not device acceptance')
