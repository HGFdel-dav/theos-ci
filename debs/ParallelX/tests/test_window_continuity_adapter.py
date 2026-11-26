"""Real production adapter functions; fake UIKit/dispatch/store boundaries.

Linux: strictly syntax-check the WHOLE fixture against iOS 15.5, then SKIP
Apple execution. macOS: compile with Foundation/CoreGraphics and RUN every case.
PXWM_REQUIRE_NATIVE=1 makes absent xcrun/native execution a hard failure.
No source-string assertions count as behavioral passes.
"""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/window_continuity_adapter'
SOURCE = ROOT / 'Common/PXWindowMemory.m'
FUNCTIONS = (
    'PXWMObject', 'PXWMBool', 'PXWMAppHash', 'PXWMFromRect', 'PXWMToRect', 'PXWMFindCard',
    'PXWMOpeningTicketOwnsCanvas', 'PXWMInitialFrameMayPrepare',
    'PXWMInitialHandoffOwnsCard', 'PXWMTicketMayUseIncomingAssociation',
    'PXWMBindingIsActive', 'PXWMReadGeometry', 'PXWMNormalGeometry',
    'PXWMDiagnosticReasonLog', 'PXWMFirstFrameSnapshot',
    'PXWMArmContinuity', 'PXWMContinuityReady', 'PXWMContentGeometry',
    'PXWMReconcileRuntimeFrame', 'PXWMQueueContentSync',
    'PXWMCaptureGestureOrientation', 'PXWMCaptureGestureFrame',
    'PXWMContextForGesture', 'PXWMSettleSave', 'PXWMGestureAction',
    'PXWMMove', 'PXWMResize', 'PXWMCardSetFrame',
)
CASES = ('begin', 'move_cancel', 'queue', 'content', 'reconcile_resize', 'frame_failure', 'diagnostics')


def extract_function(source, name):
    # Mask comments/literals without moving offsets. Braces inside diagnostics
    # or comments must not truncate the actual compiled production body.
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)
    pattern = r'^static\s+[^;{}]*?\b' + re.escape(name) + r'\s*\([^;{}]*?\)\s*\{'
    matches = list(re.finditer(pattern, masked, re.M))
    if len(matches) != 1:
        raise RuntimeError(f'{name}: expected one production definition, got {len(matches)}')
    match = matches[0]
    depth = 1
    end = match.end()
    while depth and end < len(masked):
        depth += (masked[end] == '{') - (masked[end] == '}')
        end += 1
    if depth:
        raise RuntimeError(f'{name}: unterminated production definition')
    line = source.count('\n', 0, match.start()) + 1
    return f'#line {line} "{SOURCE}"\n' + source[match.start():end] + '\n'


def generate(destination):
    source = SOURCE.read_text()
    classes = []
    for name in ('PXWMContext', 'PXWMGesture'):
        for kind in ('interface', 'implementation'):
            match = re.search(r'@' + kind + r'\s+' + name + r'\b[\s\S]*?@end', source)
            if not match:
                raise RuntimeError(f'missing production {kind}: {name}')
            classes.append(match[0])
    gate = re.search(r'typedef NS_ENUM\(unsigned, PXWMGeometryGate\)[\s\S]*?};', source)
    if not gate:
        raise RuntimeError('missing production geometry gate')
    prelude = '''
@class PXWMGesture;
'''
    glue = '''
static const void *PXWMContextKey = &PXWMContextKey;
static const void *PXWMOpenTicketKey = &PXWMOpenTicketKey;
static const void *PXWMGestureKey = &PXWMGestureKey;
static NSHashTable<PXWMContext *> *PXWMContexts;
static Class PXWMCardClass;
static void (*PXWMOriginalLayout)(id,SEL);
static void (*PXWMOriginalMove)(id,SEL,id);
static void (*PXWMOriginalResize)(id,SEL,id);
static void (*PXWMOriginalCardSetFrame)(id,SEL,CGRect);
static BOOL ADClockWithinDeadline=YES;
static CFTimeInterval CACurrentMediaTime(void) { return ADClockWithinDeadline ? 1 : 100; }
static PXWMContext *PXWMContextForCardFrame(UIView *card) {
 for(PXWMContext *context in PXWMContexts) if(context.card==card) return context;
 return nil;
}
static BOOL PXWMExpansionTarget(PXWMContext *context,CGRect incoming,CGRect *result) {
 (void)context;(void)incoming;(void)result;return NO;
}
static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,const PXWMRect *frame,BOOL visible) {
 (void)context;(void)frame;(void)visible;return NO;
}
static unsigned PXWMLinkState(id a,id b) { return !a ? 0 : a==b ? 1 : 2; }
static unsigned PXWMIdentityState(id a,id b) { return !a ? 0 : [a isEqual:b] ? 1 : 2; }
static void PXWMQueueContentSync(PXWMContext *context);
static void PXWMLog(PXWMContext *context, NSString *event, NSDictionary *details) {
    (void)context; [ADEvents addObject:event]; [ADDetails addObject:details ?: @{}];
}
static void PXWMProbeContentGeometry(PXWMContext *context, unsigned stage) {
    (void)context; (void)stage; ADProbeCalls++;
}
'''
    text = '#import "fake_uikit.h"\n' + prelude + '\n'.join(classes) + '\n' + gate[0] + glue
    text += '\n'.join(extract_function(source, name) for name in FUNCTIONS)
    text += '\n#line 1 "cases.m"\n' + (FIXTURE / 'cases.m').read_text()
    destination.write_text(text)
    print(f'adapter extraction: functions={len(FUNCTIONS)} classes=2 source_sha256={hashlib.sha256(source.encode()).hexdigest()}', flush=True)


