#!/usr/bin/env python3
"""Source checks locally; real production excerpts run with Foundation on macOS."""
from pathlib import Path
import argparse, hashlib, json, platform, shutil, subprocess, tempfile, unittest, os
D=Path(os.environ.get('DYYY_TEST_ROOT',Path(__file__).resolve().parents[1]))
P=D/'source/debs/DYYY'
BASELINE_PATH=Path(os.environ.get('DYYY_BASELINE_JSON',D/'evidence/BASELINE.json'))
BASE=json.loads(BASELINE_PATH.read_text())

def function(text, signature):
    start=text.index(signature)
    opening=text.index('{',start)
    depth=0
    for i in range(opening,len(text)):
        if text[i]=='{': depth+=1
        elif text[i]=='}':
            depth-=1
            if depth==0: return text[start:i+1]
    raise AssertionError('Unclosed production body: '+signature)

def layout(text):
    sections=[]
    for tail in text.split('%hook AWEPlayInteractionViewController\n')[1:]:
        section=tail.split('\n%end',1)[0]
        if '- (void)speedButtonTapped:(UIButton *)sender' in section:
            sections.append(section)
    assert len(sections)==1, 'Expected one speed-button interaction hook'
    return function(sections[0],'- (void)viewDidLayoutSubviews')

def native_source():
    xm=(P/'DYYY.xm').read_text()
    speed=(P/'DYYYFloatSpeedButton.m').read_text()
    fixture=(D/'tests/native_speed_label.m').read_text()
    bodies=[]
    for sig in ['static BOOL DYYYSpeedValuesMatch(', 'NSInteger getCurrentSpeedIndex(', 'float getCurrentSpeed(', 'void setCurrentSpeedIndex(', 'BOOL setCurrentSpeedValue(', 'void updateSpeedButtonUI(']:
        bodies.append(function(speed,sig))
    for sig in ['static void DYYYClearLongPressSpeedState(', 'static BOOL DYYYAwemeModelsMatch(', 'static NSString *DYYYSpeedAwemeIdentifier(', 'static double DYYYDefaultPlaybackSpeed(', 'static void DYYYRestoreFloatSpeedButtonForAwemeIfNeeded(', 'static void DYYYEnsureFloatSpeedButton(']:
        bodies.append(function(xm,sig))
    prefix=layout(xm).split('    UIViewController *directParentVC',1)[0]
    assert prefix.count('%orig;')==1
    prefix=prefix.replace('%orig;','gOriginalLayouts++;')+'}\n'
    category='@implementation AWEPlayInteractionViewController (LayoutFixture)\n'+prefix+'@end\n'
    return fixture.replace('/* PRODUCTION_EXCERPTS */','\n\n'.join(bodies)+'\n'+category)

class SourceContract(unittest.TestCase):
    def test_reused_page_refreshes_speed_state_before_early_returns(self):
        body=layout((P/'DYYY.xm').read_text())
        self.assertEqual(body.count('DYYYEnsureFloatSpeedButton(self);'),1)
        self.assertIn('if (!self.viewIfLoaded.window) return;',body)
        self.assertIn('UIViewController *directParentVC',body)
        self.assertLess(body.index('if (!self.viewIfLoaded.window) return;'),body.index('DYYYEnsureFloatSpeedButton(self);'))
        self.assertLess(body.index('DYYYEnsureFloatSpeedButton(self);'),body.index('UIViewController *directParentVC'))
        self.assertEqual(body.count('%orig;'),1)
    def test_only_localized_layout_change(self):
        before=(Path(BASE['source'])/'DYYY.xm').read_text()
        after=(P/'DYYY.xm').read_text()
        old='    [DYYYFloatingButtonCoordinator registerInteractionController:self];\n\n    UIViewController *directParentVC'
        new='    // Reused feed pages must synchronize the speed index and title as well as visibility.\n    DYYYEnsureFloatSpeedButton(self);\n\n    UIViewController *directParentVC'
        self.assertEqual(before.count(old),1)
        self.assertEqual(after.replace(new,old,1),before)
    def test_existing_reset_is_once_per_video_and_opt_in(self):
        body=function((P/'DYYY.xm').read_text(),'static void DYYYRestoreFloatSpeedButtonForAwemeIfNeeded(')
        for token in ['DYYYEnableFloatSpeedButton','DYYYAutoRestoreSpeed','isEqualToString:dyyyLastAutoRestoredSpeedAwemeIdentifier','DYYYDefaultPlaybackSpeed()','updateSpeedButtonUI();']:
            self.assertIn(token,body)
    def test_button_format_and_click_implementation_unchanged(self):
        name='DYYYFloatSpeedButton.m'
        self.assertEqual(hashlib.sha256((P/name).read_bytes()).hexdigest(),BASE['files'][name])
    def test_no_other_project_files_change(self):
        allowed={'DYYY.xm','DYYYConstants.h','control'}
        files={str(f.relative_to(P)):hashlib.sha256(f.read_bytes()).hexdigest() for f in P.rglob('*') if f.is_file()}
        self.assertEqual(set(files),set(BASE['files']))
        self.assertFalse([name for name in files if name not in allowed and files[name]!=BASE['files'][name]])
    def test_previous_visibility_fix_preserved(self):
        for name in ['DYYYFloatingButtonCoordinator.h','DYYYFloatingButtonCoordinator.m']:
            self.assertEqual(hashlib.sha256((P/name).read_bytes()).hexdigest(),BASE['files'][name])
    def test_native_fixture_uses_actual_production_bodies(self):
        source=native_source()
        self.assertNotIn('/* PRODUCTION_EXCERPTS */',source)
        self.assertIn('gOriginalLayouts++;',source)
        self.assertIn('dyyyLastAutoRestoredSpeedAwemeIdentifier = [awemeIdentifier copy];',source)

class NativeBehavior(unittest.TestCase):
    @unittest.skipUnless(platform.system()=='Darwin' and shutil.which('xcrun'),'requires macOS Foundation; not run on iSH')
    def test_production_excerpt_runtime(self):
        with tempfile.TemporaryDirectory(prefix='dyyy-speed-label-') as temp:
            root=Path(temp); src=root/'fixture.m'; binary=root/'fixture'
            src.write_text(native_source())
            subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(src),'-o',str(binary)],check=True,timeout=90)
            subprocess.run([str(binary)],check=True,timeout=15)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--require-native',action='store_true'); args,rest=parser.parse_known_args()
    if args.require_native and (platform.system()!='Darwin' or not shutil.which('xcrun')):
        raise SystemExit('REQUIRED_NATIVE_UNAVAILABLE: macOS Foundation/xcrun needed; not a PASS')
    unittest.main(argv=[__file__]+rest,verbosity=2)
