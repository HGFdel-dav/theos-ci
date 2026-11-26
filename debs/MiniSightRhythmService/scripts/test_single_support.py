# SPDX-License-Identifier: MIT
"""Mock-only single DEB publication tests. No make/dpkg/iOS/audio is executed."""
from pathlib import Path
import contextlib, hashlib, io, json, os, plistlib, runpy, signal, struct, sys, tarfile, tempfile
from unittest.mock import patch

def binary(cpu, minimum, failure=None):
    # Synthetic header + signed data only: no instructions, never a live dylib.
    sub = 0x80000002 if cpu == 'arm64e' else 0
    if failure == 'slice': sub = 7
    sdk = 0x100000 if failure == 'sdk' else 0x0f0500
    if failure == 'minimum': minimum = 0x100000
    code = struct.pack('<8I', 0xfeedfacf, 0x100000c, sub, 6, 2, 40, 0, 0)
    code += struct.pack('<6I', 0x32, 24, 2, minimum, sdk, 0)
    # CodeDirectory v0x20100 with one SHA256 slot, signed range [0,128).
    ident = b'mock\0'; hashoff = 44 + len(ident); cdlen = hashoff + 32
    capacity = 20 + cdlen
    code += struct.pack('<4I', 0x1d, 16, 128, capacity)
    code = code.ljust(128, b'\0')
    cd = struct.pack('>9I4BI', 0xfade0c02, cdlen, 0x20100, 2, hashoff, 44, 0, 1, 128, 32, 2, 0, 12, 0)
    cd += ident + hashlib.sha256(code).digest()
    raw = code + struct.pack('>5I', 0xfade0cc0, capacity, 1, 0, 20) + cd
    if failure == 'signature': raw = raw[:100] + b'X' + raw[101:]
    if failure == 'unsigned': raw = raw[:128]
    if failure == 'entitlement': raw = raw[:140] + struct.pack('>I', 5) + raw[144:]
    if failure == 'trailing': raw += b'UNSIGNED'
    if failure == 'primary': raw = raw[:140] + struct.pack('>I', 0x1000) + raw[144:]
    if failure == 'header': raw = b'BAD!' + raw[4:]
    return raw

def archive(files, failure=None):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:') as tar:
        for name, data in files.items():
            item = tarfile.TarInfo(name); item.size = len(data)
            item.mode = 0o755 if name.endswith('.dylib') else 0o644
            item.uid = item.gid = 0; item.uname = 'root'; item.gname = 'wheel'
            if failure == 'link': item.type = tarfile.SYMTYPE; item.linkname = '/tmp/escape'; item.size = 0
            if failure == 'hardlink': item.type = tarfile.LNKTYPE; item.linkname = '../escape'; item.size = 0
            if failure == 'traversal': item.name = '../escape'
            if failure == 'owner': item.uid = 99
            if failure == 'permission': item.mode = 0o777
            tar.addfile(item, io.BytesIO(data))
            if failure == 'duplicate-entry': tar.addfile(item, io.BytesIO(data))
    return out.getvalue()

