#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Pure source/build contract. Does not import a service or open a socket."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--service',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--mode',choices=['SOURCE','LIVE'],default='SOURCE');p.add_argument('--capture',type=int,default=0);p.add_argument('--transport',type=int,default=0);a=p.parse_args();s=a.service.resolve()
expected=int(a.mode=='LIVE');assert a.capture==a.transport==expected,'partial or mismatched LIVE build forbidden'
from check_manifest import verify as verify_manifest
h=lambda b:hashlib.sha256(b).hexdigest();m=verify_manifest(s)
assert h((s/'shared/vendor/BeatDetektor/BeatDetektor.h').read_bytes())=='aca16316f11a8d53d75cf34bd56fece6775b7b2e1bb1ecb3b4e5e84998d84418'
assert h((s/'shared/vendor/BeatDetektor/BeatDetektor.cpp').read_bytes())=='b7c5f347941baf4e09314ae1f4ddbd380e8c5f89a36ee642aed4733a17db9d6b'
for f in ['MiniSightRhythmFrame.h','MiniSightRhythmWire.h']:assert (s/f).read_bytes()==(s/'shared'/f).read_bytes()
for f in ['ServerInternal.h','Makefile']:
 t=(s/f).read_text();assert '../../app/' not in t and 'src/ios/MiniSightCore' not in t,f
make=(s/'Makefile').read_text()
for x in ['FINALPACKAGE = 1','ARCHS = arm64e','15.5:15.5','-fvisibility=hidden','-Wl,-S','-Wl,-x','-Werror=return-type','MINISIGHT_ENABLE_RHYTHM_CAPTURE=$(MINISIGHT_ENABLE_RHYTHM_CAPTURE)']:assert x in make,x
warning_lines=[line for line in make.splitlines() if '-Wno-error' in line]
expected_vendor='$(RHYTHM_CORE)/vendor/BeatDetektor/BeatDetektor.cpp_CFLAGS = -Wno-error=reorder-ctor -Wno-error=unused-but-set-variable -Wno-error=shorten-64-to-32 -Wno-error=sign-compare'
expected_wrapper='$(RHYTHM_CORE)/MiniSightRhythmAnalyzer.cpp_CFLAGS = -Wno-error=reorder-ctor'
assert warning_lines==[expected_vendor,expected_wrapper], 'only exact pinned vendor/header per-file warning exceptions allowed'
assert 'GO_EASY_ON_ME' not in make and '-Wno-error ' not in make
assert (s/'MiniSightRhythmService.plist').read_text().strip()=='Filter = { Executables = ("mediaserverd"); };'
t=(s/'Tweak.cpp').read_text();render=t[t.index('OSStatus HookedAudioUnitRender'):t.index('OSStatus HookedAudioComponentInstanceNew')]
assert render.index('gOriginalAudioUnitRender(unit')<render.index('CaptureRenderedAudio(')
for word in ['malloc(','new ','dispatch_','AudioUnitGetProperty','sendto(','NSLog','pthread_mutex']:assert word not in render,word
for x in ['GateEnter','GateExit','activeSourceToken','sourceGeneration','RenderMayCopy','writerBusy']:assert x in render,x
assert '#if MINISIGHT_ENABLE_RHYTHM_CAPTURE' in t
capture=(s/'CaptureEngine.cpp').read_text();assert 'AppleOutputMixer' in capture and 'SelectFormat' in capture
server=(s/'FeatureServer.cpp').read_text();assert 'LoopbackEndpoint' in server
assert 'ScheduleIdleExpiry(maximumGrace)' in server and 'ExpireClients(now)' in server
assert 'captureEnabled.store(false' in server
plugin=s.parent/'MiniSight'
if plugin.is_dir():
 fields=dict(line.split(':',1) for line in (plugin/'control').read_text().splitlines() if ':' in line)
 fields={k:v.strip() for k,v in fields.items()}
 assert fields['Package']=='com.niubiprass.minisight' and fields['Version']=='0.8.58'
 assert 'static NSString *const kMiniSightVersion   = @"'+fields['Version']+'";' in (plugin/'Tweak.xm').read_text(), 'runtime version marker drift'
 assert (plugin/'MiniSight.plist').read_bytes().strip()==b'{ Filter = { Bundles = ( "com.apple.springboard" ); }; }', 'main injection scope changed'
 assert fields['Depends']=='mobilesubstrate, firmware (>= 15.5)'
 assert fields['Provides']=='com.niubiprass.minisight.rhythmservice (= 0.1.0)'
 for key in ['Conflicts','Replaces']:assert fields[key]=='com.niubiprass.minisight.rhythmservice',key
 pm=(plugin/'Makefile').read_text();assert '../MiniSightRhythmService/build/Flags.mk' in pm
 assert 'SUBPROJECTS = ../MiniSightRhythmService' in pm and 'include $(THEOS_MAKE_PATH)/aggregate.mk' in pm
 assert 'TARGET = iphone:15.5:15.0' in pm and 'SDKVERSION = 15.5' in pm
 assert 'CaptureEngine.cpp' not in pm and 'FeatureServer.cpp' not in pm
 assert 'MINISIGHT_RHYTHM_LIVE_BUILD=$(MINISIGHT_RHYTHM_LIVE_BUILD)' in pm
 client=(plugin/'MiniSightRhythmClient.m').read_text()
 for x in ['count<16','Latest-value mailbox','eligibilityHandler','MiniSightRhythmConfigurePetWithPosition','position=NAN','[self sendLease:NO]']:assert x in client,x
 assert 'position=pet.musicPosition' not in client and 'lyricsLine' not in client
 pet=(plugin/'MiniSightPet.m').read_text();assert '[self mayPerformMusicMotion]' in pet
print(json.dumps({'status':'PASS','mode':a.mode,'capture':a.capture,'transport':a.transport,'manifest_files':m['count'],'standalone_service':True,'no_actual_audio':True}))
