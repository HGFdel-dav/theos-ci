#!/usr/bin/env python3
"""Preference routing contract; does not execute Apple's loader or instantiate UI."""
from pathlib import Path
import plistlib

PANELS = ('LocalCleanStatusRoot.plist', 'LocalCleanStatusAnimations.plist',
          'LocalCleanStatusAnimationsAdvanced.plist')
ROUTES = (
    ('LocalCleanStatusRoot.plist', 'localCleanStatusAnimations',
     'LocalCleanStatusAnimationsController', 'LocalCleanStatusAnimations.plist'),
    ('LocalCleanStatusAnimations.plist', 'animationAdvanced',
     'LocalCleanStatusAnimationAdvancedController', 'LocalCleanStatusAnimationsAdvanced.plist'),
)

def validate_route_data(entry, info, panels, controller_names=None):
    def require(ok, reason):
        if not ok:
            raise ValueError(reason)
    require(entry.get('cell') == 'PSLinkCell', 'top entry must be a PSLinkCell')
    require(entry.get('bundle') == info.get('CFBundleExecutable') == 'LocalCleanStatusPrefs',
            'top entry must retain its bundle loader target')
    require(entry.get('detail') == info.get('NSPrincipalClass') == 'LocalCleanStatusRootListController',
            'top entry and principal controller disagree')
    require(entry.get('isController') is True, 'top entry controller flag missing')
    for filename in PANELS:
        require(filename in panels and isinstance(panels[filename].get('items'), list),
                'missing panel resource: ' + filename)
    for filename, identifier, controller, target in ROUTES:
        rows = [row for row in panels[filename]['items'] if row.get('id') == identifier]
        require(len(rows) == 1, 'expected exactly one subpage entry: ' + identifier)
        row = rows[0]
        require(row.get('cell') == 'PSLinkCell' and row.get('detail') == controller,
                'wrong same-bundle controller: ' + identifier)
        require(row.get('isController') is True, 'subpage controller flag missing: ' + identifier)
        require(bool(row.get('label')), 'subpage label missing: ' + identifier)
        for key in ('bundle', 'bundlePath', 'lazy-bundle'):
            require(key not in row, 'same-bundle subpage must not request another bundle: ' + identifier + '/' + key)
        require(target in panels, 'subpage resource missing: ' + target)
        if controller_names is not None:
            require(controller in controller_names, 'subpage class missing: ' + controller)
    return len(ROUTES)

def validate_panel_routes(bundle, loader, controller_names=None):
    bundle, loader = Path(bundle), Path(loader)
    info = plistlib.loads((bundle/'Info.plist').read_bytes())
    entry = plistlib.loads(loader.read_bytes())['entry']
    panels = {name: plistlib.loads((bundle/name).read_bytes()) for name in PANELS}
    return validate_route_data(entry, info, panels, controller_names)
