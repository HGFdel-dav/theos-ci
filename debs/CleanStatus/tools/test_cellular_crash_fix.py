#!/usr/bin/env python3
"""Source contract checks for 0.3.9 cellular entry; not UIKit/runtime/device proof."""
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


base = json.loads((ROOT / 'docs/BASELINE-038-ENTRY.json').read_text())
allowed = set(base['allowed_changes'])
need(base.get('base_commit') == '4f819236e3468c27acda3e1ff7bf49a0a976124a' and len(base['files']) == 143, 'published 0.3.8 freeze manifest')
for name, digest in base['files'].items():
    if name not in allowed:
        path = ROOT / name
        need(path.is_file() and sha(path) == digest, 'published 0.3.8 file changed: ' + name)
need(sha(ROOT / 'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m') == base['files']['LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m'], 'working data-module entry unchanged')
need(sha(ROOT / 'Sources/LocalCleanStatusControlCenter.m') == base['files']['Sources/LocalCleanStatusControlCenter.m'], 'Wi-Fi and Bluetooth entry source unchanged')

service = (ROOT / 'Cellular/LCSCellularService.m').read_text()
helper = (ROOT / 'LocalCleanStatusSIMTool/main.m').read_text()
read_start = service.index('        if(self.kind==LCSCellularDataSwitch) {')
read_end = service.index('        } else {', read_start)
need(hashlib.sha256(service[read_start:read_end].encode()).hexdigest() == '10a782a4899f55cea93f5e3ded26f4b5dc2ee13f8542f878b2ae62fe0df89c0f', '0.3.7 data read branch byte-identical')
write_start = service.index('            if(self.kind==LCSCellularDataSwitch) {')
write_end = service.index('            NSString *tool=', write_start)
need(hashlib.sha256(service[write_start:write_end].encode()).hexdigest() == '2cab743ec3061facd89a6d6734f0324541be81c33becbff9369e60e067333299', '0.3.7 data write branch byte-identical')
need('LCSPlanManager' not in service and 'planItemsShouldUpdate' not in service, 'SpringBoard no longer calls the entitlement-gated plan manager')
need('getSIMStatus:error:' in service and 'copyLabel:error:' in service and 'kCTSIMSupportSIMStatusReady' in service, 'SIM manager lists subscription status and label')
need('line.identity=uuid;line.stateKnown=unique&&statusKnown' in service and 'line.enabled=ready;line.available=line.stateKnown' in service, 'SIM line state derives from subscription context and SIM status')
need('LCSHelperFailureReason' in service and all(x in service for x in ['helper-plan-api','helper-identity','helper-unusable','helper-plan-changed']), 'helper refusal stage is recorded without identity text')
need('getSubscriptionContextUUIDforPlan:' in helper and 'LCSHelperPlanUUID' in helper and 'LCSHelperUnique(manager,latest,identity)' in helper, 'entitled helper maps subscription UUID to plan')
need('"iccid"' not in helper, 'helper no longer matches a plan by ICCID')
ent = plistlib.loads((ROOT / 'LocalCleanStatusSIMTool/entitlements.plist').read_bytes())
need(ent.get('com.apple.coretelephony.CTDataPlanDeviceInfo.allow') is True, 'helper declares the minimal plan-info entitlement')
need(ent.get('com.apple.CommCenter.fine-grained') == ['cellular-plan', 'spi', 'preferences-write'], 'existing helper permissions unchanged')

hook = (ROOT / 'Cellular/LCSCellularHooks.m').read_text()
need('LCSOriginalLayout(self,sel)' in hook and 'viewDidLayoutSubviews' in hook and 'scheduleLayoutRebind' in hook, 'native controller layout triggers rebind')
need('LCSRequiredHookMask=39U' in hook and 'layout-hook-unavailable' in hook and 'layout-hook-installed' in hook, 'layout hook is required, reports failures and logs success')
need('now-self.lastLayoutRetry<.25' in hook, 'layout-triggered retry is throttled')
need('self.directPress.view==self.localHost&&LCSEntryEligible([self entryGates])' in hook, 'eligible local binding avoids repeated subtree scans')
need('LCSHasAnyGesture(button,0)' not in hook, 'existing system recognizers do not hard-disable long press')
need('LCSTapContract(button)' in hook and 'cancelsTouchesInView=YES' in hook, 'stock short tap safety remains')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook, 'long press still presents the SIM manager')
need('UIApplicationWillResignActiveNotification' in hook and 'viewDidDisappear:' in hook, 'dismiss and foreground cleanup remain')

print(f'PASS cellular-entry source contract: {checks}; frozen 0.3.8 files {len(base["files"])-len(allowed & set(base["files"]))}; no UIKit/runtime/device claim.')
