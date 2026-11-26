#!/usr/bin/env python3
"""Sync the audited service, never the other way around; no network or build."""
from pathlib import Path
import argparse,hashlib,json,shutil
p=argparse.ArgumentParser();p.add_argument('--workspace',required=True,type=Path);p.add_argument('--check',action='store_true');a=p.parse_args()
d=a.workspace.resolve();src=d/'source/capture/MiniSightRhythmService';dst=d/'source/plugin/debs/MiniSightRhythmService'
app=d/'source/app/src/ios/MiniSightCore';plug=d/'source/plugin/debs/MiniSight'
imports=['MiniSightRhythmAnalyzer.cpp','MiniSightRhythmAnalyzer.h','MiniSightRhythmFrame.h','MiniSightRhythmWire.h','MiniSightRhythmReceivePolicy.h','vendor/BeatDetektor/BeatDetektor.h','vendor/BeatDetektor/BeatDetektor.cpp']
h=lambda b:hashlib.sha256(b).hexdigest()
for name in imports:
    original=(app/name).read_bytes();assert original==(plug/name).read_bytes(),f'dual core differs: {name}'
    target=src/'shared'/name
    if a.check: assert target.read_bytes()==original,name
    else: target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(app/name,target)
# Keep wire/frame top-level includes exact as well, with the shared copy.
for name in ['MiniSightRhythmFrame.h','MiniSightRhythmWire.h']:
    assert (src/name).read_bytes()==(app/name).read_bytes(),name
files=[x for x in sorted(src.rglob('*')) if x.is_file() and not any(t in x.parts for t in ['__pycache__','.theos','packages']) and x.name!='MANIFEST.json']
manifest={'format':1,'count':len(files),'scope':'identical capture source and standalone plugin service; no artifacts','spdx':'MIT for ASS2/BeatDetektor; local adapter changes marked in PROVENANCE.md','ass2_commit':'20d26f5061fa7db132da5148e18d814947f1905e','beatdetektor_commit':'85a662048e4a906ddb40a511f9fa2ab7a7712c80','files':{str(x.relative_to(src)):{'sha256':h(x.read_bytes()),'bytes':x.stat().st_size} for x in files},'shared_imports':{n:h((app/n).read_bytes()) for n in imports}}
encoded=json.dumps(manifest,indent=2,sort_keys=True)+'\n'
if a.check: assert (src/'MANIFEST.json').read_text()==encoded,'manifest drift'
else: (src/'MANIFEST.json').write_text(encoded)
files.append(src/'MANIFEST.json')
expected={str(x.relative_to(src)) for x in files}
if a.check:
    actual={str(x.relative_to(dst)) for x in dst.rglob('*') if x.is_file()}
    assert actual==expected,f'mirror path drift: {actual^expected}'
    for x in files: assert x.read_bytes()==(dst/x.relative_to(src)).read_bytes(),str(x)
else:
    dst.mkdir(parents=True,exist_ok=True)
    extras={str(x.relative_to(dst)) for x in dst.rglob('*') if x.is_file()}-expected
    assert not extras,f'refuse to overwrite untracked mirror content: {extras}'
    for x in files:
        target=dst/x.relative_to(src);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(x,target)
print(json.dumps({'status':'PASS','manifested_files':manifest['count'],'total_including_manifest':len(files),'copies_identical':True,'no_actual_audio':True}))
