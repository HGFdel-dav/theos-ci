#!/usr/bin/env python3
"""Source contract checks for 0.3.10 WiFi-style cellular entry; no UIKit runtime claim."""
from pathlib import Path
import hashlib, json, plistlib

ROOT = Path(__file__).resolve().parents[1]
checks = 0


def need(value, label):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


base = json.loads((ROOT / 'docs/BASELINE-0315-ENTRY-BINDING-FALLBACK.json').read_text())
allowed = set(base['allowed_changes'])
need(base.get('base_version') == '0.3.14' and len(base['files']) == 160, 'published 0.3.14 frozen source manifest')
for name, digest in base['files'].items():
    if name not in allowed:
        path = ROOT / name
        need(path.is_file() and sha(path) == digest, 'published 0.3.13 protected file changed: ' + name)
need(sha(ROOT / 'Cellular/LCSCellularService.m') == base['files']['Cellular/LCSCellularService.m'], 'SIM service unchanged')
need(sha(ROOT / 'LocalCleanStatusSIMTool/main.m') == base['files']['LocalCleanStatusSIMTool/main.m'], 'SIM helper unchanged')
need(sha(ROOT / 'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m') == base['files']['LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m'], 'DataSwitch module unchanged')

service = (ROOT / 'Cellular/LCSCellularService.m').read_text()
helper = (ROOT / 'LocalCleanStatusSIMTool/main.m').read_text()
read_start = service.index('        if(self.kind==LCSCellularDataSwitch) {')
read_end = service.index('        } else {', read_start)
need(hashlib.sha256(service[read_start:read_end].encode()).hexdigest() == '10a782a4899f55cea93f5e3ded26f4b5dc2ee13f8542f878b2ae62fe0df89c0f', '0.3.8 data read branch byte-identical')
write_start = service.index('            if(self.kind==LCSCellularDataSwitch) {')
write_end = service.index('            NSString *tool=', write_start)
need(hashlib.sha256(service[write_start:write_end].encode()).hexdigest() == '2cab743ec3061facd89a6d6734f0324541be81c33becbff9369e60e067333299', '0.3.8 data write branch byte-identical')
need('getSIMStatus:error:' in service and 'copyLabel:error:' in service and 'kCTSIMSupportSIMStatusReady' in service, 'SIM manager lists subscription state')
need('LCSPlanManager' not in service and 'planItemsShouldUpdate' not in service, 'SpringBoard does not call plan manager')
need('LCSHelperFailureReason' in service and all(x in service for x in ['helper-plan-api','helper-identity','helper-unusable','helper-plan-changed']), 'helper refusal stages stay diagnosable')
need('getSubscriptionContextUUIDforPlan:' in helper and 'LCSHelperPlanUUID' in helper and 'LCSHelperUnique(manager,latest,identity)' in helper, 'helper maps subscription UUID to plan')
ent = plistlib.loads((ROOT / 'LocalCleanStatusSIMTool/entitlements.plist').read_bytes())
need(ent.get('com.apple.coretelephony.CTDataPlanDeviceInfo.allow') is True, 'helper plan entitlement unchanged')

hook = (ROOT / 'Cellular/LCSCellularHooks.m').read_text()
need('- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture' in hook and 'return [self.binding shouldBeginPressedGesture:gesture];' in hook, 'independent recognizer target implements the hook callback')
need('LCSRoundButtonAllowsGesture(cellular,original,local)' in hook and 'BOOL local=cellular&&state&&[state.target gestureRecognizerShouldBegin:gesture];' in hook, 'round hook calls the target callback it expects')
need('- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture' in hook and 'return [self.binding shouldBeginPressedGesture:gesture];' in hook, 'independent target implements the callback called by round hook')
need('LCSRoundGestureShouldBegin' in hook and 'BOOL cellular=LCSCellularOwnsRoundGesture(self,gesture);' in hook and 'BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);' in hook and 'LCSRoundButtonAllowsGesture(cellular,original,local)' in hook, 'CCUIRoundButton only alters own cellular gesture and forwards other result')
need('round-local-hook-installed' in hook and 'round-button-image-unverified' in hook, 'round gate checks source image and logs result')
need('shouldBeRequiredToFailByGestureRecognizer:' in hook and 'UIPanGestureRecognizer.class' in hook, 'WiFi-style failure dependency is present')
need('bound-wifi-entry' in hook and 'initWithTarget:self.target action:@selector(lcs_handlePress:)' in hook, 'standard long press attached to the native button')
need('self.directPress.delegate=self.target' in hook and 'cancelsTouchesInView=YES' in hook, 'own delegate and short-tap cancellation')
need('previewInteractionShouldBegin:' in hook and 'preview-shouldbegin-unavailable' in hook, 'preview gate is optional and failure is recorded')
need('contentViewController' not in hook and 'isExpanded' not in hook, 'does not depend on optional container getters')
need('containerWillTransitionToExpandedContentMode:' in hook, 'native expanded state is tracked via lifecycle')
need('LCSRoundBegin' not in hook and 'if(state&&state.button==self)[state bind];' in hook, 'only already marked cellular button is synchronized on window lifecycle')
need(hook.count('self.windowPress=[[UILongPressGestureRecognizer alloc]')==1 and 'bound-window-fallback' in hook, 'one region-limited fallback recognizer at most')
need('if(!window||self.windowPress)return;' in hook and 'self.windowPress.cancelsTouchesInView=NO' in hook, 'fallback is passive; direct-capable and out-of-region touches still refused')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook, 'existing SIM card presentation retained')
need('UIApplicationWillResignActiveNotification' in hook and 'UIApplicationDidBecomeActiveNotification' in hook, 'foreground cleanup and rebind retained')

print(f'PASS cellular WiFi-entry source contract: {checks}; frozen 0.3.11 files {len(base["files"])-len(allowed & set(base["files"]))}; no UIKit/runtime/device claim.')
