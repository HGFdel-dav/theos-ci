#!/usr/bin/env python3
"""Source invariants only. Does not compile iOS code or prove runtime behavior."""
from pathlib import Path
import plistlib, json, re, subprocess, tempfile, sys
ROOT = Path(__file__).resolve().parents[1]
checks = 0
def need(ok, message):
    global checks
    if not ok: raise AssertionError(message)
    checks += 1
def text(name): return (ROOT/name).read_text()
features = re.findall(r'"((?:hide|modern|tap)[A-Za-z]+)"',text('Sources/LocalCleanStatusCore.h'))
need(len(features)==14 and len(set(features))==14,'fourteen unique feature keys')
for path in ROOT.rglob('*.plist'):
    if any(s in path.parts for s in ('.git','.theos','packages','out','checks')): continue
    need(isinstance(plistlib.loads(path.read_bytes()),dict),str(path))
panel = plistlib.loads((ROOT/'LocalCleanStatusPrefs/Resources/LocalCleanStatusRoot.plist').read_bytes())
switches=[i for i in panel['items'] if i['cell']=='PSSwitchCell']
need(len(switches)==15,'fourteen switches plus master')
need(set(i['key'] for i in switches)==set(features+['enabled']),'panel/core keys agree')
need(all(i['default'] is False for i in switches),'all defaults OFF')
entry=plistlib.loads((ROOT/'layout/Library/PreferenceLoader/Preferences/LocalCleanStatusPrefs.plist').read_bytes())['entry']
info=plistlib.loads((ROOT/'LocalCleanStatusPrefs/Resources/Info.plist').read_bytes())
need(entry['detail']==info['NSPrincipalClass']=='LocalCleanStatusRootListController','panel controller identity')
need(entry['bundle']==info['CFBundleExecutable']=='LocalCleanStatusPrefs','bundle executable identity')
need(entry['isController'] is True,'real controller enabled')
need(info['CFBundleVersion']==info['CFBundleShortVersionString']=='0.1.3','panel version')
need('Version: 0.1.3' in text('control'),'package version')
need('Maintainer: Niubiprass' in text('control') and 'Author: Niubiprass' in text('control'),'package author')
need(entry['icon']=='icon.png' and all(('Resources/'+n) in text('LocalCleanStatusPrefs/Makefile') for n in ('icon.png','icon@2x.png','icon@3x.png')),'three original PreferenceLoader icons')
for name,size in (('icon.png',29),('icon@2x.png',58),('icon@3x.png',87)):
    icon=(ROOT/'LocalCleanStatusPrefs/Resources'/name).read_bytes()
    need(icon.startswith(bytes.fromhex('89504e470d0a1a0a')) and int.from_bytes(icon[16:20],'big')==size and int.from_bytes(icon[20:24],'big')==size,'custom RGBA icon %s'%name)
need(not (ROOT/'LocalCleanStatusPrefs/Resources/CleanStatusIcon@2x.png').exists(),'old custom icon name removed')
need('Architecture: iphoneos-arm64e' in text('control'),'package arch')
need('preferenceloader' in text('control'),'panel dependency')
need('TARGET = iphone:clang:15.5:15.5' in text('LocalCleanStatusBuild.mk'),'fixed SDK')
need('ARCHS = arm64e' in text('LocalCleanStatusBuild.mk'),'arm64e target')
need('FINALPACKAGE = 1' in text('Makefile'),'release package')
need('-fvisibility=hidden' in text('Makefile') and '-DCLEANSTATUS_STRIP_LOGS=1' in text('Makefile'),'hidden/log-stripped dylib')
need('-Wl,-x -Wl,-dead_strip' in text('Makefile'),'release linker stripping')
need('GITHUB_ACTIONS' in text('build.sh') and 'RUNNER_OS' in text('build.sh'),'local iOS build denied')
filt=plistlib.loads((ROOT/'LocalCleanStatus.plist').read_bytes())
need(filt=={'Filter':{'Bundles':['com.apple.UIKit','com.apple.springboard']}},'UIKit and SpringBoard injection only')
main=text('Hooks/LocalCleanStatusMain.xm')
need('bundlePath.pathExtension' in main and '@"app"' in main,'app guard')
for name in ('local_cleanstatus_installStatusHooks','local_cleanstatus_installBatteryHooks','local_cleanstatus_installLowPowerBridge','local_cleanstatus_refreshStatusBars','local_cleanstatus_refreshBatteries'):
    need(name+'();' in main,'main wiring '+name)