def run_cases(S, source_filters, filter_scopes):
    cases = []
    # Original twelve scenarios retained; missing now means half of ONE DEB.
    original = [('roothide', None), ('rootless', None), ('roothide', 'plugin-build'),
      ('rootless', 'missing-service'), ('roothide', 'missing-plugin'), ('rootless', 'duplicate-package'),
      ('rootless', 'wrong-arch'), ('roothide', 'wrong-slice'), ('rootless', 'wrong-sdk'),
      ('roothide', 'wrong-prefix'), ('rootless', 'wrong-filter'), ('roothide', 'stale')]
    additional = ['service-build', 'clean-failure', 'missing-service-filter', 'missing-plugin-filter',
      'service-slice', 'service-sdk', 'plugin-minimum', 'service-minimum', 'plugin-signature',
      'service-signature', 'plugin-unsigned', 'service-unsigned', 'service-filter', 'plugin-filter',
      'external-depends', 'bad-provides', 'bad-conflicts', 'bad-replaces', 'wrong-version',
      'empty-package', 'no-package', 'symlink-package', 'extra-payload', 'control-script',
      'link', 'owner', 'permission', 'cancel-int', 'cancel-term', 'cancel-keyboard',
      'contract-failure', 'local-refused', 'approval-refused', 'output-symlink',
      'plugin-entitlement', 'service-entitlement', 'source-refused', 'scheme-refused', 'build-refused',
      'plugin-trailing', 'service-trailing', 'plugin-primary', 'service-primary', 'plugin-header', 'service-header',
      'hardlink', 'traversal', 'duplicate-entry', 'extra-build-output', 'publish-failure', 'wrong-package']
    for scheme, failure in original + [('roothide', f) for f in additional]:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td).resolve(); service = base/'MiniSightRhythmService'; plugin = base/'MiniSight'
            out = base/'out'; calls = []; built = {}
            for root, name, package, ver in [(service, 'MiniSightRhythmService', 'com.niubiprass.minisight.rhythmservice', '0.1.0'), (plugin, 'MiniSight', 'com.niubiprass.minisight', '0.8.58')]:
                root.mkdir(); (root/'Makefile').write_text('# mock only\n')
                (root/'control').write_text('Package: '+package+'\nVersion: '+ver+'\n')
                (root/(name+'.plist')).write_bytes(source_filters[name])
            (service/'MANIFEST.json').write_text('{}')
            if failure == 'stale': out.mkdir(); (out/'sentinel').write_text('preserve')
            if failure == 'output-symlink': out.symlink_to(base/'nonexistent')
            prefix = ('var/jb/' if scheme == 'rootless' else '') + 'Library/MobileSubstrate/DynamicLibraries/'
            if failure == 'wrong-prefix': prefix = 'var/jb/Library/MobileSubstrate/DynamicLibraries/'
            cpu = 'arm64e' if scheme == 'roothide' else 'arm64'
            for name in source_filters:
                role = 'plugin' if name == 'MiniSight' else 'service'
                bad = None
                for kind in ['slice', 'sdk', 'minimum', 'signature', 'unsigned', 'entitlement', 'trailing', 'primary', 'header']:
                    if failure == role+'-'+kind or (role == 'plugin' and failure == 'wrong-'+kind): bad = kind
                if failure != 'missing-'+role:
                    built[prefix+name+'.dylib'] = binary(cpu, 0x0f0000 if role == 'plugin' else 0x0f0500, bad)
                if failure != 'missing-'+role+'-filter':
                    scope = filter_scopes[name]
                    if failure in [role+'-filter', 'wrong-filter']: scope = {'Filter': {'Executables': ['SpringBoard', 'mediaserverd']}}
                    built[prefix+name+'.plist'] = plistlib.dumps(scope, fmt=plistlib.FMT_BINARY)
            if failure == 'extra-payload': built['extra'] = b'unwanted'
            def fake_run(cmd, **kw):
                assert not out.exists(), 'output exposed before all audits completed'
                calls.append(cmd)
                if cmd[0] == sys.executable and cmd[1].endswith('/scripts/check_contract.py'):
                    if failure == 'contract-failure': raise RuntimeError('mock contract failed')
                    return
                if cmd[0] == 'make':
                    assert Path(cmd[2]) == plugin, 'never package service separately'
                    assert 'THEOS_PACKAGE_SCHEME='+scheme in cmd
                    for flag in ['MINISIGHT_ENABLE_RHYTHM_CAPTURE=1', 'MINISIGHT_ENABLE_RHYTHM_TRANSPORT=1', 'MINISIGHT_RHYTHM_LIVE_BUILD=1']: assert flag in cmd
                    if cmd[3] == 'clean':
                        if failure == 'clean-failure': raise RuntimeError('mock clean failed')
                        return
                    assert cmd[3] == 'package'
                    if failure in ['plugin-build', 'service-build']: raise RuntimeError('mock aggregate member failed')
                    if failure == 'cancel-int': signal.raise_signal(signal.SIGINT)
                    if failure == 'cancel-term': signal.raise_signal(signal.SIGTERM)
                    if failure == 'cancel-keyboard': raise KeyboardInterrupt()
                    dest = Path(next(x.split('=', 1)[1] for x in cmd if x.startswith('THEOS_PACKAGE_DIR=')))
                    if failure == 'no-package': return
                    if failure == 'symlink-package': (dest/'mock.deb').symlink_to(service/'control'); return
                    (dest/'mock.deb').write_bytes(b'' if failure == 'empty-package' else b'MOCK NOT A DEB')
                    if failure == 'duplicate-package': (dest/'duplicate.deb').write_bytes(b'MOCK')
                    if failure == 'extra-build-output': (dest/'unexpected.log').write_bytes(b'unwanted')
                    return
                if cmd[:2] == ['dpkg-deb', '-x']:
                    for name, data in built.items():
                        p = Path(cmd[3])/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
                    return
                raise AssertionError(('unexpected command, NOT executed', cmd))
            def fake_output(cmd, **kw):
                assert not out.exists(), 'output exposed during archive/native audits'
                calls.append(cmd)
                if cmd[:2] == ['dpkg-deb', '-f']:
                    fields = {'Package': 'com.niubiprass.minisight', 'Version': '0.8.58',
                      'Architecture': 'iphoneos-'+cpu, 'Depends': 'mobilesubstrate, firmware (>= 15.5)',
                      'Provides': 'com.niubiprass.minisight.rhythmservice (= 0.1.0)',
                      'Conflicts': 'com.niubiprass.minisight.rhythmservice', 'Replaces': 'com.niubiprass.minisight.rhythmservice'}
                    wrong = {'wrong-arch': 'Architecture', 'wrong-version': 'Version', 'external-depends': 'Depends',
                      'bad-provides': 'Provides', 'bad-conflicts': 'Conflicts', 'bad-replaces': 'Replaces', 'wrong-package': 'Package'}
                    if failure in wrong: fields[wrong[failure]] = 'incorrect'
                    return fields[cmd[3]]
                if cmd[:2] == ['dpkg-deb', '--fsys-tarfile']: return archive(built, failure)
                if cmd[:2] == ['dpkg-deb', '--ctrl-tarfile']:
                    return archive({'control': b'mock', **({'postinst': b'exit 0'} if failure == 'control-script' else {})})
                raise AssertionError(('unexpected command, NOT executed', cmd))
            failed = False
            env = {'CI': 'false' if failure == 'local-refused' else 'true', 'MINISIGHT_RHYTHM_CI_BUILD_APPROVED': '0' if failure == 'approval-refused' else '1'}
            argv = ['package_pair.py', '--service', str(service), '--output', str(out), '--mode', 'SOURCE' if failure == 'source-refused' else 'LIVE', '--scheme', 'unknown' if failure == 'scheme-refused' else scheme]
            if failure != 'build-refused': argv.append('--build')
            real_rename = Path.rename
            def checked_publish(src, dst):
                assert Path(dst) == out and not out.exists(), 'publish destination must be fresh'
                assert {x.name for x in src.iterdir()} == {'mock.deb', 'SINGLE-ARTIFACT.json', 'SHA256SUMS'}
                report = json.loads((src/'SINGLE-ARTIFACT.json').read_text())
                assert {x['target'] for x in report['required']} == {'MiniSight', 'MiniSightRhythmService'}
                assert all(x['native_checked'] for x in report['required'])
                digest = hashlib.sha256((src/'mock.deb').read_bytes()).hexdigest()
                assert report['sha256'] == digest and (src/'SHA256SUMS').read_text() == digest+'  mock.deb\n'
                if failure == 'publish-failure': raise OSError('mock atomic publish failure')
                return real_rename(src, dst)
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, env), patch('subprocess.run', fake_run), patch('subprocess.check_output', fake_output), patch.object(Path, 'rename', checked_publish), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                try: runpy.run_path(str(S/'scripts/package_pair.py'), run_name='__main__')
                except (AssertionError, RuntimeError, ValueError, OSError, KeyboardInterrupt, SystemExit): failed = True
            assert failed == bool(failure), (scheme, failure, failed)
            if not failure:
                m = json.loads((out/'SINGLE-ARTIFACT.json').read_text())
                assert m['single_deb'] and m['scheme'] == scheme and not m['device_validated']
                assert {x['target'] for x in m['required']} == {'MiniSight', 'MiniSightRhythmService'}
                assert len([x for x in calls if x[0] == 'make']) == 2
                assert all(x['native_checked'] for x in m['required'])
                assert len(list(out.glob('*.deb'))) == len((out/'SHA256SUMS').read_text().splitlines()) == 1
                assert len(list(out.iterdir())) == 3
            elif failure == 'stale': assert (out/'sentinel').read_text() == 'preserve' and not calls
            elif failure == 'output-symlink': assert out.is_symlink() and not calls
            else: assert not out.exists(), failure
            assert not list(base.glob('.minisight-single-*')), 'private partial staging leaked'
            cases.append({'scheme': scheme, 'failure': failure, 'passed': True})
    return cases