def run(command):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.stdout:
        print(result.stdout, end='', flush=True)
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr, flush=True)
    if result.returncode:
        raise AssertionError(f'command exited {result.returncode}')
    return result


@contextmanager
def build_directory():
    directory = Path(tempfile.mkdtemp(prefix='.build-', dir=FIXTURE))
    try:
        yield directory
    finally:
        # iSH's shared filesystem does not provide the inode identity required
        # by shutil's fd-safe rmtree; remove only our known flat build outputs.
        for child in directory.iterdir():
            child.unlink()
        directory.rmdir()


class WindowContinuityAdapter(unittest.TestCase):
    def test_whole_fixture_ios155_strict_syntax(self):
        if sys.platform == 'darwin':
            self.skipTest('iOS 15.5 cross syntax check is the Linux lane; native lane executes below')
        clang = shutil.which('clang')
        sdk = Path(os.environ.get('PXWM_IOS_SDK', '/opt/theos/sdks/iPhoneOS15.5.sdk'))
        self.assertTrue(clang, 'clang missing; tools are not auto-installed')
        self.assertTrue((sdk / 'SDKSettings.plist').exists(), 'iOS 15.5 SDK missing')
        # Generated files stay in the explicitly authorized fixture directory.
        with build_directory() as temp:
            generated = Path(temp) / 'adapter.m'
            generate(generated)
            run([clang, '-target', 'arm64-apple-ios15.5', '-isysroot', str(sdk),
                 '-fobjc-arc', '-fblocks', '-fsyntax-only', '-Wall', '-Wextra', '-Werror',
                 '-I' + str(ROOT / 'Common'), '-I' + str(FIXTURE), str(generated)])

    def test_native_foundation_behavior(self):
        xcrun = shutil.which('xcrun')
        if not xcrun or sys.platform != 'darwin':
            reason = 'Apple behavior SKIP: requires macOS Foundation and xcrun; Linux syntax is not behavioral proof'
            if os.environ.get('PXWM_REQUIRE_NATIVE') == '1' or sys.platform == 'darwin':
                self.fail('native behavior required on Apple runner: ' + reason)
            self.skipTest(reason)
        with build_directory() as temp:
            generated = Path(temp) / 'adapter.m'
            executable = Path(temp) / 'adapter'
            generate(generated)
            run([xcrun, '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
                 '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                 '-framework', 'CoreGraphics', '-I' + str(ROOT / 'Common'),
                 '-I' + str(FIXTURE), str(generated), '-o', str(executable)])
            for case in CASES:
                with self.subTest(case=case):
                    result = run([str(executable), case])
                    self.assertRegex(result.stdout, rf'PASS {case} checks=[1-9][0-9]*')


if __name__ == '__main__':
    unittest.main(verbosity=2)
