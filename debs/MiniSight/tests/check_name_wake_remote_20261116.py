#!/usr/bin/env python3
"""Source/wire integration checks only; never a UIKit or device runtime proof."""
from pathlib import Path
import sys
P = Path(__file__).resolve().parents[1]
strict_native = '--strict-native' in sys.argv[1:]
plugin_only = '--plugin-only' in sys.argv[1:]
paths = [argument for argument in sys.argv[1:] if argument not in ('--strict-native', '--plugin-only')]
if plugin_only and paths:
    raise SystemExit('--plugin-only cannot masquerade as an App mirror check')
A = None if plugin_only else (Path(paths[0]) if paths else Path('/var/minis/shared/openminis/minisight-workbuddy-trae-20261112/src/ios/MiniSightCore'))
if A is not None and A.resolve() == P.resolve():
    raise SystemExit('App mirror must be a distinct tree; use --plugin-only in plugin CI')
host = (P / 'MiniSightNameWakeHost.h').read_text()
bridge = (P / 'MiniSightNameWakeBridge.m').read_text()
tweak = (P / 'Tweak.xm').read_text()
checks = 0
def check(value, label):
    global checks
    checks += 1
    if not value: raise AssertionError(label)
for name in ('namewake-state.json', 'namewake-request.json', 'namewake-response.json'):
    check(name in bridge, name)
for suffix in ('request', 'response', 'state'):
    check('com.openminis.minisight.namewake.' + suffix in bridge, 'notification ' + suffix)
for field in ('schema', 'clock', 'host', 'revision', 'token', 'action', 'responseGeneration', 'voiceGeneration', 'reason', 'unlocked', 'allowed', 'busy'):
    check('@"' + field + '"' in bridge, 'wire field ' + field)
check('request.count != 6' in bridge and 'MSNWLimit = 8191' in bridge, 'strict small fixed envelope')
check('MSNWClockFresh' in bridge and 'systemUptime' in bridge and 'NSDate' not in bridge, 'boot clock')
check('MSNWContainerValid' in bridge and 'AT_SYMLINK_NOFOLLOW' in bridge and 'S_ISREG' in bridge, 'current safe container')
check('isEqualToDictionary:value' in bridge, 'mailbox readback')
reply = bridge.split('- (void)replyToRequest:', 1)[1]
check(reply.index('MSNWWriteVerified') < reply.index('MSBridgePost(MSNWResponseNote)') < reply.index('MSBridgePost(@"com.openminis.minisight.voice")'), 'ACK before named voice notification')
check('ticket != self->_responseTicket' in reply and '_readTicket' in bridge and '_stateTicket' in bridge, 'latest generation fences')
for forbidden in ('openURL', 'AVAudioEngine', 'AVAudioRecorder', 'speakUtterance', 'startRecording'):
    check(forbidden not in host + bridge, 'no injected audio/launch: ' + forbidden)
