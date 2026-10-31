#!/usr/bin/env python3
"""Source-only checks. This is not an iOS compile or runtime acceptance test."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--headers', action='store_true')
parser.add_argument('--json', type=Path)
args = parser.parse_args()
checks = []
def check(name, ok):
    checks.append({'name': name, 'pass': bool(ok)})
def sha(data):
    return hashlib.sha256(data).hexdigest()
def text(rel):
    p = ROOT / rel
    return p.read_text() if p.is_file() else ''

upstream = json.loads(text('UPSTREAM.json'))
inputs = json.loads(text('BUILD-INPUTS.json'))
allowed = set(upstream['allowed_modified_files'])
for rel, digest in upstream['files'].items():
    if rel not in allowed:
        p = ROOT / rel
        check('upstream unchanged: ' + rel, p.is_file() and sha(p.read_bytes()) == digest)
source = (ROOT / 'tweak/Tweak.x').read_bytes()
guard_line = b'#include "SMBuildGuard.h"\n'
check('only compile guard added to runtime source',
      source.count(guard_line) == 1 and
      sha(source.replace(guard_line, b'', 1)) == upstream['files']['tweak/Tweak.x'])
check('nine original JS test files preserved',
      len(list((ROOT / 'tests').glob('*-test.cjs'))) == 9)
control = text('tweak/control')
for key, value in [('Package', inputs['package']), ('Version', inputs['version']),
                   ('Architecture', 'iphoneos-arm64e'), ('Author', 'T4MAG0')]:
    check('control ' + key, re.search(r'^' + key + ': ' + re.escape(value) + r'$', control, re.M))
check('control firmware remains iOS 15', 'firmware (>= 15.0), firmware (<< 16.0)' in control)
check('nonofficial build clearly identified', 'Unofficial' in control)
make = text('tweak/Makefile')
for name, needle in [('exact SDK/minOS', 'override TARGET := iphone:clang:15.5:15.0'),
                     ('arm64e only', 'override ARCHS := arm64e'),
                     ('native RootHide', 'THEOS_PACKAGE_SCHEME ?= roothide'),
                     ('reject different scheme', 'ifneq ($(THEOS_PACKAGE_SCHEME),roothide)'),
                     ('release package', 'FINALPACKAGE = 1'),
                     ('RootHide compile marker', '-DSM_TARGET_ROOTHIDE=1'),
                     ('inspectable pointer chains', '-Wl,-fixup_chains')]:
    check('Makefile ' + name, needle in make)
check('no no-PAC/no-fixups workaround', not any(v in make for v in ['-fno-ptrauth', '-no_fixup_chains', '-arch arm64 ']))
guard = text('tweak/SMBuildGuard.h')
for needle in ['__apple_build_version__', '__arm64e__', '__has_feature(ptrauth_calls)',
               '__IPHONE_OS_VERSION_MAX_ALLOWED != 150500',
               '__IPHONE_OS_VERSION_MIN_REQUIRED != 150000', 'TARGET_OS_SIMULATOR']:
    check('compile guard ' + needle, needle in guard)
check('compile guard has no runtime implementation', not any(v in guard for v in ['@implementation', 'ptrauth_strip(', 'ptrauth_sign_unauthenticated(']))
build = text('tweak/build-all.sh')
check('native build calls RootHide directly', 'make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide' in build)
check('no rootless-to-RootHide binary copy', not any(v in build for v in ['THEOS_PACKAGE_SCHEME=rootless', '"$W/rh"', 'sed \'s/^Architecture:']))
check('build runs artifact validation', 'verify_deb.py' in build)
check('iSH cannot accidentally compile', '!= Darwin' in text('build.sh') and 'exit 1' in text('build.sh'))
prepare = text('tools/prepare_web.sh')
check('web builds forced to iOS 15', 'SM_IOS=15 npm run build' in prepare)
check('upstream tests remain mandatory', 'npm test' in prepare)
check('dependency install scripts disabled', 'npm ci --ignore-scripts' in prepare)
for key in ['sdk_commit', 'theos_commit']:
    check('fixed source revision ' + key, bool(re.fullmatch('[0-9a-f]{40}', inputs[key])))
check('fixed macOS/Xcode host', inputs['host'] == 'macos-15-intel' and inputs['xcode'] == '16.4')
for rel in ['tools/verify_macho.py', 'tools/verify_deb.py', 'tools/check_sdk.py',
            'tests/local/test_verify_macho.py', 'ci/build-safarimodernizer.yml']:
    check('required build gate exists: ' + rel, (ROOT / rel).is_file())
ci = text('ci/build-safarimodernizer.yml')
check('CI cannot write repository', 'contents: read' in ci and 'contents: write' not in ci and 'git push' not in ci)
check('CI only builds this project', 'debs/SafariModernizer/build.sh' in ci and 'debs/*/' not in ci)
check('CI uses correct host', 'runs-on: macos-15-intel' in ci)
if args.headers:
    for js, header, var in [('polyfill.min.js', 'polyfill.h', 'polyfill_js'),
                            ('smfix.min.js', 'smfix.h', 'smfix_js')]:
        data = (ROOT / 'web' / js).read_bytes()
        hdr = text('tweak/' + header)
        match = re.search(r'\[\]\s*=\s*\{([^}]+)\}', hdr, re.S)
        decoded = bytes(int(v) for v in re.findall(r'\d+', match[1])) if match else b''
        check('embedded bytes exactly match ' + js, bool(data) and data == decoded)
        check('embedded length matches ' + js, f'{var}_len = {len(data)};' in hdr)
result = {'stage': 'source_static_only', 'passed': sum(x['pass'] for x in checks),
          'total': len(checks), 'failures': [x['name'] for x in checks if not x['pass']],
          'ios_build': 'not_run_by_this_check', 'device_runtime': 'not_tested_by_this_check'}
if args.json:
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(bool(result['failures']))
