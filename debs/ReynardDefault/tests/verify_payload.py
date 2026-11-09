#!/usr/bin/env python3
"""Never ship old signed bytes alongside newer editable source files."""
import hashlib, io, json, re, sys, zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
asset=ROOT/'layout/Library/ReynardDefault'
errors=[]
xpi=(asset/'handoff.xpi').read_bytes()
with zipfile.ZipFile(io.BytesIO(xpi)) as z:
    if z.testzip(): errors.append('XPI CRC failure')
    if not {'META-INF/mozilla.rsa','META-INF/manifest.mf'} <= set(z.namelist()): errors.append('AMO signature files missing')
    for name in ['manifest.json','handoff.js','background.js']:
        if name not in z.namelist(): errors.append('signed XPI missing '+name)
        elif z.read(name) != (asset/'handoff'/name).read_bytes(): errors.append('signed XPI differs from edited '+name)
    v=json.loads(z.read('manifest.json'))['version']
    expected=json.loads((asset/'handoff/manifest.json').read_text())['version']
    if v!=expected: errors.append(f'XPI version {v} != source {expected}')
    if ('kRDAddonVersion = @"'+expected+'"') not in (ROOT/'Common/RDExtensionInstall.h').read_text(): errors.append('installer version mismatch')
text=(ROOT/'Common/RDHandoffPayload.h').read_text()
m=re.search(r'kHandoffXpi\[\]\s*=\s*\{(.*?)\};',text,re.S)
if not m: errors.append('embedded XPI missing')
else:
    embedded=bytes(int(h,16) for h in re.findall(r'0x([0-9a-fA-F]{2})',m[1]))
    if embedded!=xpi: errors.append('embedded XPI differs from package XPI')
    if re.search(r'kHandoffXpiLen\s*=\s*(\d+)',text).group(1)!=str(len(xpi)): errors.append('embedded XPI length mismatch')
if errors:
    print('BLOCKED: signed payload is not ready for this candidate.');print('\n'.join('- '+e for e in errors));sys.exit(1)
print('PASS source/XPI/embedded bytes match; signature files present; cryptographic trust is separately verified by AMO/Gecko')
print('XPI sha256',hashlib.sha256(xpi).hexdigest())
