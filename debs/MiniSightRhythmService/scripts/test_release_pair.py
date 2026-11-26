#!/usr/bin/env python3
"""Source contracts and mock-only packaging. Never runs make/xcrun/dpkg/audio."""
from pathlib import Path
import ast,contextlib,io,json,os,plistlib,runpy,sys,tempfile
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
assert 'test -s out/SINGLE-ARTIFACT.json' in workflow and 'shasum -a 256 -c SHA256SUMS' in workflow
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
# Real source scopes plus both standard Theos output encodings. All original
# twelve build/atomic-publication scenarios remain below, without weaker asserts.
source_filters={
 'MiniSight':b'{ Filter = { Bundles = ( "com.apple.springboard" ); }; }\n',
 'MiniSightRhythmService':b'Filter = { Executables = ("mediaserverd"); };'}
filter_scopes={'MiniSight':{'Filter':{'Bundles':['com.apple.springboard']}},
               'MiniSightRhythmService':{'Filter':{'Executables':['mediaserverd']}}}
filter_node=next(n for n in ast.parse(code).body if isinstance(n,ast.FunctionDef) and n.name=='verify_filter')
filter_ns={'plistlib':plistlib};exec(compile(ast.Module(body=[filter_node],type_ignores=[]),'verify_filter','exec'),filter_ns)
filter_cases=[]
for name,scope in filter_scopes.items():
 for encoding in [plistlib.FMT_BINARY,plistlib.FMT_XML]:
  encoded=plistlib.dumps(scope,fmt=encoding)
  filter_ns['verify_filter'](source_filters[name],encoded,name)
  filter_cases.append({'role':name,'encoding':encoding.name,'valid_scope':True})
 for wrong in [{'Filter':{'Executables':['SpringBoard','mediaserverd']}},
               {'Filter':{'Executables':['other']}},
               {'Filter':dict(scope['Filter'],Classes=['NSObject'])},
               dict(scope,Extra=True),{},['mediaserverd']]:
  refused=False
  try:filter_ns['verify_filter'](source_filters[name],plistlib.dumps(wrong,fmt=plistlib.FMT_BINARY),name)
  except AssertionError:refused=True
  assert refused,('unexpected filter scope accepted',name,wrong)
  filter_cases.append({'role':name,'wrong_scope_rejected':True})
 for corrupt in [b'changed',b'bplist00broken',b'<?xml version="1.0"?><plist><dict>']:
  refused=False
  try:filter_ns['verify_filter'](source_filters[name],corrupt,name)
  except AssertionError:refused=True
  assert refused,('corrupt filter accepted',name)
  filter_cases.append({'role':name,'corrupt_rejected':True})
 refused=False
 try:filter_ns['verify_filter'](source_filters[name]+b'\nUnexpected = 1;',plistlib.dumps(scope),name)
 except AssertionError:refused=True
 assert refused,('changed source scope accepted',name)
 filter_cases.append({'role':name,'source_drift_rejected':True})
from test_single_support import run_cases
cases=run_cases(S,source_filters,filter_scopes)
print(json.dumps({'status':'PASS','scope':'SOURCE_AND_MOCK_ONLY','mock_cases':cases,'filter_encoding_cases':filter_cases,'current_placeholder_blocks_packaging':current_identity_blocked,'single_deb_both_targets_required':True,'no_commands_executed':True,'not_ios_or_device_validated':True}))
