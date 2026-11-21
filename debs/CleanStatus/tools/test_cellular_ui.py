#!/usr/bin/env python3
"""UI structure, immutable scope and real production-C layout tests; not UIKit execution."""
from pathlib import Path
import hashlib,json,re,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
checks=0
def need(value,label):
    global checks
    if not value:raise AssertionError(label)
    checks+=1
manifest=json.loads((ROOT/'docs/CELLULAR-UI-VIDEO-PROTECTED.json').read_text())
for name,want in manifest['protected'].items():
    p=ROOT/name;need(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==want,'outside UI scope changed: '+name)
panel=(ROOT/'Cellular/LCSCellularPanel.m').read_text();head=(ROOT/'Cellular/LCSCellularPanel.h').read_text();module=(ROOT/'LocalCleanStatusDataSwitch/LocalCleanStatusDataModule.m').read_text()
for forbidden in ['UITableView','UISwitch','UIModalPresentationPageSheet','setTitle:@"完成"','UITableViewCellAccessoryCheckmark']:
    need(forbidden not in panel,'old settings-sheet chrome removed: '+forbidden)
for token in ['UIModalPresentationOverFullScreen','UIBlurEffectStyleSystemThinMaterialDark','LCS_CELLULAR_CARD_RADIUS','self.heading.textAlignment=NSTextAlignmentCenter','LCS_CELLULAR_CARD_GLYPH','self.glyph.topAnchor','UIControlEventTouchUpInside','self.rows=rows','for(NSInteger slot=1;slot<=2;slot++)']:
    need(token in panel,'video card structure: '+token)
for text in ['@"已开启"','@"已关闭"','@"使用中"','@"未选用"','@"未知"']:
    need(text in panel,'state badge text: '+text)
need('LCSCellularCardBadge(kind,known,observed)' in panel and 'LCSCellularCardBadgeGreen(badge)' in panel,'production badge policy used, including unknown')
need('line.available&&known&&!busy' in panel,'busy/unknown/unavailable row cannot dispatch')
need('BOOL desired=!line.enabled' in panel and not re.search(r'line\.(enabled|selected|stateKnown)\s*=',panel),'tap uses observed state without optimistic model mutation')
need('[self lineForSlot:row.tag]' in panel and 'return count==1?found:nil' in panel,'rows uniquely resolve slot then preserve service identity')
need('if(line.selectionKnown&&!line.selected)' in panel,'current-data row is not retoggled')
need('UIAlertActionStyleCancel' in panel and 'if(s&&[s current:generation])' in panel and 'confirmed:YES' in panel,'disable confirmation and stale/cancel fencing remain')
need('self.active&&self.generation==generation&&!self.token.cancelled' in panel,'generation/token guard remains')
need('viewDidDisappear:' in panel and '[self.token cancel]' in panel and '[self.guardTimer invalidate]' in panel,'dismiss/off/lock cleanup remains')
need('showNotice:verified?nil:message retry:!verified' in panel and 'self.status.numberOfLines=0' in panel,'long error message is retained, not converted to a fake success badge')
need('UIScrollView' in panel and 'contentLayoutGuide' in panel and 'scaledFontForFont:' in panel and 'traitCollectionDidChange:' in panel,'large text/long error scroll rather than clip')
need('accessibilityPerformEscape' in panel and 'outside.accessibilityLabel' in panel and 'forControlEvents:UIControlEventTouchUpInside' in panel,'close via outside tap or VoiceOver escape')
need('new UIWindow' not in panel and '[[UIWindow' not in panel,'no new global overlay window')
need('LCSCellularStatusRow LCSDataModuleStatusRow' in head,'added Objective-C row class isolated across images')
need('preferredExpandedContentHeight {return [LCSCellularPanelController preferredCardHeight];}' in module and 'preferredExpandedContentWidth {return LCS_CELLULAR_CARD_WIDTH;}' in module,'data expansion uses actual shared compact layout')
need('providesOwnPlatter {return false;}' in module,'existing CC platter/transition path preserved')
need('requestExpandModule' in module and '[self.panel deactivate]' in module,'data expand/dismiss lifecycle intact')
need('中国联通' not in panel and '中国电信' not in panel and 'line.name' in panel,'real names come from existing service; screenshot labels not hardcoded')
with tempfile.TemporaryDirectory(prefix='lcs-card-layout-') as temp:
    executable=str(Path(temp)/'layout')
    subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(ROOT/'Cellular'),str(ROOT/'tests/cellular/card_layout_test.c'),'-lm','-o',executable],check=True)
    subprocess.run([executable],check=True)
print(f'PASS cellular UI structure/scope: {checks}; protected non-UI files: {len(manifest["protected"])}. UIKit appearance, touch and material NOT run.')
