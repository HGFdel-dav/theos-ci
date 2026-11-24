#!/usr/bin/env python3
"""Button-priority contract layered onto the existing 0.3.10 entry checks."""
from pathlib import Path
import json,hashlib,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
hook=(ROOT/'Cellular/LCSCellularHooks.m').read_text();checks=0
def need(v,label):
 global checks
 if not v:raise AssertionError(label)
 checks+=1
base=json.loads((ROOT/'docs/BASELINE-0315-ENTRY-BINDING-FALLBACK.json').read_text())
allow=set(base['allowed_changes'])
for n,h in base['files'].items():
 if n not in allow:need((ROOT/n).is_file() and hashlib.sha256((ROOT/n).read_bytes()).hexdigest()==h,'0.3.11 protected file changed: '+n)
need('- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture' in hook and 'return [self.binding shouldBeginPressedGesture:gesture];' in hook,'independent target implements the callback required by the round hook')
need('- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture' in hook and 'return [self.binding shouldBeginPressedGesture:gesture];' in hook,'target implements the gesture-begin callback used by round hook')
need('BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);' in hook and 'BOOL local=cellular&&state&&[state.target gestureRecognizerShouldBegin:gesture];' in hook and 'BOOL allowed=LCSRoundButtonAllowsGesture(cellular,original,local);' in hook and 'return allowed;' in hook,'native original forwards unrelated gestures; cellular exception uses its target delegate')
need('round-local-hook-installed' in hook and 'round-button-image-unverified' in hook,'round hook checks source image and logs result')
need('gestureRecognizerShouldBegin:"' in hook and 'setOwner:' not in hook and 'forwardInvocation:' not in hook,'no custom owner, subclass, or forwarding')
need('shouldBeRequiredToFailByGestureRecognizer:' in hook and 'return ![other isKindOfClass:UIPanGestureRecognizer.class];' in hook,'WiFi failure rule preserved')
need('LCSCellularSIMController' in hook and 'presentViewController:panel' in hook,'existing SIM card path retained')
with tempfile.TemporaryDirectory(prefix='lcs311-entry-') as d:
 for n in ['round_button_policy_test.c']:
  exe=str(Path(d)/n.removesuffix('.c'))
  subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(ROOT/'Cellular'),str(ROOT/'tests/cellular'/n),'-lm','-o',exe],check=True)
  subprocess.run([exe],check=True)
print(f'PASS cellular button-priority source contract: {checks}; no UIKit/device arbitration executed.')
