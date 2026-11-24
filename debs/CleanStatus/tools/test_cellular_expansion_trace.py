#!/usr/bin/env python3
"""0.3.13 local expansion/trace gates. Source/C only, not UIKit arbitration."""
from pathlib import Path
import json, hashlib, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
hook=(ROOT/'Cellular/LCSCellularHooks.m').read_text()
policy=(ROOT/'Cellular/LCSCellularEntryPolicy.h').read_text()
checks=0
def need(v,label):
 global checks
 if not v:raise AssertionError(label)
 checks+=1
def body(anchor):
 start=hook.index(anchor);op=hook.index('{',start);depth=0
 for i in range(op,len(hook)):
  if hook[i]=='{':depth+=1
  elif hook[i]=='}':
   depth-=1
   if not depth:return hook[op+1:i]
 raise AssertionError('unbalanced '+anchor)
begin=body('- (BOOL)shouldBeginPressedGesture:(UIGestureRecognizer *)gesture {')
press=body('- (void)pressed:(UILongPressGestureRecognizer *)gesture {')
unbind=body('- (void)unbind {')
transition=body('static void LCSWillExpand(')
round_hook=body('static BOOL LCSRoundGestureShouldBegin(')
receive=body('- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:')
received=body('- (void)receivedTouch:(UIGestureRecognizer *)gesture {')
trace=body('- (void)traceGesture:(UIGestureRecognizer *)gesture phase:(NSString *)phase {')
inventory=body('- (void)logGestureInventory {')
yield_rule=body('- (BOOL)shouldYieldForGesture:(UIGestureRecognizer *)gesture other:(UIGestureRecognizer *)other {')
need('bool allowed=LCSCellularMayBeginPress(expansion,owned,local);' in begin,'production begin calls actual C gate')
need('bool validExpansion=expansion==LCSCellularExpansionUnknown||' in policy and 'expansion==LCSCellularExpansionExpanded;' in policy,'unknown/collapsed/expanded accepted; invalid state rejected')
need('BOOL direct=gesture&&self.directPress&&gesture==self.directPress;' in begin,'direct recognizer identity checked')
need('BOOL fallback=gesture&&self.windowPress&&gesture==self.windowPress;' in begin,'fallback recognizer identity checked')
need('BOOL owned=direct||fallback;' in begin,'nil or foreign recognizer is not owned')
need('if(direct)local=local&&LCSDirectTouch(self.button);' in begin,'direct entry requires native direct touch')
need('LCSCellularWindowFallbackAllows(YES,LCSDirectTouch(self.button),LCSVisible(self.button),local)' in begin,'fallback receives un-negated direct-touch capability')
need('BOOL local=[self entryReady];' in begin and '[state entryReady]' in receive,'receive/begin share the actual live-view safety gate')
need('self.windowPress.enabled=NO' in unbind and '[self.boundWindow removeGestureRecognizer:self.windowPress]' in unbind,'unbind detaches the fallback recognizer')
need('LCSRequiredHookMask=47U' in hook,'expanded lifecycle callback required')
need('state.expansionKnown=YES;state.expanded=expanded;' in transition,'only observed transition records known state')
need(hook.count('expansionKnown=YES')==1,'no invented collapsed initial state')
need('LCSAssumeCollapsed' not in hook and 'initial-collapsed' not in hook,'no load/appear assumption')
need('load-await-transition' in hook and 'appear-await-transition' in hook,'unknown initial state observable')
need('self.expanded=' not in unbind and 'self.expansionKnown=' not in unbind,'unbind cannot reset expanded state to collapsed')
need('traceBudget=0;self.traceGeneration++' in unbind,'unbind cancels pending diagnostics')
need('state.panel==weakPanel&&state.controller' in press and 'LCSCellularForeground&&LCSCellularIsUnlocked()' in press,'panel continuation retains owner, lock and feature safety')
need('state.expansionKnown&&!state.expanded' not in press,'ongoing panel is not invalidated when module expands')
need('if(expanded&&state.panel)[state.panel close]' not in transition,'native expansion callback never closes an open SIM card')
need('return validExpansion && gestureIsOwned && localGate;' in policy,'unknown/collapsed/expanded all pass only for own gesture and local guards')
need('expansion-unknown' not in press and 'already-expanded' not in press,'expanded/unknown do not reject actual presentation path')
need('BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);' in round_hook,'foreign gesture invokes original exactly once')
need(round_hook.count('LCSOriginalRoundGestureShouldBegin(')==1,'no double native callback')
need('BOOL allowed=LCSRoundButtonAllowsGesture(cellular,original,local);' in round_hook and 'return allowed;' in round_hook,'all foreign decisions forwarded unchanged')
need('BlocksNative' not in policy+hook and 'blocksNative' not in hook,'no guessed native gesture blocking')
need('return ![other isKindOfClass:UIPanGestureRecognizer.class];' in yield_rule,'failure-relation decisions unchanged from 0.3.11')
need('@"other-waits"' in yield_rule and 'self-waits-other' not in hook,'Apple direction is other waits own, not reverse')
need('return YES;' in receive and 'sendActions' not in receive,'touch logging not a synthetic tap or rejection')
need('now-self.lastTouchTrace<.75' in received and 'self.traceBudget=36' in received,'bounded per-touch budget/rate')
need('++self.traceGeneration' in received,'new trace invalidates previous delayed snapshot')
need(received.index('++self.traceGeneration')<received.index('now-self.lastTouchTrace<.75'),'throttled touch also invalidates preceding delayed snapshot')
for anchor,original in [('static void LCSLoaded(', 'LCSOriginalLoad(self,sel)'),('static void LCSAppeared(', 'LCSOriginalAppear(self,sel,animated)'),('static void LCSDisappeared(', 'LCSOriginalDisappear(self,sel,animated)'),('static void LCSLayoutSubviews(', 'LCSOriginalLayout(self,sel)')]:
 b=body(anchor);need(b.count(original)==1 and b.index(original)<b.index('LCSCellularButtonState'),'original lifecycle executes exactly once before local state')
