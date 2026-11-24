#!/usr/bin/env python3
"""Unified compact/expanded overlay contracts. Source + C model only; no UIKit runtime."""
from pathlib import Path
import re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
cc=(ROOT/'Sources/LocalCleanStatusControlCenter.m').read_text()
cpp=(ROOT/'Shared/LocalCleanStatusCCPolicy.h').read_text()
hook=(ROOT/'Cellular/LCSCellularHooks.m').read_text()
policy=(ROOT/'Cellular/LCSCellularEntryPolicy.h').read_text()
checks=0
def need(ok,msg):
 global checks
 if not ok: raise AssertionError(msg)
 checks+=1
need('(void)expanded;' in cpp and '&& !expanded &&' not in cpp,'CC overlay policy ignores expanded layout')
need('local_cleanstatus_ccUnlocked(),self.expanded,attached' in cc,'actual CC state passed into policy')
need('if(!expanded)[state bind];' in cc and 'if(expanded)[lcscc_presentedList close]' not in cc,'expansion callback never closes active WiFi/BT overlay')
need('return weakSelf.controller!=nil;' in cc and '!weakSelf.expanded' not in cc,'WiFi/BT overlay lifetime independent of expanded state')
need('bool validExpansion=expansion==LCSCellularExpansionUnknown||' in policy,'cellular permits unknown initial state')
need('expansion==LCSCellularExpansionCollapsed||expansion==LCSCellularExpansionExpanded;' in policy,'cellular permits collapsed and expanded states')
need('return validExpansion && gestureIsOwned && localGate;' in policy,'cellular still requires owned gesture and all local safety gates')
need('expansion-unknown' not in hook and 'already-expanded' not in hook,'cellular actual-action path does not reject layout state')
need('state.expansionKnown&&!state.expanded' not in hook,'cellular panel lifetime does not require collapsed state')
need('if(expanded&&state.panel)[state.panel close]' not in hook,'cellular expansion callback never auto-closes SIM card')
need('state.panel==weakPanel' in hook and 'LCSCellularIsUnlocked()' in hook and 'LCSCellularFeatureEnabled(LCSCellularSIMManager)' in hook,'cellular continuation retains panel identity, unlock, feature gates')
need('BOOL original=cellular?NO:LCSOriginalRoundGestureShouldBegin(self,sel,gesture);' in hook,'foreign/native round decisions forwarded')
need('early|=[button actionsForTarget:object forControlEvent:UIControlEventTouchDown].count>0;' in hook,'short-tap safety scan retained')
# Execute the actual portable CC policy across enabled/unlocked/expanded/attached/presenting/conflict/master combinations.
with tempfile.TemporaryDirectory(prefix='lcs314-unified-') as d:
 exe=Path(d)/'cc-policy'
 subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(ROOT/'Shared'),'-I'+str(ROOT/'Sources'),str(ROOT/'tests/cc_policy_test.c'),'-o',str(exe)],check=True)
 r=subprocess.run([str(exe)],text=True,capture_output=True)
 need(r.returncode==0,'actual production CC policy truth-table execution')
 print(r.stdout.strip())
print(f'PASS unified expansion contracts: {checks}; source/C only, UIKit arbitration not executed.')
