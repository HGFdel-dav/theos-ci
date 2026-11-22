#!/usr/bin/env python3
"""Source contract checks for the 0.3.7 layout-rebind change; not UIKit runtime proof."""
from pathlib import Path
import hashlib, json, re
ROOT = Path(__file__).resolve().parents[1]
checks = 0
def need(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
base = json.loads((ROOT / 'docs/BASELINE-036-RUNTIME.json').read_text())
allowed = {
    'Cellular/LCSCellularHooks.m', 'tools/test_cellular_crash_fix.py',
    'tools/check_cellular.py', 'tools/check.py', 'tools/verify_deb.py',
    'tools/test_cellular_path_reuse.py', 'tools/test_cellular_ui.py',
    'tools/syntax_cellular.py', 'tools/package_source.py',
    'control', 'LocalCleanStatusPrefs/Resources/Info.plist',
    'LocalCleanStatusDataSwitch/Resources/Info.plist',
    'docs/BASELINE-036-RUNTIME.json', 'STATUS.md'
}
need(base.get('base_commit') == '869ddd0737f0c878322ef4ab9b2015632f952b7f' and len(base['files']) == 141, 'published 0.3.6 freeze manifest')
for name, digest in base['files'].items():
    if name not in allowed:
        path = ROOT / name
        need(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'published 0.3.6 file changed: ' + name)
need(hashlib.sha256((ROOT/'Cellular/LCSCellularService.m').read_bytes()).hexdigest() == base['files']['Cellular/LCSCellularService.m'], 'working data-service implementation unchanged')
need(hashlib.sha256((ROOT/'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m').read_bytes()).hexdigest() == base['files']['LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m'], 'working data-module entry unchanged')
hook = (ROOT/'Cellular/LCSCellularHooks.m').read_text()
need('LCSOriginalLayout(self,sel)' in hook and 'viewDidLayoutSubviews' in hook and 'scheduleLayoutRebind' in hook, 'native controller layout triggers rebind')
need('LCSRequiredHookMask=39U' in hook and 'layout-hook-unavailable' in hook and 'layout-hook-installed' in hook,'layout hook is required, reports failures and logs success')
need('now-self.lastLayoutRetry<.25' in hook, 'layout-triggered retry is throttled')
need('self.directPress&&self.button.window==self.boundWindow&&LCSVisible(self.button)' in hook, 'visible live button avoids repeated subtree scans')
need('button-not-visible' in hook and 'button-not-found' in hook, 'hidden/missing button failures stay diagnosable')
need('LCSHasAnyGesture(button,0)' not in hook, 'existing system recognizers do not hard-disable long press')
need('LCSTapContract(button)' in hook and 'cancelsTouchesInView=YES' in hook, 'stock short tap safety remains')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook, 'long press still presents the SIM manager')
need('UIApplicationWillResignActiveNotification' in hook and 'viewDidDisappear:' in hook, 'dismiss and foreground cleanup remain')
print(f'PASS layout-rebind source contract: {checks}; frozen 0.3.6 files {len(base["files"])-len(allowed)}; no UIKit/runtime/device claim.')
