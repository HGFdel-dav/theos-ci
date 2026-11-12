#!/usr/bin/env python3
"""Static integration checks. Not Objective-C compilation or runtime proof."""
from pathlib import Path
import plistlib, re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
def text(p): return (root/p).read_text()
ui=text('LocalCleanStatusPrefs/LocalCleanStatusAnimationsController.m')
engine=text('Animation/LocalCleanStatusAnimations.xm')
store=text('Animation/LocalCleanStatusAnimationPreferences.m')
policy=text('Sources/LocalCleanStatusAnimationPolicy.h')
cap=text('Sources/LocalCleanStatusAnimationCapabilities.h')
controls={}
for name in ('LocalCleanStatusAnimations','LocalCleanStatusAnimationsAdvanced'):
    data=plistlib.loads((root/'LocalCleanStatusPrefs/Resources'/f'{name}.plist').read_bytes())
    for item in data['items']:
        if item.get('key'):
            assert item['key'] not in controls
            controls[item['key']]=item
            assert item.get('defaults')=='com.local.cleanstatus.animations'
            assert item.get('get')=='readPreferenceValue:' and item.get('set')=='setPreferenceValue:specifier:'
assert len(controls)==14
for key,default in re.findall(r'\{"(animation\w+)", (true|false)\}',policy):
    assert controls[key]['default'] is (default=='true'),key
for key,fallback,lo,hi in re.findall(r'\{"(animation\w+)", ([\d.]+), ([\d.]+), ([\d.]+)\}',policy):
    row=controls[key]
    assert (row['default'],row['min'],row['max'])==(float(fallback),float(lo),float(hi)),key
assert controls['animationEnabled']['default'] is False
assert controls['animationIcons'].get('animationRequires') is None
assert controls['animationDroplet']['requiresCapability']==9
assert controls['animationClearSheet']['requiresCapability']==20
assert controls['animationFlyBlur']['requiresCapability']==68
assert controls['animationGlobalSlow']['requiresCapability']==32
assert 'if (!_specifiers)' in ui and '_specifiers =' in ui
for bad in ('local_cleanstatus_readPreferences(', 'local_cleanstatus_writePreferences(', 'migratePreferences(', 'valueForKey:@"enabled"', 'LocalCleanStatusConfig'):
    assert bad not in ui+engine+store,bad
assert 'local_cleanstatus_notifyAnimationsApplied(' not in engine,'runtime must not notify its own preference observer'
assert 'CFPreferences' not in engine and 'dataWithContentsOfFile' not in engine
assert 'LCSAFlyCleanup();' in engine and '[gLCSAGenie finish];' in engine and 'LCSARestoreNumbers(nil);' in engine
assert 'UIAccessibilityReduceMotionStatusDidChangeNotification' in engine
assert 'maximumFramesPerSecond' in engine
assert 'LCSAAppABI()' in engine and 'LCSAGenieABI()' in engine and 'LCSAIconsABI()' in engine
assert 'coverSheetSlidingViewControllerDidEndTransition:' not in engine
assert 'TEST_HOOKS' not in engine and 'visibility("default")' not in engine
assert 'com.local.cleanstatus.animations.plist' in store and 'com.local.cleanstatus.plist' not in store
assert '@"/var/mobile/Library/Preferences/' not in store
assert 'NSDataWritingAtomic' in store and 'isEqualToData:data' in store
assert '127u' in cap and 'UINT64_C(127)' in cap
assert 'LocalCleanStatusAnimations_FILES = Animation/' in text('Makefile')
assert not (root/'Hooks/LocalCleanStatusAnimations.xm').exists()
assert plistlib.loads((root/'LocalCleanStatusAnimations.plist').read_bytes())=={'Filter':{'Bundles':['com.apple.springboard']}}
with tempfile.TemporaryDirectory(prefix='lcs-anim-host-') as tmp:
    for source in ('tests/animation_policy_test.c','Animation/portable_validation.c'):
        binary=Path(tmp)/Path(source).stem
        subprocess.run(['cc','-std=c11','-D_DEFAULT_SOURCE','-O2','-Wall','-Wextra','-Werror',str(root/source),'-lm','-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
print('PASS animation settings types/defaults/dependencies, independent storage and OFF cleanup wiring; iOS runtime not tested')
