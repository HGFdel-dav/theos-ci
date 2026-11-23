#!/usr/bin/env python3
"""Entry adapter contracts for the WiFi-style cellular route. No UIKit execution."""
from pathlib import Path
import hashlib, json, re
ROOT = Path(__file__).resolve().parents[1]
hook = (ROOT / 'Cellular/LCSCellularHooks.m').read_text()
checks = 0

def need(value, label):
    global checks
    if not value: raise AssertionError(label)
    checks += 1

interfaces = re.findall(r'@interface\s+(\w+)\s*:\s*(\w+)', hook)
need(len(interfaces) == 2 and all(base == 'NSObject' for _, base in interfaces), 'no UIKit/recognizer subclass')
for bad in ['objc_allocateClassPair','forwardInvocation:','forwardingTargetForSelector:','setOwner:',
            'windowPress','UIWindow alloc','method_setImplementation','sendActionsForControlEvents:',
            'cancelInteraction','setUserInteractionEnabled:']:
    need(bad not in hook, 'retired or broad interception forbidden: ' + bad)
need('"gestureRecognizerShouldBegin:"' not in hook, 'no native round-button method hook')
need('gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:' in hook, 'own recognizer supplies the failure rule')
need('return ![other isKindOfClass:UIPanGestureRecognizer.class];' in hook, 'exact WiFi pan/tap rule')
need('shouldRecognizeSimultaneouslyWithGestureRecognizer:' in hook and '(void)gesture;(void)other;return NO;' in hook, 'no simultaneous recognition')
need('[button addGestureRecognizer:self.directPress]' in hook, 'recognizer on the native button, not the whole window')
need('self.directPress.delegate=self.target' in hook, 'retained independent delegate')
assignments = re.findall(r'([A-Za-z_][\w.]*)\.delegate\s*=(?!=)', hook)
need(all(v in ('self.directPress',) for v in assignments), 'native gesture delegates are not changed')
need('previewInteractionShouldBegin:' in hook and 'preview-shouldbegin-unavailable' in hook, 'preview path optional and self-diagnosing')
need('contentViewController' not in hook and 'isExpanded' not in hook, 'no dependency on optional getters')
need('LCSPreviewShouldBegin' in hook and 'return LCSOriginalPreviewShouldBegin(self,sel,interaction);' in hook, 'unowned preview calls forward exactly')
need('self.directPress.numberOfTouches==0' in hook and 'locationInCoordinateSpace:self.button' in hook, 'preview scope uses live cellular touch/point')
need('self.controller.view isDescendantOfView:container.view' in hook, 'preview container must host the cellular controller')
need('CGRectContainsPoint(CGRectInset(self.button.bounds,-8,-10),point)' in hook, 'preview point remains within the button region')
need('containerWillTransitionToExpandedContentMode:' in hook and 'state.expanded=expanded' in hook, 'native expansion state is tracked')
need('bound-wifi-entry' in hook and 'began-wifi' in hook, 'entry path is visible in diagnostics')
need('UIApplicationWillResignActiveNotification' in hook and 'UIApplicationDidBecomeActiveNotification' in hook, 'foreground cleanup/rebind')
base = json.loads((ROOT / 'docs/BASELINE-039-WIFI-ENTRY.json').read_text())
for name in ['Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m',
             'LocalCleanStatusSIMTool/main.m','LocalCleanStatusSIMTool/entitlements.plist',
             'Sources/LocalCleanStatusControlCenter.m','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m']:
    need(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == base['files'][name], 'protected behaviour unchanged: ' + name)
print(f'PASS WiFi-style entry adapter contracts: {checks}; UIKit/device arbitration NOT executed.')