check('#include "MiniSightNameWakeHost.h"' in tweak and 'MiniSightNameWakeBridge.m' in (P / 'Makefile').read_text(), 'real build wiring')
check('isEqualToString:MSNWRequestNote' in tweak and '(__bridge const void *)MSNWRequestNote' in tweak, 'request observer and routing')
check('MiniSightRequestResources(NO,' in host and 'refreshPreferences' not in host, 'single lazy resource path, not polling directories')
check('timerWithTimeInterval:1.0' in host and 'else if (!enabled && gMSNWPulse)' in host, 'opt-in heartbeat stops OFF')
check('MSNWAllowed(' in host and 'MSNWBusy(' in host and '[MiniSightMusicMonitor deviceIsUnlocked]' in host, 'production safe gates and existing lock ABI')
check('!(gMiniSightNameWakeToken.length || gMiniSightNameWakePresentationHeld)' in tweak, 'named request or user draft owns overlay')
check('gMiniSightNameWakePresentationHeld = panel.isVisible' in host and 'nameWakeVoiceFinishedHandler' in host, 'natural final retains draft without cancellation')
check('gMiniSightNameWakePresentationHeld = NO' in tweak and 'MiniSightChatPanel.existingPanel.isVisible' in tweak, 'close ends draft presentation')
check('gMiniSightPet.window != gMiniSightWindow' in host and 'showNameWakeResponseInWindowScene' in host, 'real current anchor and panel')
ready = host.split('if ([action isEqualToString:@"ready"])',1)[1].split('if (!gMSNWSeenTokens)',1)[0]
check(ready.index('gMSNWReadyConsumed = YES') < ready.index('beginNameWakeVoiceInputForGeneration'), 'consume once before UI callback')
check('!same || gMSNWReadyConsumed' in ready and 'MSNWReadyMayConsume' in ready, 'same token/lifecycle ready')
cancel = host.split('static void MiniSightNameWakeCancel(',1)[1].split('static void MiniSightNameWakeUpdate(',1)[0]
check(cancel.index('gMSNWRequest = nil') < cancel.index('cancelNameWakeRequestForToken') < cancel.index('state:@"cancelled"'), 'clear ownership before cancellation and response')
check('reason:@""' not in host, 'nonempty reason compatible with App decoder')
for root in ((P,) if plugin_only else (P, A)):
    panel = (root / 'MiniSightChatPanel.m').read_text()
    header = (root / 'MiniSightChatPanel.h').read_text()
    for symbol in ('nameWakeRequestToken', 'currentVoiceGeneration', 'cancelNameWakeRequestForToken', 'nameWakeVoiceRequestDeferred'):
        check(symbol in header and symbol in panel, 'shared interface ' + symbol)
    check('@"source": @"nameWake", @"nameWakeToken": self.voiceNameWakeToken' in panel, 'named source and exact host token')
    check('return @{@"action": action, @"generation": @(self.voiceGeneration)};' in panel, 'manual original two-field payload')
    check('if (!self.voiceFromNameWake) {\n        dispatch_after' in panel and 'background_voice_unavailable' in panel, 'named skips old 1.2s URL fallback')
    owned = panel.split('- (BOOL)cancelNameWakeRequestForToken:',1)[1].split('- (BOOL)beginNameWakeVoiceInputForGeneration:',1)[0]
    check('isEqualToString:self.nameWakeRequestToken' in owned and '[self close]' not in owned and '[self.ai cancel]' not in owned, 'cancel cannot steal manual UI/network')
    check('@"minisight.wake.enabled": @"wakeEnabled"' in (root / 'MiniSightResources.m').read_text(), 'opt-in setting passthrough')
# Existing plugin presentation behavior must remain even in single-tree CI.
plugin_panel = (P / 'MiniSightChatPanel.m').read_text()
check('CGFloat panelBoost' in plugin_panel and 'self.panelBoost > 1. ? 1. : 1.35' in plugin_panel
      and '* self.panelBoost' in plugin_panel and 'MIN(self.panelBoost, 1.2)' in plugin_panel,
      'old plugin panel boost behavior retained')
if A is not None:
    check((P/'MiniSightChatPanel.h').read_bytes() == (A/'MiniSightChatPanel.h').read_bytes(), 'public headers identical')
    # Never replace either whole panel file to make shared interfaces agree.
    check('CGFloat panelBoost' not in (A/'MiniSightChatPanel.m').read_text(), 'old independent App panel layout retained')
else:
    print('SKIP App mirror parity: explicitly plugin-only CI; plugin layout guards remain active')
print(f'PASS source/wire integration: {checks} assertions')
print('SKIP native Foundation/UIKit/SpringBoard/audio/device: not executed; portable/source checks are not runtime proof')
if strict_native:
    print('FAIL CLOSED: --strict-native requires native evidence, not supplied or executed')
    raise SystemExit(2)
