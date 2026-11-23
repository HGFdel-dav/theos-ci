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


base = json.loads((ROOT / 'docs/BASELINE-039-WIFI-ENTRY.json').read_text())
allowed = set(base['allowed_changes'])
need(base.get('base_commit') == '4f819236e3468c27acda3e1ff7bf49a0a976124a' and len(base['files']) == 143, 'published 0.3.8 freeze manifest')
for name, digest in base['files'].items():
    if name not in allowed:
        path = ROOT / name
        need(path.is_file() and sha(path) == digest, 'published 0.3.8 file changed: ' + name)
need(sha(ROOT / 'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m') == base['files']['LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m'], 'working data-module entry unchanged')
need(sha(ROOT / 'Cellular/LCSCellularService.m') == base['files']['Cellular/LCSCellularService.m'], 'SIM service unchanged')
need(sha(ROOT / 'LocalCleanStatusSIMTool/main.m') == base['files']['LocalCleanStatusSIMTool/main.m'], 'SIM helper unchanged')

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
need('NSObject <UIGestureRecognizerDelegate>' in hook and 'forwardInvocation:' not in hook and 'setOwner:' not in hook, 'independent public protocol; no forwarding or private owner')
need('shouldBeRequiredToFailByGestureRecognizer:' in hook and 'UIPanGestureRecognizer.class' in hook, 'WiFi-style failure dependency is present')
need('bound-wifi-entry' in hook and 'initWithTarget:self.target action:@selector(lcs_handlePress:)' in hook, 'standard long press attached to the native button')
need('self.directPress.delegate=self.target' in hook and 'cancelsTouchesInView=YES' in hook, 'own delegate and short-tap cancellation')
need('previewInteractionShouldBegin:' in hook and 'preview-shouldbegin-unavailable' in hook, 'preview gate is optional and failure is recorded')
need('contentViewController' not in hook and 'isExpanded' not in hook, 'does not depend on optional container getters')
need('containerWillTransitionToExpandedContentMode:' in hook, 'native expanded state is tracked via lifecycle')
need('windowPress' not in hook and 'LCSRoundBegin' not in hook and 'didMoveToWindow' not in hook, 'no window fallback or native round-button hook')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook, 'existing SIM card presentation retained')
need('UIApplicationWillResignActiveNotification' in hook and 'UIApplicationDidBecomeActiveNotification' in hook, 'foreground cleanup and rebind retained')

print(f'PASS cellular WiFi-entry source contract: {checks}; frozen 0.3.8 files {len(base["files"])-len(allowed & set(base["files"]))}; no UIKit/runtime/device claim.')
