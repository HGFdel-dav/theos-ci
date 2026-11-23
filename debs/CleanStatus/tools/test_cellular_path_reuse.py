#!/usr/bin/env python3
"""Source/wiring preservation. Native resolver fixtures run separately, never claimed here."""
from pathlib import Path
import hashlib,json,re,tempfile,importlib.util
ROOT=Path(__file__).resolve().parents[1]
count=0
def need(value,label):
    global count
    if not value:raise AssertionError(label)
    count+=1
def sha(b):return hashlib.sha256(b).hexdigest()
def text(n):return (ROOT/n).read_text()
base=json.loads(text('docs/BASELINE-032-PATH-REUSE.json'));allowed=set(base['allowed_changes'])
runtime=json.loads(text('docs/BASELINE-039-WIFI-ENTRY.json'))
runtime_allowed=set(runtime['allowed_changes'])
for name,want in runtime['files'].items():
    if name not in runtime_allowed:need((ROOT/name).is_file() and sha((ROOT/name).read_bytes())==want,'published 0.3.8 non-scope file changed: '+name)
settings=text('Cellular/LCSCellularSettings.m');animation=text('Animation/LocalCleanStatusAnimationPreferences.m')
need(sha(animation.encode())==base['files']['Animation/LocalCleanStatusAnimationPreferences.m'],'reused animation implementation byte-identical')
need('for (NSString *prefix in @[@"", @".jbroot"])' in animation,'existing implementation already follows split-root backlink')
need('LCSASelectedRoot()' in animation and 'dispatch_once(&once' in animation,'keep original one-time selected root, no new resolver')
root=settings[settings.index('NSString *LCSCellularRoot(void)'):settings.index('NSDictionary *LCSCellularDefaults(void)')]
need(root.count('local_cleanstatus_animationPreferencesPath()')==2,'both cellular root and file derive from original public API')
for forbidden in ['LCSRootRank','dlsym','dladdr','contentsOfDirectoryAtPath','FIXTURE','dispatch_once','selected=']:
    need(forbidden not in root,'cellular may not rediscover or inject a root: '+forbidden)
need('LCSRelative.lastPathComponent' in root and 'path.stringByDeletingLastPathComponent' in root,'keep separate sibling cellular filename')
need('local_cleanstatus_writeAnimationPreferences(' not in settings and 'local_cleanstatus_migrateAnimationPreferences(' not in settings and 'local_cleanstatus_readAnimationPreferences(' not in settings,'path reuse does not read/write/migrate animation values')
for makefile,key,part in [('Makefile','LocalCleanStatusCellular_FILES','Animation/LocalCleanStatusAnimationPreferences.m'),('LocalCleanStatusDataSwitch/Makefile','LocalCleanStatusDataSwitch_FILES','../Animation/LocalCleanStatusAnimationPreferences.m'),('LocalCleanStatusSIMTool/Makefile','LocalCleanStatusSIMTool_FILES','../Animation/LocalCleanStatusAnimationPreferences.m'),('LocalCleanStatusPrefs/Makefile','LocalCleanStatusPrefs_FILES','../Animation/LocalCleanStatusAnimationPreferences.m')]:
    source=text(makefile);line=next(v for v in source.splitlines() if v.startswith(key+' ='))
    need(line.split().count(part)==1,'each image links one copy of the exact old source: '+makefile)
    need('-fvisibility=hidden' in source,'C functions stay image-local: '+makefile)
    need('LCS_CELLULAR_FIXTURE' not in source and 'LCS_CELLULAR_STORAGE_TEST' not in source,'production compile cannot enable fixture boundaries: '+makefile)
start=settings.index('NSDictionary *LCSCellularDefaults(void)');end=settings.index('NSString *LCSCellularSIMToolPath(void)')
need(sha(settings[start:end].encode())==base['protected_settings_storage_span_sha256'],'original cellular defaults/atomic store/locks/migration/readback/notify unchanged')
log=settings[settings.index('void LCSCellularLog('):]
need(sha(log.encode())==base['protected_settings_diagnostics_span_sha256'],'existing bounded diagnostic implementation unchanged')
need('LCSInside(path,root)' in settings and 'before.st_dev!=after.st_dev' in settings and 'before.st_ino!=after.st_ino' in settings,'path containment and root-change rejection retained')
need('O_NOFOLLOW' in settings and 's.st_nlink==1' in settings and 'NSDataWritingAtomic' in settings and 'isEqualToData:data' in settings,'symlink/hardlink/atomic/readback defenses retained')
tool=settings[settings.index('NSString *LCSCellularSIMToolPath(void)'):settings.index('void LCSCellularLog(')]
need('@[@"",@".jbroot"]' in tool and 'root=LCSCellularRoot()' in tool,'helper resolves only direct/backlink of the old selected root')
need('contentsOfDirectoryAtPath' not in tool and '/var/jb' not in tool,'tool lookup never picks another root independently')
need('S_ISREG' in tool and 's.st_nlink==1' in tool and 'X_OK' in tool,'helper retains ordinary executable/no-final-symlink checks')
fixture=text('tests/cellular/storage_native.m')
need('LCS_CELLULAR_FIXTURE_ROOT"' not in fixture and 'LCS_CELLULAR_FIXTURE_GROUP' in fixture,'native test no longer preselects root')
need('createSymbolicLinkAtPath:' in fixture and '@".jbroot"' in fixture,'real split data/program fixture')
runner=text('tools/run_cellular_storage_native.py')
need('LCSARootRank(candidate)' in runner and 'LCSARootFromImage()' in runner,'test stages real old selection code, not a rewritten resolver')
need("'share-write','share-read'" in runner and "'missing','unranked','symlink-root','rootless','escape','stale'" in runner,'independent-process and refusal fixtures scheduled')
spec=importlib.util.spec_from_file_location('lcs_native_fixture_runner',ROOT/'tools/run_cellular_storage_native.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='lcs-resolver-staging-check-') as tmp:
    staged=module.stage(tmp).read_text()
    for token in ['static int LCSARootRank(NSString *root)','LCSAHiddenRoot(path)','LCSARootFromImage()','int rank = LCSARootRank(candidate);','dispatch_once(&once','for (NSString *prefix in @[@"", @".jbroot"])']:
        need(token in staged,'staged original discovery still executes: '+token)
print(f'PASS path reuse source/wiring: {count}; original resolver/UI/business code preserved. This is NOT native storage execution.')
