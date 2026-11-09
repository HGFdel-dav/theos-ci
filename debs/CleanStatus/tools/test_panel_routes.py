#!/usr/bin/env python3
"""Real panel fixtures plus invalid routes. Static contract, not UIKit execution."""
from pathlib import Path
from copy import deepcopy
import plistlib, re
from panel_routes import PANELS, validate_route_data

root = Path(__file__).resolve().parents[1]
resources = root/'LocalCleanStatusPrefs/Resources'
entry = plistlib.loads((root/'layout/Library/PreferenceLoader/Preferences/LocalCleanStatusPrefs.plist').read_bytes())['entry']
info = plistlib.loads((resources/'Info.plist').read_bytes())
panels = {name: plistlib.loads((resources/name).read_bytes()) for name in PANELS}
classes = set(re.findall(r'@interface\s+(\w+)\s*:', '\n'.join(p.read_text() for p in (root/'LocalCleanStatusPrefs').glob('*.h'))))
assert validate_route_data(entry, info, panels, classes) == 2
count = 1

def reject(label, change):
    global count
    e, i, p, c = deepcopy((entry, info, panels, classes))
    change(e, i, p, c)
    try:
        validate_route_data(e, i, p, c)
    except ValueError:
        count += 1
    else:
        raise AssertionError('invalid route accepted: ' + label)

def row(p, filename, identifier):
    return next(x for x in p[filename]['items'] if x.get('id') == identifier)

for filename, identifier in (
    ('LocalCleanStatusRoot.plist', 'localCleanStatusAnimations'),
    ('LocalCleanStatusAnimations.plist', 'animationAdvanced'),
):
    # Reproduce the exact extra bundle key shipped in 0.3.0 on each subpage.
    reject('0.3.0 duplicate bundle ' + identifier,
           lambda e, i, p, c, f=filename, n=identifier: row(p, f, n).update(bundle='LocalCleanStatusPrefs'))
    reject('wrong explicit path ' + identifier,
           lambda e, i, p, c, f=filename, n=identifier: row(p, f, n).update(bundlePath='/missing.bundle'))
    reject('missing controller ' + identifier,
           lambda e, i, p, c, f=filename, n=identifier: row(p, f, n).update(detail='MissingController'))
reject('top-level bundle accidentally removed', lambda e, i, p, c: e.pop('bundle'))
reject('missing advanced resource', lambda e, i, p, c: p.pop('LocalCleanStatusAnimationsAdvanced.plist'))
reject('missing compiled controller declaration', lambda e, i, p, c: c.remove('LocalCleanStatusAnimationsController'))
print(f'PASS panel routing: {count} source/resource positive and negative cases; no UIKit runtime test')
