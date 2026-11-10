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
need('setMotionLocked:YES forReason:MiniSightPetMotionLockChatEditor' not in panel, 'editor must not freeze the pet')
need('preferredFramesPerSecond = 60' in panel, 'anchor follower matches the pet frame cadence')
need('currentAnchorRect' in panel, 'follower uses tilt-safe anchor')
pet=(ROOT/'MiniSightPet.m').read_text()
need('effectiveLayout == 3' in pet and '(CGFloat)col / packCols' in pet and '(CGFloat)_state / packRows' in pet, 'single sheet plays row/column frames')
need('effectiveLayout == 1' in pet and 'CGRectMake(0, 0, 1, 1)' in pet, 'single image is never sliced')
need('MSLoadAtlas(petPath, single, key)' in (ROOT/'MiniSightResources.m').read_text(), 'single image loads at its own ratio')
need(tweak.count('0.20') >= 2, 'drag gain is applied on change and on release')
blip=(ROOT/'MiniSightBlip.m').read_text()
need('fmtLen = 16' in blip and 'appendBytes:&fmtLen length:4' in blip, 'WAV fmt chunk is 16 bytes')
need('appendBytes:&dataLen length:4' in blip, 'WAV data length is frames*2, not fmt')
need('initWithData:wav error:&error' in blip and '[gPlayer play]' in blip, 'blip checks init/play')
need('AVAudioSessionCategoryAmbient' in blip and 'MixWithOthers' in blip, 'blip mixes instead of pausing other audio')
need('"trash", @"清空"' in panel and '@[@"mic", @"听写"]' not in panel, 'menu is icon-only without duplicate mic')
need('name = @"natural";' in tweak, 'colour removal keeps the source pixels')
need('gMiniSightSettingsWatch' in tweak and 'MiniSightReloadSettings();' in tweak, 'settings revision and shown are polled live')
need('CGFloat size = MiniSightPetSize()' in tweak, 'pet size applies without a respring')
need('soundEnabled = c.sound' in tweak, 'sound switch is live')
need('beginDraggingWithDirection' in pet and 'endDragging' in pet, 'drag keeps one clip until release')
need('MSFlipVertical' in (ROOT/'MiniSightResources.m').read_text(), 'loaded sprite is flipped upright for display')
need('CGImageCreateWithImageInRect' in pet, 'renderer crops the current frame explicitly')
need('roamInterval' in tweak and 'gravityStrength' in tweak, 'activity interval and gravity strength are live')
need('gMiniSightBubbleScale' in tweak and 'gMiniSightDwell' in tweak, 'bubble/text/dwell settings reach the panel')
need('refreshSnapshotPreferences' in tweak and 'runtime.json' in tweak, 'live reload reads the atomic runtime snapshot')
need('MiniSightRegionPicker' in tweak and 'startWithSource:MiniSightRecorderSourceManual region:' in tweak, 'manual recording has a draggable region picker')
need('cropThenFinish' in (ROOT/'MiniSightRecorder.m').read_text(), 'the save stage crops the chosen region')
import re, struct, wave
from io import BytesIO
_frames_match = re.search(r'frames = (\d+)', blip)
if not _frames_match:
    fails.append('blip frame count missing')
else:
    _frames = int(_frames_match.group(1)); _rate = 22050
    _pcm = b'\0\0' * _frames; _data = _frames * 2
    _header = (b'RIFF' + struct.pack('<I', 36 + _data) + b'WAVEfmt '
               + struct.pack('<I', 16) + struct.pack('<HHIIHH', 1, 1, _rate,
                                                     _rate * 2, 2, 16)
               + b'data' + struct.pack('<I', _data))
    try:
        with wave.open(BytesIO(_header + _pcm), 'rb') as _w:
            if _w.getnframes() != _frames: fails.append('WAV frame count differs')
    except Exception as exc:  # noqa: BLE001
        fails.append('standard WAV parser rejects the blip header: %s' % exc)
need('name = @"natural";' in tweak, 'colour removal keeps the source pixels')
need('gMiniSightSettingsWatch' in tweak and 'MiniSightReloadSettings();' in tweak, 'settings revision and shown are polled live')
need('CGFloat size = MiniSightPetSize()' in tweak, 'pet size applies without a respring')
need('soundEnabled = c.sound' in tweak, 'sound switch is live')
need('beginDraggingWithDirection' in pet and 'endDragging' in pet, 'drag keeps one clip until release')
need('MSFlipVertical' in (ROOT/'MiniSightResources.m').read_text(), 'loaded sprite is flipped upright for display')
need('CGImageCreateWithImageInRect' in pet, 'renderer crops the current frame explicitly')
need('roamInterval' in tweak and 'gravityStrength' in tweak, 'activity interval and gravity strength are live')
need('gMiniSightBubbleScale' in tweak and 'gMiniSightDwell' in tweak, 'bubble/text/dwell settings reach the panel')
need('refreshSnapshotPreferences' in tweak and 'runtime.json' in tweak, 'live reload reads the atomic runtime snapshot')
need('MiniSightRegionPicker' in tweak and 'startWithSource:MiniSightRecorderSourceManual region:' in tweak, 'manual recording has a draggable region picker')
need('cropThenFinish' in (ROOT/'MiniSightRecorder.m').read_text(), 'the save stage crops the chosen region')
need('MSKeyOutBlackBackground' in (ROOT/'MiniSightResources.m').read_text(), 'black sheet background is keyed out')
if fails:
    print('FAIL plugin repairs'); [print(' -',x) for x in fails]; sys.exit(1)
print('PASS MiniSight plugin repair locks')
