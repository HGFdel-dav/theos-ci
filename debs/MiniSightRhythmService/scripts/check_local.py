#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded local host/syntax checks; never build/link/load iOS code or sockets."""
from pathlib import Path
import argparse,json,subprocess,time,shutil
p=argparse.ArgumentParser();p.add_argument('--service',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--output',required=True,type=Path);p.add_argument('--sdk',default='/opt/theos/sdks/iPhoneOS15.5.sdk');a=p.parse_args();s=a.service.resolve();o=a.output.resolve();o.mkdir(parents=True,exist_ok=True)
rows=[]
def run(name,cmd,execute=None,expected=0):
 t=time.monotonic();r=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=180);text=r.stdout+r.stderr;rc=r.returncode
 if rc==0 and execute:
  r=subprocess.run(list(map(str,execute)),capture_output=True,text=True,timeout=180);text+='\n'+r.stdout+r.stderr;rc=r.returncode
 (o/(name+'.log')).write_text(text);rows.append({'name':name,'command':list(map(str,cmd)),'execute':list(map(str,execute)) if execute else None,'exit':rc,'expected':expected,'pass':rc==expected,'seconds':round(time.monotonic()-t,2),'log':str(o/(name+'.log'))});(o/'RESULT.json').write_text(json.dumps({'checks':rows,'no_actual_audio':True,'network_executed':False,'ios_machine_code':False},indent=2)+'\n');print(name,rc,'PASS' if rc==expected else 'FAIL',flush=True)
inc=['-I'+str(s),'-I'+str(s/'shared')]
exe=o/'admission-host'
run('host-admission',['clang++','-std=c++17','-O1','-Wall','-Wextra','-Werror',*inc,s/'tests/AdmissionTests.cpp','-o',exe],[exe])
for mode,n in [('SOURCE',0),('LIVE',1)]:run('contract-'+mode,['make','-f',s/'build/Pair.mk','contract','MINISIGHT_RHYTHM_MODE='+mode])
for name,flags in [('half-transport',['MINISIGHT_RHYTHM_MODE=LIVE','MINISIGHT_ENABLE_RHYTHM_CAPTURE=0']),('half-capture',['MINISIGHT_RHYTHM_MODE=LIVE','MINISIGHT_ENABLE_RHYTHM_TRANSPORT=0']),('invalid',['MINISIGHT_ENABLE_RHYTHM_TRANSPORT=2']),('source-not-live',['MINISIGHT_ENABLE_RHYTHM_CAPTURE=1','MINISIGHT_ENABLE_RHYTHM_TRANSPORT=1'])]:run('reject-'+name,['make','-f',s/'build/Pair.mk','contract',*flags],expected=2)
if Path(a.sdk).is_dir() and shutil.which('clang++'):
 flags=['-target','arm64e-apple-ios15.5','-isysroot',a.sdk,'-isystem',a.sdk+'/usr/include/c++/v1','-stdlib=libc++','-std=c++17','-fblocks','-DNDEBUG','-DDEVTEST_BUILD=0','-DMINISIGHT_RHYTHM_STRIP_LOGS=1','-fvisibility=hidden','-fvisibility-inlines-hidden','-Wall','-Wextra','-Wshadow','-Wshorten-64-to-32','-Wimplicit-fallthrough','-Werror=return-type','-I/opt/theos/vendor/include','-F/opt/theos/vendor/lib',*inc,'-fsyntax-only','-ferror-limit=5']
 for n in [0,1]:
  pair=['-DMINISIGHT_ENABLE_RHYTHM_CAPTURE='+str(n),'-DMINISIGHT_ENABLE_RHYTHM_TRANSPORT='+str(n),'-DMINISIGHT_RHYTHM_LIVE_BUILD='+str(n)]
  for f in ['Tweak.cpp','CaptureEngine.cpp','FeatureAnalyzer.cpp','FeatureServer.cpp','shared/MiniSightRhythmAnalyzer.cpp','shared/vendor/BeatDetektor/BeatDetektor.cpp']:run('sdk155-'+str(n)+'-'+Path(f).name,['clang++',*flags,*pair,s/f])
  # Preprocess only: inspect symbol presence, never execute constructor/network.
  pp=['clang++',*[v for v in flags if v!='-fsyntax-only'],*pair,'-E',s/'Tweak.cpp'];run('preprocess-'+str(n),pp)
  text=(o/('preprocess-'+str(n)+'.log')).read_text();assert ('static void MiniSightRhythmServiceInitialize()' in text)==bool(n);assert ('OSStatus HookedAudioUnitRender(' in text)==bool(n)
 # Fail-closed preprocessor mismatched capture.
 run('reject-preprocessor-half',['clang++','-x','c++','-E','-DMINISIGHT_ENABLE_RHYTHM_CAPTURE=1',s/'CaptureConfig.h'],expected=1)
else:
 rows.append({'name':'SDK15.5','status':'SKIP','pass':False,'reason':'required SDK or compiler absent'})
(o/'RESULT.json').write_text(json.dumps({'checks':rows,'pass':all(r['pass'] for r in rows),'no_actual_audio':True,'network_executed':False,'ios_machine_code':False},indent=2)+'\n')
raise SystemExit(0 if all(r['pass'] for r in rows) else 1)
