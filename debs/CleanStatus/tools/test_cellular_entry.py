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
            'UIWindow alloc','method_setImplementation','sendActionsForControlEvents:',
            'cancelInteraction','setUserInteractionEnabled:']:
    need(bad not in hook, 'retired or broad interception forbidden: ' + bad)
need('LCSRoundGestureShouldBegin' in hook and 'LCSCellularOwnsRoundGesture(self,gesture)' in hook, 'native round-button hook is scoped to the own cellular recognizer')
need('BOOL local=cellular&&state&&[state.target gestureRecognizerShouldBegin:gesture];' in hook and 'LCSRoundButtonAllowsGesture(cellular,original,local)' in hook and 'BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);' in hook, 'round-button checks owned target and forwards original result for other gestures')
need('round-local-hook-installed' in hook and 'round-button-image-unverified' in hook, 'round-button hook validates image and reports failures')
need('gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:' in hook, 'own recognizer supplies the failure rule')
need('return ![other isKindOfClass:UIPanGestureRecognizer.class];' in hook, 'exact WiFi pan/tap rule')
need('shouldRecognizeSimultaneouslyWithGestureRecognizer:' in hook and re.search(r'- \(BOOL\)gestureRecognizer:[^\n]*shouldRecognizeSimultaneouslyWithGestureRecognizer:[^\n]*\{.*?return NO;\s*\}',hook,re.S), 'no simultaneous recognition; diagnostics do not alter result')
need('[button addGestureRecognizer:self.directPress]' in hook, 'primary recognizer on the native button, not the whole window')
need('[window addGestureRecognizer:self.windowPress]' in hook, 'one passive fallback recognizer attached only to the hosting window')
need('CGRectContainsPoint(CGRectInset(state.button.bounds,-8,-10),point)' in hook, 'fallback touch must land inside the cellular button region')
need('LCSCellularWindowFallbackAllows(YES,LCSDirectTouch(state.button),YES,' in hook, 'fallback receives raw direct-touch parameter; helper alone negates it')
need('LCSCellularWindowFallbackAllows(YES,!LCSDirectTouch' not in hook, 'no reversed real call arguments')
need('LCSCellularWindowFallbackAllows' in hook and 'usingWindowFallback' in (ROOT/'Cellular/LCSCellularEntryPolicy.h').read_text(), 'fallback activation is a pure production predicate')
need('self.directPress.delegate=self.target' in hook and 'self.windowPress.delegate=self.target' in hook, 'retained independent delegate for both recognizers')
assignments = re.findall(r'([A-Za-z_][\w.]*)\.delegate\s*=(?!=)', hook)
need(all(v in ('self.directPress','self.windowPress') for v in assignments), 'native gesture delegates are not changed')
need('previewInteractionShouldBegin:' in hook and 'preview-shouldbegin-unavailable' in hook, 'preview path optional and self-diagnosing')
need('contentViewController' not in hook and 'isExpanded' not in hook, 'no dependency on optional getters')
need('LCSPreviewShouldBegin' in hook and 'return LCSOriginalPreviewShouldBegin(self,sel,interaction);' in hook, 'unowned preview calls forward exactly')
need('press.numberOfTouches==0' in hook and 'locationInCoordinateSpace:self.button' in hook, 'preview scope uses live cellular touch/point from the active recognizer')
need('UILongPressGestureRecognizer *press=LCSDirectTouch(self.button)?self.directPress:self.windowPress;' in hook, 'preview checks the recognizer that is actually active')
need('self.controller.view isDescendantOfView:container.view' in hook, 'preview container must host the cellular controller')
need('CGRectContainsPoint(CGRectInset(self.button.bounds,-8,-10),point)' in hook, 'preview point remains within the button region')
need('containerWillTransitionToExpandedContentMode:' in hook and 'state.expanded=expanded' in hook, 'native expansion state is tracked')
need('bound-wifi-entry' in hook and 'began-wifi' in hook and 'round-local-hook-installed' in hook and 'round-button-allowed' in hook, 'round-button allow hook and direct-entry state are observable')
need('gestureRecognizerShouldBegin:' in hook and 'setOwner:' not in hook and 'forwardInvocation:' not in hook, 'no private recognizer ownership or delegate forwarding')
need('UIApplicationWillResignActiveNotification' in hook and 'UIApplicationDidBecomeActiveNotification' in hook, 'foreground cleanup/rebind')
base = json.loads((ROOT / 'docs/BASELINE-0314-UNIFIED-EXPANSION.json').read_text())
for name in ['Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m',
             'LocalCleanStatusSIMTool/main.m','LocalCleanStatusSIMTool/entitlements.plist',
             'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m']:
    need(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == base['files'][name], 'protected behaviour unchanged: ' + name)
cc=(ROOT/'Sources/LocalCleanStatusControlCenter.m').read_text()
need('if(!expanded)[state bind];' in cc and 'if(expanded)[lcscc_presentedList close]' not in cc,'Wi-Fi/BT list remains open through the native expansion transition')
need('return weakSelf.controller!=nil;' in cc and '!weakSelf.expanded' not in cc,'Wi-Fi/BT list continuation does not reject expanded layout')
print(f'PASS WiFi-style entry adapter contracts: {checks}; UIKit/device arbitration NOT executed.')
