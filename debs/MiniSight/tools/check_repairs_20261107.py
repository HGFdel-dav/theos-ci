#!/usr/bin/env python3
"""Plugin-side locks for 0.8.2: action routing, logs, resource reload."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
tweak = (ROOT / 'Tweak.xm').read_text()
log = (ROOT / 'MiniSightLog.m').read_text()
panel = (ROOT / 'MiniSightChatPanel.m').read_text()
fails=[]
def need(c,w):
    if not c: fails.append(w)
need('[MiniSightChatPanel.existingPanel showInput]' in tweak, 'input action opens editor')
need('[MiniSightChatPanel.existingPanel showMenu]' in tweak, 'menu action only opens menu')
need('[MiniSightChatPanel.existingPanel beginVoiceInput]' in tweak, 'voice action starts voice')
need('kMiniSightResourcesChanged' in tweak, 'asset import dedicated reload')
need('diagnostic-app.log' in log and 'diagnostic-plugin.log' in log, 'separate logs')
need('@"route"' in log and '@"old"' in log and '@"new"' in log, 'typed route/old/new')
need('@"approval"' in log and '@"gesture"' in log and '@"assets"' in log, 'new event features allowed')
need('"generation"' in panel and '"starting"' in panel, 'voice result is fenced and acknowledged')
need('finishVoiceWithReason' in panel and 'voicePending' in panel, 'voice failure has one state')
need('setMotionLocked' in panel, 'editor/approval freeze pet without fighting host')
need('preferredFramesPerSecond = 30' in panel, 'anchor follower limited to 30fps')
need('currentAnchorRect' in panel, 'follower uses tilt-safe anchor')
pet=(ROOT/'MiniSightPet.m').read_text()
need('packCols * innerCols' in pet and 'variantIndex' in pet, 'outer pet + inner frame slicing')
need('_spriteLayout == 1' in pet and 'CGRectMake(0, 0, 1, 1)' in pet, 'single image is never sliced')
need('MSLoadAtlas(petPath, single)' in (ROOT/'MiniSightResources.m').read_text(), 'single image loads at its own ratio')
need(tweak.count('0.40') >= 2, 'drag gain is applied on change and on release')
need('setCategory' not in open(ROOT/'MiniSightBlip.m').read(), 'blip never hijacks the audio session')
need('"trash", @"清空"' in panel and '@[@"mic", @"听写"]' not in panel, 'menu is icon-only without duplicate mic')
need('MSKeyOutBlackBackground' in (ROOT/'MiniSightResources.m').read_text(), 'black sheet background is keyed out')
if fails:
    print('FAIL plugin repairs'); [print(' -',x) for x in fails]; sys.exit(1)
print('PASS MiniSight plugin repair locks')
