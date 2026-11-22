#!/usr/bin/env python3
"""Execute the unchanged old animation resolver against real temporary fixtures.
Only directory-root literals are substituted in a TEMPORARY compile unit. No
selected-root injection, production source edits, real /var reads, or radio API.
"""
from pathlib import Path
import hashlib,json,platform,subprocess,tempfile,sys
ROOT=Path(__file__).resolve().parents[1]

def stage(directory):
    original=ROOT/'Animation/LocalCleanStatusAnimationPreferences.m'
    frozen=json.loads((ROOT/'docs/BASELINE-032-PATH-REUSE.json').read_text())
    assert hashlib.sha256(original.read_bytes()).hexdigest()==frozen['files']['Animation/LocalCleanStatusAnimationPreferences.m']
    text=original.read_text();needle='static NSString * const LCSAGroupDirectory = @"/var/mobile/Containers/Shared/AppGroup";'
    assert text.count(needle)==1
    text=text.replace(needle,'#define LCSAGroupDirectory (NSProcessInfo.processInfo.environment[@"LCS_CELLULAR_FIXTURE_GROUP"])')
    assert text.count('@"/var/jb/usr/lib"')==1
    text=text.replace('@"/var/jb/usr/lib"','[NSProcessInfo.processInfo.environment[@"LCS_CELLULAR_FIXTURE_ROOTLESS"] stringByAppendingPathComponent:@"usr/lib"]')
    # Rootless locations also point into the fixture so a CI host cannot touch
    # a real jailbreak location. The old ranking/backlink/cache algorithm stays exact.
    text=text.replace('@"/var/jb"','(NSProcessInfo.processInfo.environment[@"LCS_CELLULAR_FIXTURE_ROOTLESS"])')
    assert 'LCSARootRank(candidate)' in text and 'LCSARootFromImage()' in text
    out=Path(directory)/'UnchangedAnimationResolverWithFixtureRoots.m';out.write_text(text)
    return out

def main():
    syntax='--syntax-only' in sys.argv
    if not syntax and platform.system()!='Darwin':
        print('SKIP Apple Foundation reused-root/storage fixtures: not an Apple runtime; no pass claimed.')
        return
    with tempfile.TemporaryDirectory(prefix='lcs-reused-root-') as tmp:
        animation=stage(tmp)
        include=['-I'+str(ROOT/'Cellular'),'-I'+str(ROOT/'Sources'),'-I'+str(ROOT/'Animation')]
        flags=['-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-DLCS_CELLULAR_STORAGE_TEST=1',*include]
        if syntax:
            base=['clang','-fsyntax-only','-target','arm64e-apple-ios15.5','-isysroot','/opt/theos/sdks/iPhoneOS15.5.sdk']
            for path in [animation,ROOT/'Cellular/LCSCellularSettings.m',ROOT/'tests/cellular/storage_native.m',ROOT/'tests/cellular/path_reuse_native.m']:
                subprocess.run(base+flags+[str(path)],check=True)
            print('PASS fixed-SDK parse of original-root test compile units (4); no native execution or code generation.')
            return
        base=['xcrun','clang',*flags,'-framework','Foundation','-framework','CoreFoundation']
        for name in ['storage_native','path_reuse_native']:
            executable=Path(tmp)/name
            subprocess.run(base+[str(ROOT/'tests/cellular'/f'{name}.m'),str(ROOT/'Cellular/LCSCellularSettings.m'),str(animation),'-o',str(executable)],check=True)
            if name=='storage_native':subprocess.run([str(executable)],check=True,timeout=30)
            else:
                for mode in ['split','flat','missing','unranked','symlink-root','rootless','escape','stale']:
                    with tempfile.TemporaryDirectory(prefix='lcs-path-case-') as fixture:
                        subprocess.run([str(executable),mode,fixture],check=True,timeout=15)
                with tempfile.TemporaryDirectory(prefix='lcs-path-shared-') as fixture:
                    for mode in ['share-write','share-read']:
                        subprocess.run([str(executable),mode,fixture],check=True,timeout=15)
        print('PASS Apple Foundation unchanged old resolver + cellular storage: real split roots, ten path cases including separate writer/reader processes; not device sandbox verification.')
if __name__=='__main__':main()
