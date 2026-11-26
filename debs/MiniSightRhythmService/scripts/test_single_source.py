#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Expand real project Makefiles against inert include stubs, NEVER Theos/codegen.
Only make goal __source_probe exists here. No iOS objects/packages are built.
"""
from pathlib import Path
import itertools, json, subprocess, tempfile
S = Path(__file__).resolve().parents[1]
P = S.parent/'MiniSight'
rows = []
with tempfile.TemporaryDirectory() as td:
    t = Path(td); mk = t/'makefiles'; mk.mkdir()
    (mk/'common.mk').write_text('THEOS_MAKE_PATH := '+str(mk)+'\n')
    for f in ['tweak.mk', 'aggregate.mk']: (mk/f).write_text('# inert source-only include\n')
    probe = t/'probe.mk'
    variables = ['TARGET', 'SDKVERSION', 'ARCHS', 'FINALPACKAGE', 'TWEAK_NAME', 'SUBPROJECTS',
        'MINISIGHT_RHYTHM_MODE', 'MINISIGHT_ENABLE_RHYTHM_CAPTURE', 'MINISIGHT_ENABLE_RHYTHM_TRANSPORT',
        'MINISIGHT_RHYTHM_LIVE_BUILD', 'MiniSight_FILES', 'MiniSight_CFLAGS',
        'MiniSightRhythmService_FILES', 'MiniSightRhythmService_CCFLAGS', 'MiniSightRhythmService_LDFLAGS',
        'shared/vendor/BeatDetektor/BeatDetektor.cpp_CFLAGS', 'shared/MiniSightRhythmAnalyzer.cpp_CFLAGS']
    probe.write_text('\n'.join('$(info '+v+'=$('+v+'))' for v in variables)+'\n.PHONY: __source_probe\n__source_probe:\n\t@:\n')
    for root, scheme in itertools.product([P, S], ['roothide', 'rootless']):
        for mode, capture, transport, live in itertools.product(['SOURCE', 'LIVE'], [0, 1], [0, 1], [0, 1]):
            flags = ['MINISIGHT_RHYTHM_MODE='+mode, 'MINISIGHT_ENABLE_RHYTHM_CAPTURE='+str(capture),
                'MINISIGHT_ENABLE_RHYTHM_TRANSPORT='+str(transport), 'MINISIGHT_RHYTHM_LIVE_BUILD='+str(live)]
            cmd = ['make', '-s', '--no-print-directory', '-C', str(root), '-f', 'Makefile', '-f', str(probe),
                '__source_probe', 'THEOS='+str(t), 'THEOS_PACKAGE_SCHEME='+scheme, *flags]
            r = subprocess.run(cmd, text=True, capture_output=True)
            ok = capture == transport == live == int(mode == 'LIVE')
            assert (r.returncode == 0) == ok, (cmd, r.stdout, r.stderr)
            if ok:
                fields = dict(x.split('=', 1) for x in r.stdout.splitlines() if '=' in x)
                assert fields['ARCHS'] == ('arm64e' if scheme == 'roothide' else 'arm64')
                assert fields['FINALPACKAGE'] == '1'
                assert fields['TWEAK_NAME'] == root.name
                main = root == P
                assert fields['TARGET'] == ('iphone:15.5:15.0' if main else 'iphone:clang:15.5:15.5')
                files = fields[root.name+'_FILES'].split()
                assert all((root/x).is_file() for x in files), files
                if main:
                    assert fields['SDKVERSION'] == '15.5'
                    assert fields['SUBPROJECTS'] == '../MiniSightRhythmService'
                    assert not any(x in files for x in ['Tweak.cpp', 'CaptureEngine.cpp', 'FeatureServer.cpp'])
                    assert 'MiniSightLyrics.m' in files and 'MiniSightPetEffects.m' in files
                else:
                    assert fields['SUBPROJECTS'] == '' and 'Tweak.cpp' in files and 'CaptureEngine.cpp' in files
                    assert fields['shared/vendor/BeatDetektor/BeatDetektor.cpp_CFLAGS'] == '-Wno-error=reorder-ctor -Wno-error=unused-but-set-variable -Wno-error=shorten-64-to-32 -Wno-error=sign-compare'
                    assert fields['shared/MiniSightRhythmAnalyzer.cpp_CFLAGS'] == '-Wno-error=reorder-ctor'
                cflags = fields['MiniSight_CFLAGS' if main else 'MiniSightRhythmService_CCFLAGS']
                for k, value in [('CAPTURE', capture), ('TRANSPORT', transport)]: assert '-DMINISIGHT_ENABLE_RHYTHM_'+k+'='+str(value) in cflags
                assert '-DMINISIGHT_RHYTHM_LIVE_BUILD='+str(live) in cflags
            rows.append({'project': root.name, 'scheme': scheme, 'mode': mode, 'capture': capture, 'transport': transport, 'live': live, 'accepted': ok})
        for invalid in ['MINISIGHT_RHYTHM_MODE=', 'MINISIGHT_RHYTHM_MODE=SOURCE LIVE', 'MINISIGHT_RHYTHM_MODE=unknown',
            'MINISIGHT_ENABLE_RHYTHM_CAPTURE=2', 'MINISIGHT_ENABLE_RHYTHM_TRANSPORT=', 'THEOS_PACKAGE_SCHEME=unknown']:
            cmd = ['make', '-s', '-C', str(root), '-f', 'Makefile', '-f', str(probe), '__source_probe', 'THEOS='+str(t), 'THEOS_PACKAGE_SCHEME='+scheme, invalid]
            r = subprocess.run(cmd, text=True, capture_output=True)
            assert r.returncode != 0, (cmd, r.stdout)
            rows.append({'project': root.name, 'scheme': scheme, 'invalid': invalid, 'rejected': True})
print(json.dumps({'status': 'PASS', 'scope': 'INERT_MAKEFILE_EXPANSION_ONLY', 'cases': rows, 'count': len(rows), 'ios_compile': False, 'real_theos': 'NOTRUN'}))
