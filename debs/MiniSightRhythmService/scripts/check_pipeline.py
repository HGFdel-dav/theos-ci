#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded selected synthetic PCM/FFT + current production-host extraction.
No actual audio, AudioUnit, socket or Tweak is ever run. UIKit seams are mocks.
"""
from pathlib import Path
import argparse,importlib.util,json,subprocess,shutil,time
p=argparse.ArgumentParser();p.add_argument('--workspace',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
p.add_argument('--compile-timeout',type=int,default=180);p.add_argument('--run-timeout',type=int,default=180)
p.add_argument('--host-opt',choices=['0','1'],default='1')
a=p.parse_args();assert 1<=a.compile_timeout<=600 and 1<=a.run_timeout<=600
d=a.workspace.resolve();s=d/'source/capture/MiniSightRhythmService';o=a.output.resolve();o.mkdir(parents=True,exist_ok=True);core=d/'source/app/src/ios/MiniSightCore';fixture=d/'source/app/scripts/fixtures';rows=[]
def run(name,cmd,exe=None):
 start=time.monotonic();stage='compile';compiled=False;executed=False
 try:
  r=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=a.compile_timeout);text=r.stdout+r.stderr;rc=r.returncode;compiled=rc==0
  if compiled and exe:
   stage='execute';r=subprocess.run(list(map(str,exe)),capture_output=True,text=True,timeout=a.run_timeout);text+='\n'+r.stdout+r.stderr;rc=r.returncode;executed=True
 except subprocess.TimeoutExpired:
  text=locals().get('text','')+'\nTIMEOUT during '+stage+'; NOT PASS';rc=124
 (o/(name+'.log')).write_text(text);rows.append({'name':name,'command':list(map(str,cmd)),'execute':list(map(str,exe)) if exe else None,'exit':rc,'pass':rc==0,'compiled':compiled,'executed':executed,'timeout_stage':stage if rc==124 else None,'seconds':round(time.monotonic()-start,2)});(o/'RESULT.json').write_text(json.dumps({'checks':rows,'no_actual_audio':True,'host_only':True,'optimization':a.host_opt},indent=2)+'\n');print(name,rc,flush=True)
 if rc:raise SystemExit(rc)
inc=['-I'+str(s),'-I'+str(s/'shared')];deps=[s/'shared/MiniSightRhythmAnalyzer.cpp',s/'shared/vendor/BeatDetektor/BeatDetektor.cpp'];base=['clang++','-std=c++17','-O'+a.host_opt,'-DDEVTEST_BUILD=0',*inc]
for case in ['BridgeTests','RealWrapperSmoke']:
 exe=o/case;run(case,base+[s/('tests/'+case+'.cpp'),*([] if case=='BridgeTests' else deps),'-o',exe],[exe])
# Copy the previously fixed fixture algorithm, change only duration/trace window.
text=(fixture/'minisight_rhythm_20261125/test_analyzer.cpp').read_text()
text=text.replace('?72:32','?36:12').replace('feed.time>=68.0','feed.time>=32.0')
text=text[:text.index('int main(int argc,char **argv)')]+'''int main(){
 traceFile=std::fopen("TRACE_PATH","w");if(!traceFile)return 2;
 scenario("pulse",120,true);std::fclose(traceFile);traceFile=NULL;
 scenario("pulse",90,true);scenario("pulse",150,true);
 scenario("tone",0,true);scenario("noise",0,true);scenario("silence",0,true);
 scenario("barepulse",120,false);
 std::printf("{\\"test_failures\\":%d}\\n",failures);return failures?1:0;
}
'''.replace('TRACE_PATH',str(o/'frames120.jsonl'))
(o/'selected.cpp').write_text(text);exe=o/'selected-host'
run('selected-PCM2048-FFT1024',base+['-DMS_TEST_N=2048','-DMS_TEST_H=800','-DMS_TEST_FS=48000','-DMS_TEST_NORMALIZED_POWER',o/'selected.cpp',*deps,'-o',exe],[exe])
# Execute CURRENT extracted Pet/Effects methods in both host fixtures. Source
# scripts are imported as translators only, never invoke their native runner.
frames=[json.loads(x) for x in (o/'frames120.jsonl').read_text().splitlines()]
assert len(frames)>200
old=d.parent/'music-rhythm-local-20261123/test-real-trace-host.py'
raw=old.read_text();fn=raw.split("function=r'''",1)[1].split("'''",1)[0]
fn=fn.replace('float sr=16000','float sr=48000')
# The old source fixture predates the ordinary-life recovery fix: only the
# measured route must freeze on dropout; the ordinary clock/roam must resume.
assert fn.count('CHECK(!P.motionActive&&!P.roamTimer);')==1
fn=fn.replace('CHECK(!P.motionActive&&!P.roamTimer);',
    'CHECK(!P.musicMotion&&!P.motionActive&&P.frameTimer&&P.roamTimer);')
head='static const MSRhythmFrame CapturedFrames[]={\n'+',\n'.join('{'+','.join(str(f[k]) for k in ['epoch','sequence','sampleTime','period','phase','confidence','rms','peak','flags'])+'}' for f in frames)+'\n};\n'
for side,path in [('app',d/'source/app/src/ios/MiniSightCore'),('plugin',d/'source/plugin/debs/MiniSight')]:
 script=d/('source/app/scripts/test_minisight_pet_paths_20261122.py' if side=='app' else 'source/plugin/debs/MiniSight/scripts/test_minisight_pet_paths_20261122.py')
 spec=importlib.util.spec_from_file_location('current_'+side,script);b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
 td=o/side;td.mkdir(exist_ok=True);pet=(path/'MiniSightPet.m').read_text();effects=(path/'MiniSightPetEffects.m').read_text();generated,evidence=b.generate(pet,effects)
 (td/'production-paths.h').write_text(generated);(td/'extracted-methods.json').write_text(json.dumps(evidence,indent=2)+'\n')
 for f in b.FIX.glob('*.c'):shutil.copyfile(f,td/f.name)
 for f in path.glob('*.h'):shutil.copyfile(f,td/f.name)
 driver=(td/'driver.c').read_text();driver=driver.replace('#include "MiniSightPetRhythmPolicy.h"','#include "MiniSightPetRhythmPolicy.h"\n#include "MiniSightRhythmReceivePolicy.h"')
 driver=driver.replace('int main(int argc,char**argv) {',head+fn+'\nint main(int argc,char**argv) {')
 driver=driver.replace(' RhythmSuite(); RhythmExtra();',' RhythmSuite(); RhythmExtra(); ActualTraceHost();')
 assert 'ActualTraceHost();' in driver;(td/'driver.c').write_text(driver)
 exe=td/'trace-host';run(side+'-current-production-host',['clang','-std=c99','-O'+a.host_opt,'-Wno-unused-function','-I'+str(td),td/'driver.c','-lm','-o',exe],[exe])
result={'checks':rows,'pass':all(x['pass'] for x in rows),'no_actual_audio':True,'source':'synthesized 48kHz PCM,2048FFT/1024 bins, normalized portable power expression','not_executed':['Accelerate','AudioUnit','ObjC/UIKit','NSTimer','socket','service constructor'],'barepulse':'Optional validity observation only; late_valid_fraction is not a continuous-lock support guarantee'}
(o/'RESULT.json').write_text(json.dumps(result,indent=2)+'\n')
