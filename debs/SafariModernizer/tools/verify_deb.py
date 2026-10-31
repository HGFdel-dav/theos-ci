#!/usr/bin/env python3
"""Extract/read a DEB for static verification; never install or run its scripts."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from verify_macho import verify as verify_macho
from verify_signature import verify as verify_signature

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('package', type=Path)
parser.add_argument('--json', type=Path)
args = parser.parse_args()
package = args.package.resolve()
inputs = json.loads((ROOT / 'BUILD-INPUTS.json').read_text())
report = {'stage': 'DEB_static_only', 'passed': False, 'package_sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'errors': []}
def check(ok, message):
    if not ok:
        report['errors'].append(message)
def bundles(data):
    if data.startswith(b'bplist') or data.lstrip().startswith(b'<?xml'):
        return plistlib.loads(data).get('Filter', {}).get('Bundles', [])
    match = re.search(rb'Bundles\s*=\s*\((.*?)\)', data, re.S)
    return [v.decode() for v in re.findall(rb'"([^"]+)"', match[1])] if match else []
try:
    with tempfile.TemporaryDirectory(prefix='sm-verify-') as tmp:
        tmp = Path(tmp)
        for option, dest in [('-e', tmp / 'control'), ('-x', tmp / 'data')]:
            subprocess.run(['dpkg-deb', option, str(package), str(dest)], check=True, timeout=60, capture_output=True)
        control = (tmp / 'control/control').read_text()
        fields = dict(re.findall(r'^([A-Za-z-]+): (.*)$', control, re.M))
        report['control'] = {key: fields.get(key) for key in ['Package', 'Version', 'Architecture', 'Depends']}
        for key, expected in [('Package', inputs['package']), ('Version', inputs['version']), ('Architecture', 'iphoneos-arm64e')]:
            check(fields.get(key) == expected, 'Wrong control field: ' + key)
        check('firmware (>= 15.0), firmware (<< 16.0)' in fields.get('Depends', ''), 'Wrong firmware constraints')
        scripts = [p.name for p in (tmp / 'control').iterdir() if p.name in ['preinst', 'postinst', 'prerm', 'postrm', 'config', 'triggers']]
        check(not scripts, 'Unexpected maintainer script/trigger requires manual review: ' + ', '.join(scripts))
        payload = tmp / 'data'
        files = [str(p.relative_to(payload)) for p in payload.rglob('*') if p.is_file() or p.is_symlink()]
        report['payload_files'] = sorted(files)
        expected = {'Library/MobileSubstrate/DynamicLibraries/SafariModernizer.dylib',
                    'Library/MobileSubstrate/DynamicLibraries/SafariModernizer.plist',
                    'usr/share/doc/com.t4mag0.safarimodernizer/LICENSE',
                    'usr/share/doc/com.t4mag0.safarimodernizer/THIRD_PARTY_LICENSES.txt'}
        check(set(files) == expected, 'Payload is not the expected native RootHide layout')
        check(not any(p.is_symlink() for p in payload.rglob('*')), 'Unexpected payload symlink requires manual review')
        dylib = payload / 'Library/MobileSubstrate/DynamicLibraries/SafariModernizer.dylib'
        plist = dylib.with_suffix('.plist')
        if plist.is_file():
            check(bundles(plist.read_bytes()) == bundles((ROOT / 'tweak/SafariModernizer.plist').read_bytes()), 'Browser injection scope changed')
        if dylib.is_file():
            report['macho'] = verify_macho(str(dylib))
            report['signature'] = verify_signature(str(dylib))
            check(report['macho']['passed'], 'Mach-O/PAC artifact gate failed')
            check(report['signature']['passed'], 'CodeDirectory page-integrity gate failed')
        else:
            check(False, 'Missing dylib')
except (OSError, ValueError, subprocess.SubprocessError) as error:
    report['errors'].append('Cannot statically inspect package: ' + str(error))
report['passed'] = not report['errors']
if args.json:
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(not report['passed'])
