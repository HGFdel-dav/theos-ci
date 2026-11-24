#!/usr/bin/env python3
"""Approved Darwin CI only: exact 15.5 arm64e types, default-OFF preprocessing.
Only the default-OFF path is checked. No capture-enabled compiler invocation.
"""
from pathlib import Path
import argparse,json,os,platform,subprocess
p=argparse.ArgumentParser();p.add_argument('--ios-sdk',required=True);a=p.parse_args()
assert platform.system()=='Darwin' and os.environ.get('CI','').lower() in ('true','1','yes')
sdk=Path(a.ios_sdk);assert sdk.is_dir() and sdk.name=='iPhoneOS15.5.sdk'
D=Path(__file__).resolve().parent;P=D.parents[1];S=P.parent/'MiniSightRhythmService'
O=Path(os.environ['RHYTHM_OFF_OUT']);O.mkdir(parents=True,exist_ok=True);rows=[]
def check(name,cmd):
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
 (O/(name+'.log')).write_text(r.stdout+r.stderr)
 rows.append({'name':name,'exit':r.returncode,'command':cmd});(O/'NATIVE-RHYTHM.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(name,r.returncode,flush=True)
 if r.returncode:print(r.stdout+r.stderr);raise SystemExit(1)
 return r.stdout
base=['xcrun','clang++','-std=c++17','-fblocks','-fexceptions','-fcxx-exceptions','-target','arm64e-apple-ios15.5','-isysroot',str(sdk),'-I'+str(P),'-I'+str(S),'-I'+str(Path.home()/'theos/vendor/include'),'-I'+str(Path.home()/'theos/include'),'-F'+str(Path.home()/'theos/vendor/lib'),'-F'+str(Path.home()/'theos/vendor/lib/iphone/roothide'),'-F'+str(Path.home()/'theos/vendor/lib/iphone/rootless'),'-Wall','-Wextra','-Werror=return-type']
for n in ['Tweak.cpp','CaptureEngine.cpp','FeatureAnalyzer.cpp','FeatureServer.cpp']:
 check('service-off-'+n,base+['-fsyntax-only',str(S/n)])
for n in ['MiniSightRhythmAnalyzer.cpp','vendor/BeatDetektor/BeatDetektor.cpp']:
 check('core-'+Path(n).name,base+['-fsyntax-only',str(P/n)])
for lang,std in [('c','c11'),('c++','c++17'),('objective-c','gnu11'),('objective-c++','gnu++17')]:
 h=O/('header-'+lang+'.h');h.write_text('#include "MiniSightRhythmAnalyzer.h"\n#include "MiniSightRhythmWire.h"\n#include "MiniSightRhythmReceivePolicy.h"\n')
 check('header-'+lang,['xcrun','clang','-x',lang,'-std='+std,'-fsyntax-only','-target','arm64e-apple-ios15.5','-isysroot',str(sdk),'-I'+str(P),'-Wall','-Wextra','-Werror',str(h)])
text=check('service-default-preprocessed',base+['-E',str(S/'Tweak.cpp')])
for forbidden in ['MiniSightRhythmServiceInitialize','HookedAudioUnitRender','InstallHooks()']:
 assert forbidden not in text,'default OFF retained activation: '+forbidden
client=(P/'MiniSightRhythmClient.m').read_text();config=(S/'CaptureConfig.h').read_text()
assert '#define MINISIGHT_ENABLE_RHYTHM_TRANSPORT 0' in client and '#define MINISIGHT_ENABLE_RHYTHM_CAPTURE 0' in config
(O/'DEFAULT-OFF.json').write_text(json.dumps({'capture_default':0,'transport_default':0,'service_constructor_excluded':True,'hooks_excluded':True,'capture_enabled_tested':False,'transport_enabled_tested':False},indent=2)+'\n')
print('PASS exact SDK native types/default OFF; no device/audio/runtime claim')
