#!/usr/bin/env python3
"""Compare against the exact 0.2.5 source tree; not runtime verification."""
from pathlib import Path
import hashlib, json, sys
root = Path(__file__).resolve().parents[1]
baseline = Path(sys.argv[1]) if len(sys.argv) > 1 else root.parent/'research/baseline-0.2.5'
allowed = {
    'Makefile', 'control', 'STATUS.md',
    'LocalCleanStatusPrefs/Makefile',
    'LocalCleanStatusPrefs/Resources/Info.plist',
    'LocalCleanStatusPrefs/Resources/LocalCleanStatusRoot.plist',
    'LocalCleanStatusSystemActions/Resources/Info.plist',
    'tools/check.py', 'tools/verify_deb.py', 'tools/package_source.py',
}
protected, changed, failures = [], [], []
manifest = json.loads((root/'docs/BASELINE-0.2.5-PROTECTED.json').read_text())
for name, expected in manifest['protected_sources'].items():
    current = root/name
    if not current.is_file() or hashlib.sha256(current.read_bytes()).hexdigest() != expected:
        failures.append(name+' differs from protected baseline hash')
for f in sorted(baseline.rglob('*')):
    if not f.is_file(): continue
    name = f.relative_to(baseline).as_posix()
    current = root/name
    same = current.is_file() and f.read_bytes() == current.read_bytes()
    if same: protected.append(name)
    elif name in allowed: changed.append(name)
    else: failures.append(name)
# Every original setting remains in its order, with identical behavior metadata.
import plistlib
old = manifest['original_root_items']
new = plistlib.loads((root/'LocalCleanStatusPrefs/Resources/LocalCleanStatusRoot.plist').read_bytes())['items']
pos = 0
for item in new:
    if pos < len(old) and item == old[pos]: pos += 1
if pos != len(old): failures.append('original preference rows modified/removed/reordered')
print(json.dumps({'protected_original_files':len(protected),'allowed_changed':changed,'failures':failures}, ensure_ascii=False, indent=2))
if failures: raise SystemExit(1)
print('PASS original feature sources and preference rows preserved against exact 0.2.5')
