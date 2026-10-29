from pathlib import Path
import zipfile,hashlib,json,shutil
R=Path(__file__).resolve().parent
D=Path('/var/minis/attachments/ParticleX-0.1.0dev1');D.mkdir(parents=True,exist_ok=True)
S=Path('/var/minis/shared/ParticleX-0.1.0dev1');S.mkdir(parents=True,exist_ok=True)
state=json.loads((R/'ci-state.json').read_text())
for scheme in ('roothide','rootless'):
 a=R/'ci-downloads'/('particlex-'+scheme)
 for p in a.glob('*.deb'):shutil.copyfile(p,D/p.name)
 shutil.copyfile(a/'build.log',D/(scheme+'-build.log'))
 shutil.copyfile(a/'package-list.txt',D/(scheme+'-package-list.txt'))
shutil.copyfile(R/'README.md',D/'README.md')
shutil.copyfile(Path('/tmp/particlex-verify/verification.json'),D/'verification.json')
excludes={'.git','.theos','packages','out','__pycache__','ci-downloads','verification'}
omit={'ci-state.json','deliver.py','publish.py','ci_download.py'}
files=[p for p in sorted(R.rglob('*')) if p.is_file() and not excludes.intersection(p.relative_to(R).parts) and p.name not in omit and p.suffix not in ('.deb','.zip','.log')]
with zipfile.ZipFile(D/'ParticleX-0.1.0dev1-Source.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for p in files:
  rel=p.relative_to(R);z.write(p,Path('ParticleX-0.1.0dev1')/rel)
  to=S/rel;to.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,to)
with zipfile.ZipFile(D/'ParticleX-0.1.0dev1-Source.zip') as z:
 assert not any(any(x in Path(n).parts for x in excludes) or n.endswith('.deb') for n in z.namelist())
text=f'''ParticleX 0.1.0dev1\nSource commit: {state['commit']}\nBranch: {state['branch']}\nBuild: https://github.com/Niubiprass/theos-ci/actions/runs/40942373955\n\nStatic source/plist/ABI checks: PASS (75 guards)\nPortable slider geometry: PASS (100010 cases)\nMetal shader preflight: PASS (xcrun metal, ios-metal2.3)\nGitHub macos-14 / roothide/theos / iPhoneOS15.5.sdk: PASS\nrootless and roothide CI jobs: SUCCESS\ndpkg-deb -e and -c: PASS; no maintainer scripts\nRootHide payload: /Library/ only; package architecture iphoneos-arm64e\nRootless payload: /var/jb/Library/ only; package architecture iphoneos-arm64\nEach dylib + prefs binary: arm64 and arm64e; all SHA1/SHA256 CodeDirectory pages matched\nFilter: com.apple.springboard only\nNo screenshot/notification body persisted; bounded local diagnostic log\nRootHide resource/preferences mapping uses libroothide jbroot()\n\nKnown build warnings: upstream -multiply_defined obsolete linker option; no project compiler warnings suppressed beyond unused-parameter.\n\nNOT performed: phone installation, SpringBoard reload, runtime injection proof, visual/gesture acceptance.\nBuild success is NOT runtime success. If SpringBoard crashes or preferences blank, provide CrashReporter .ips and ParticleX runtime.log.\n'''
(D/'VERIFICATION.txt').write_text(text)
(S/'BUILD-RESULT.txt').write_text(text)
rows=[]
for p in sorted(D.iterdir()):
 if p.is_file() and p.name!='SHA256SUMS':rows.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name)
(D/'SHA256SUMS').write_text('\n'.join(rows)+'\n')
print('Delivery:',D)
print((D/'SHA256SUMS').read_text())
print('Clean source files',len(files),'Persistent source:',S)
