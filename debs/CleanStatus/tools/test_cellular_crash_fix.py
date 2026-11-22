#!/usr/bin/env python3
"""Regression gates for SpringBoard gesture-crash mitigation; NOT UIKit runtime proof."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1];checks=0
def need(ok,label):
 global checks
 if not ok:raise AssertionError(label)
 checks+=1
base=json.loads((ROOT/'docs/BASELINE-033-GESTURE.json').read_text());allowed=set(base['allowed_changes'])|{'docs/CELLULAR-UI-VIDEO-033-PROTECTED.json'}
for name,digest in base['files'].items():
 if name not in allowed:need((ROOT/name).is_file() and hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,'out-of-scope 0.3.3 file changed: '+name)
for n in ['Sources/LocalCleanStatusControlCenter.m','Sources/LocalCleanStatusPaths.m','Animation/LocalCleanStatusAnimationPreferences.m','Cellular/LCSCellularService.m','Cellular/LCSCellularPanel.m','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m','LocalCleanStatusSIMTool/main.m','LocalCleanStatusSIMTool/entitlements.plist','Cellular/LCSCellularPolicy.h','Cellular/LCSCellularSettings.m']:
 need(hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==base['files'][n],'UI/business/path/service/permission behavior untouched: '+n)
hook=(ROOT/'Cellular/LCSCellularHooks.m').read_text();check=(ROOT/'tools/check_cellular.py').read_text();panel=(ROOT/'Cellular/LCSCellularPanel.m').read_text();module=(ROOT/'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m').read_text();binary=''.join(hook.split())
need(not re.search(r'@interface\s+LCSCellularPress\s*:\s*UILongPressGestureRecognizer',hook),'custom recognizer subclass absent (avoids colliding with UIKit private owner selector)')
for bad in ['UIGestureRecognizerDelegate','gestureRecognizerShouldBegin','gestureRecognizer:shouldReceiveTouch:','shouldRecognizeSimultaneously','windowPress','LCSRoundBegin','didMoveToWindow','LCSOriginalRoundBegin','gesture.delegate','owner=','->owner']:
 need(bad not in hook,'unsafe callback/whole-window/private-owner path removed: '+bad)
need(re.search(r'UILongPressGestureRecognizer\s*\*directPress',hook) and 'initWithTarget:self.target action:@selector(lcs_handlePress:)' in hook,'standard long press target/action on native button')
need('LCSCellularButtonKey' in hook and 'objc_setAssociatedObject(button,&LCSCellularButtonKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC)' in binary,'one-owner association on the stock button only')
need('LCSHasAnyGesture(button,0)' in binary and 'view.gestureRecognizers.count' in hook and 'depth>16)return YES' in hook,'recursively fail closed if any existing/subview gesture recognizer is present')
need('LCSTapContract(button)' in hook and 'UIControlEventTouchUpInside' in hook and 'UIControlEventTouchDown' in hook,'preserve verified stock short tap and reject early action')
need('LCSDirectTouch(button)' in hook and 'button.window!=self.controller.view.window' in hook,'strict direct-touch/view ownership gate')
need('LCSCellularLog(LCSCellularSIMManager,@"binding",@"recognizer-conflict",0)' in hook and 'button.gestureRecognizers' not in hook and 'LCSHasAnyGesture(button,0)' in hook,'existing gesture conflict logs a reason then fails open without binding')
need('matches.count>1' in hook and 'matches.count!=1' in hook,'ambiguous native buttons fail open')
need('gesture!=self.directPress' in hook and 'UIGestureRecognizerStateBegan' in hook and 'self->_handledBeginning' in hook,'ignore unknown, failed or duplicate gesture callbacks')
need('LCSRequiredHookMask=7U' in hook and '(LCSHookMask&LCSRequiredHookMask)==LCSRequiredHookMask' in hook,'do not bind before all native controller lifecycle hooks are verified')
need('viewDidDisappear:' in hook and 'UIApplicationWillResignActiveNotification' in hook and 'didClose' in hook,'offscreen, dismiss and panel teardown handled')
need('if(s&&(!s.button.window||!LCSVisible(s.button)))' in hook and 's.appeared=NO;[s unbind];if(s.panel)[s.panel close];' in hook,'module-covered controller does not close the panel; actually offscreen tile is detached')
need('[LCSPresentedSIM close]' in hook and 'UIApplicationWillResignActiveNotification' in hook,'foreground loss closes the one active panel')
need('(LCSHookMask&LCSRequiredHookMask)!=LCSRequiredHookMask' in hook,'do not bind after only some native lifecycle methods installed')
need('static NSString *const' not in hook.lower(),'no malformed static selector or hidden scratch state')
need('!LCSCellularIsUnlocked()' in hook and '[state unbind]' in hook and 'if(state.panel)[state.panel close]' in hook,'lock/OFF explicitly detaches long press and dismisses panel')
need('LCSOriginalLoad(self,sel)' in hook and 'LCSOriginalAppear(self,sel,animated)' in hook and 'LCSOriginalDisappear(self,sel,animated)' in hook,'all original controller lifecycle implementations forwarded')
need(not re.search(r'LCSInstall\([^\n]*"(?:buttonTapped:|_toggleState|gestureRecognizerShouldBegin:|didMoveToWindow)"',hook),'no stock button toggle or UIGestureRecognizer method hook')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook,'retained long-press action remains only SIM manager presentation')
for name in ['Cellular/LCSCellularPanel.h','Cellular/LCSCellularPanel.m','Cellular/LCSCellularCardLayout.h','LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m']:
 need(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==base['files'][name],'video UI file byte-identical to 0.3.3: '+name)
need('UIModalPresentationOverFullScreen' in panel and 'LCS_CELLULAR_CARD_RADIUS' in panel and 'LCSCellularCardBadge(kind,known,observed)' in panel,'video-aligned two-card UI remains intact')
need('preferredExpandedContentHeight {return [LCSCellularPanelController preferredCardHeight];}' in module,'data switch card expansion remains intact')
need('gestureRecognizerShouldBegin' not in hook and 'windowPress' not in hook and 'LCSOriginalRoundBegin' not in hook,'production hooks no longer contain removed legacy gesture path')
need('test_cellular_crash_fix.py' in check,'crash regression test wired into main local gate')
print(f'PASS gesture crash/scope regression: {checks}; protected unchanged files {len(base["files"])-len(allowed)}; no UIKit/runtime or device claim.')