for term in ['__weak typeof(self)','__weak UIGestureRecognizer','__weak UIControl','state.traceGeneration!=generation','state.directPress!=weakGesture','state.button!=weakButton','!LCSCellularForeground','!LCSCellularFeatureEnabled','!LCSCellularIsUnlocked']:
 need(term in received,'late snapshot guard '+term)
need(received.count('dispatch_after(')==1 and '.7*NSEC_PER_SEC' in received,'one finite delayed read-only snapshot')
need('self.traceBudget<2' in trace and 'self.traceBudget-=2' in trace,'every gesture/class pair consumes budget')
need('depth<12&&count<4' in inventory,'snapshot enumeration bounded')
for bad in ['touch location','sendActionsForControlEvents','gesture.enabled=','gesture.delegate=','removeGestureRecognizer']:
 need(bad not in received+trace+inventory,'snapshot does not mutate UIKit '+bad)
need('NSStringFromClass(gesture.class)' in trace and "c>='a'&&c<='z'" in trace and 'slug.length<48' in trace,'class labels normalized to logger alphabet and limit')
settings=(ROOT/'Cellular/LCSCellularSettings.m').read_text()
need('events.count>=128' in settings and 's.length>48' in settings,'existing bounded diagnostic store unchanged')
need(len(re.findall(r'- \(BOOL\)gestureRecognizer:[^\n]*shouldBeRequiredToFailByGestureRecognizer:[^\n]*\{',hook))==1,'single delegate failure method implementation')
with tempfile.TemporaryDirectory(prefix='lcs312-gate-') as temp:
 d=Path(temp);exe=d/'gate';src=ROOT/'tests/cellular/expansion_gate_test.c'
 def run(header):
  (d/'LCSCellularEntryPolicy.h').write_text(header)
  compiled=subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(d),str(src),'-o',str(exe)],text=True,capture_output=True)
  need(compiled.returncode==0,'production and each bad predicate must compile before execution')
  return subprocess.run([str(exe)],text=True,capture_output=True)
 good=run(policy);need(good.returncode==0,'actual production C predicate execution');print(good.stdout.strip())
 original='bool validExpansion=expansion==LCSCellularExpansionUnknown||'
 need(original in policy,'valid expansion allowlist anchor present')
 mutations=[policy.replace('expansion==LCSCellularExpansionExpanded;','expansion==LCSCellularExpansionCollapsed;'),
  policy.replace('return validExpansion && gestureIsOwned && localGate;','(void)validExpansion; return gestureIsOwned && localGate;'),
  policy.replace('return validExpansion && gestureIsOwned && localGate;','(void)gestureIsOwned; return validExpansion && localGate;')]
 for mutant_header in mutations:
  mutant=run(mutant_header)
  need(mutant.returncode!=0,'reject invalid expansion or missing ownership/local gate mutation')
print(f'PASS expansion trace source contract: {checks}; 3 real C mutations rejected; no UIKit/device execution')