all_sources='\n'.join(p.read_text() for p in ROOT.rglob('*') if p.suffix in ('.m','.h','.xm'))
need('NSUserDefaults' not in re.sub(r'//[^\n]*','',all_sources),'no cfprefsd/real-var mirror')
need('initWithSuiteName' not in all_sources,'no default-suite fallback')
need('NSLog(' not in all_sources.replace('#define NSLog(...)',''),'no production runtime logging')
need('subviews' not in text('Sources/LocalCleanStatusStatus.m'),'no broad view tree icon matching')
status=text('Sources/LocalCleanStatusStatus.m')
need(status.count('Entry", "set')==12,'eleven icon types plus second cellular entry')
need('data copy' in status and 'entry copy' in status,'copy before mutation')
need('filtered == entry' in status and 'display == source' in status,'no in-place shared entry mutation')
need('lcsNativeDataKey' in status and 'local_cleanstatus_currentFlags()' in status,'reversible source/display split')
battery=text('Sources/LocalCleanStatusBattery.m')
need('local_cleanstatus_restoreNative(state)' in battery and 'state.oldInteraction' in battery,'battery restoration')
need('lcsBatteryLayoutDepth' in battery,'setter layout cycle guard')
need(battery.count('local_cleanstatus_installBatteryUpdateHooks();')==1,'battery update hooks installed')
need('chargingState",0)==1' in battery,'charging state exact')
need('local_cleanstatus_inStatusBar' in battery,'status-only battery scope')
need('NSTimer' not in all_sources and 'CADisplayLink' not in all_sources,'no periodic rendering poll')
runtime=text('Headers/LocalCleanStatusRuntime.h')
need('method_copyReturnType' in runtime and 'method_copyArgumentType' in runtime,'return/argument ABI validation')
need('actual[1] !=' in runtime,'block and object ABI not conflated')
low=text('Sources/LocalCleanStatusLowPower.m')
for guard in ('com.apple.springboard','isUILocked','lcsPowerInFlight','local_cleanstatus_tapAllowed','local_cleanstatus_methodMatches'):
    need(guard in low,'power guard '+guard)
need('setPowerMode:error:' in low,'real low power mutation')
need('local_cleanstatus_boolValue(manager, "isUILocked", YES)' in low,'unknown lock fails closed')
prefs=text('Sources/LocalCleanStatusPreferences.h')
paths=text('Sources/LocalCleanStatusPaths.m')
need('NSPropertyListBinaryFormat_v1_0' in prefs and 'NSDataWritingAtomic' in prefs,'atomic whole-file prefs')
need('local_cleanstatus_migrationRoots()' in prefs and 'if (roots.count == 0) [roots addObject:@"/var/jb"]' in prefs and 'roots addObject:@"/"' in prefs,'migration candidates and rootless fallback only when no RootHide roots exist')
need('dispatch_once(&once' in paths and 'jbroot(local_cleanstatus_logicalPreferencePath)' in paths,'preference path mapped and cached once per process')
need('if (!mapped.length) mapped = local_cleanstatus_logicalPreferencePath' in paths,'real logical path fallback')
need('local_cleanstatus_selectedRoot' in paths and 'hasSuffix:local_cleanstatus_preferenceSuffix' in paths,'containment root derived from mapped path')
need('contentsOfDirectoryAtPath:local_cleanstatus_appGroupDirectory' in text('Sources/LocalCleanStatusPaths.h'),'legacy migration scan retained')
need('local_cleanstatus_pathInsideRoot(path, local_cleanstatus_selectedRoot())' in prefs and prefs.index('local_cleanstatus_pathInsideRoot(path, local_cleanstatus_selectedRoot())') < prefs.index('createDirectoryAtPath'),'validate preference path before creating directories')
need('local_cleanstatus_pathInsideRoot(NSString *path, NSString *root)' in text('Sources/LocalCleanStatusPaths.h'),'writable path containment')
controller=text('LocalCleanStatusPrefs/LocalCleanStatusRootListController.m')
need('if (!_specifiers)' in controller and '_specifiers =' in controller,'inherited specifier cache')
need('self.lcsBaseline' in controller and 'isEqual:baseline' in controller,'draft conflict detection')
need('dispatch_async(local_cleanstatus_panelQueue()' in controller,'serial background panel storage')
need(controller.index('if (success) local_cleanstatus_notifyApplied()')>controller.index('local_cleanstatus_writePreferences'),'notify only after write')
for bad in ('system(', 'posix_spawn(', 'NSTask', 'killall', 'sbreload'):
    need(bad not in all_sources,'no implicit process/device action '+bad)
for path in ROOT.rglob('*'):
    if path.suffix not in ('.h','.m','.xm','.plist','.mk','.sh','.yml','.json') and path.name not in ('Makefile','control'): continue
    if not path.is_file() or any(s in path.parts for s in ('.git','.theos','packages','out','checks')): continue
    s=path.read_text()
    need('OWNER/REPOSITORY' not in s and '__PREFIX__' not in s,'no placeholders '+str(path.relative_to(ROOT)))
    need(not re.search(r'\.jbroot-[0-9A-Fa-f]{8}-',s),'no hardcoded root UUID')
    need(not any(line.rstrip()!=line for line in s.splitlines()),'no trailing whitespace '+str(path.relative_to(ROOT)))
subprocess.run(['sh','-n',str(ROOT/'build.sh')],check=True)
with tempfile.TemporaryDirectory(prefix='cleanstatus-host-') as tmp:
    binary=str(Path(tmp)/'core')
    subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror',str(ROOT/'tests/core_test.c'),'-lm','-o',binary],check=True)
    subprocess.run([binary],check=True)
print(f'PASS source invariants: {checks}. iOS compile/runtime NOT performed.')
