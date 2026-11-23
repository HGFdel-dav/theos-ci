#!/usr/bin/env python3
"""Entry adapter contracts plus actual portable production-policy execution.
Neither source checks nor this host executable validate UIKit's gesture arbitration.
"""
from pathlib import Path
import json,re,subprocess,tempfile,hashlib,sys
ROOT=Path(__file__).resolve().parents[1]
hook=(ROOT/'Cellular/LCSCellularHooks.m').read_text()
checks=0

def need(value,label):
    global checks
    if not value: raise AssertionError(label)
    checks+=1

interfaces=re.findall(r'@interface\s+(\w+)\s*:\s*(\w+)',hook)
need(len(interfaces)==2 and all(base=='NSObject' for _,base in interfaces),'no UIKit/recognizer subclass')
for bad in ['objc_allocateClassPair','forwardInvocation:','forwardingTargetForSelector:','setOwner:',
            'windowPress','UIWindow alloc','method_setImplementation','sendActionsForControlEvents:',
            'cancelInteraction','setUserInteractionEnabled:']:
    need(bad not in hook,'retired or broad interception forbidden: '+bad)
need('"gestureRecognizerShouldBegin:"' not in hook,'no native round-button method hook')
need('[hostView addGestureRecognizer:self.directPress]' in hook,'single local or fallback recognizer host')
need('if(v==content)break' in hook and '![v isDescendantOfView:content]' in hook,'host cannot climb outside the native module')
need('LCSConnectivityImage(object_getClass(content))' in hook,'module content belongs to original connectivity image')
need('LCSEntryReceive(&attempt' in hook and 'related=hit&&' in hook,'touch hit relationship and exact region are both checked')
need('LCSEntryPreviewWait(&attempt' in hook and 'locationInCoordinateSpace:self.button' in hook,'preview scope uses real touch coordinates')
need('container!=self.moduleContainer' in hook and 'LCSCellularObject(container,"previewInteraction")!=interaction' in hook,'other containers/interactions always retain original decision')
need('return LCSOriginalPreviewShouldBegin(self,sel,interaction);' in hook,'unhandled native preview forwards exactly')
need('gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:' in hook and 'prioritiseGesture:' in hook,'native short gestures use the configured failure direction')
need('other.delegate==(id)self.button||other.delegate==(id)self.moduleContainer' in hook and 'isKindOfClass:UILongPressGestureRecognizer.class' in hook and 'UIPanGestureRecognizer.class' in hook,'bounded native long-press/pan scope only')
need('self.directPress.delegate=self.target' in hook,'retained independent own delegate')
assignments=re.findall(r'([A-Za-z_][\w.]*)\.delegate\s*=(?!=)',hook)
need(all(v=='self.directPress' for v in assignments),'native gesture delegates are not changed')
need('LCSCellularMethod(cls,sel_registerName("isExpanded"),"B",0,NULL)' in hook,'native mode getter signature checked')
need('LCSInstall(cls,"previewInteractionShouldBegin:","B",1,object' in hook,'preview instance method exact argument/return gate')
need('numberOfTouchesRequired=1' in hook and 'minimumPressDuration=.45' in hook and 'allowableMovement=10' in hook,'ordinary one-finger long press')
need('LCSEntryCancel(&attempt)' in hook and 'state.bindingTicket==ticket' in hook,'cancel and obsolete-binding callbacks fenced')
need('UIApplicationWillResignActiveNotification' in hook and 'UIApplicationDidBecomeActiveNotification' in hook,'foreground lifecycle cleans and rebinds')
need('bound-legacy-fallback' in hook and 'legacyAllowed' in hook,'new entry keeps old button path as fallback')
need('entryStale' in hook and 'resetEntry' in hook,'early release clears the active touch ticket')
need('UIControlEventTouchDownRepeat' in hook and 'LCSTapContract(button)' in hook,'early-action short tap controls are not intercepted')
base=json.loads((ROOT/'docs/BASELINE-038-ENTRY.json').read_text())
for name in ['Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m',
             'LocalCleanStatusSIMTool/main.m','LocalCleanStatusSIMTool/entitlements.plist',
             'Sources/LocalCleanStatusControlCenter.m','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m']:
    need(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==base['files'][name], 'protected behaviour source unchanged: '+name)
with tempfile.TemporaryDirectory(prefix='lcs-entry-host-') as tmp:
    binary=str(Path(tmp)/'policy')
    subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror',
                    '-I'+str(ROOT/'Cellular'),str(ROOT/'tests/cellular/entry_policy_test.c'),'-lm','-o',binary],check=True)
    subprocess.run([binary],check=True)
print(f'PASS cellular entry adapter source contracts: {checks}; UIKit/device arbitration NOT executed.')
