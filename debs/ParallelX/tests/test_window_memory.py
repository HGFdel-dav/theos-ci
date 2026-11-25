"""Run production C everywhere; production Foundation storage on Apple hosts.
UIKit hooking and final visible effects still require the authorized device gate.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WindowMemoryPolicy(unittest.TestCase):
    def test_production_geometry_and_epoch_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / 'geometry'
            subprocess.run([shutil.which('cc') or 'cc', '-std=c11','-Wall','-Wextra','-Werror',
                            str(ROOT/'tests/window_memory_harness.c'),'-lm','-o',str(binary)], check=True)
            text = subprocess.check_output([str(binary)], text=True)
            self.assertIn('WINDOW_MEMORY_POLICY_PASS', text)
            self.assertGreater(int(text.split('checks=')[1]), 4000)

    def test_real_harness_rejects_broken_epoch_and_bounds(self):
        policy = (ROOT/'Common/PXWindowMemoryPolicy.h').read_text()
        policies = [
            (policy,[('observedEpoch == currentEpoch','(observedEpoch == currentEpoch || true)'),
                     ('g.frame.x >= g.reference.x - tolerance','true'),
                     ('(!resolved || (keyKnown && previousKey != currentKey))','(!resolved || !keyKnown || previousKey != currentKey)'),
                     ('orientationKnown && gestureKey == currentKey &&','orientationKnown &&'),
                     ('!state->initialCleanupSeen && !state->cancelled','!state->cancelled'),
                     ('matchingCanvasAndBundle && state->initialCleanupSeen','state->initialCleanupSeen'),
                     ('directionKnown && gestureKey == currentKey &&','directionKnown &&'),
                     ('!normalGeometry && samples < maximumSamples','true'),
                     ('if (!*known) { *known = true; *gestureKey = currentKey; return true; }',
                      '{ *known = true; *gestureKey = currentKey; return true; }'),
                     ('return *gestureKey == currentKey;','return true;'),
                     ('currentTicket && nativeEntering && cleanupSeen && !cancelled','currentTicket && nativeEntering'),
                     ('owns && matchingCanvasAndBundle && loaded && enabled &&','owns &&'),
                     ('!resolved && !interacting && !savePending;','!resolved;')]),
        ]
        for source, mutations in policies:
            for old,new in mutations:
                with self.subTest(old=old), tempfile.TemporaryDirectory() as temp:
                    target=Path(temp); (target/'Common').mkdir(); (target/'tests').mkdir()
                    self.assertEqual(source.count(old),1,old)
                    (target/'Common/PXWindowMemoryPolicy.h').write_text(source.replace(old,new))
                    shutil.copy2(ROOT/'tests/window_memory_harness.c',target/'tests/harness.c')
                    binary=target/'negative'
                    subprocess.run(['cc','-std=c11','-Wno-unused-parameter',str(target/'tests/harness.c'),'-lm','-o',str(binary)],check=True)
                    run=subprocess.run([str(binary)],capture_output=True,text=True)
                    self.assertNotEqual(run.returncode,0)

    def test_native_method_table_bytes_match_fixture(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha455-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        self.assertEqual(hashlib.sha256(image).hexdigest(),fixture['sample_sha256'])
        start, end = (int(value,16) for value in fixture['selref_range'])
        def relative(pos): return pos+struct.unpack_from('<i',image,pos)[0]
        def cstr(pos): return image[pos:image.index(b'\0',pos)].decode()
        for method in fixture['methods']:
            with self.subTest(selector=method['selector']):
                entry=int(method['entry'],16)
                self.assertEqual(relative(entry+8),int(method['imp'],16))
                self.assertEqual(cstr(relative(entry+4)),method['encoding'])
                name=relative(entry)
                if start<=name<end: name=struct.unpack_from('<Q',image,name)[0]&0xffffffff
                self.assertEqual(cstr(name),method['selector'])

    def test_original_open_first_closes_old_window_then_sets_canvas(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha455-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        self.assertEqual(hashlib.sha256(image).hexdigest(),fixture['sample_sha256'])
        def word(pos): return struct.unpack_from('<I',image,pos)[0]
        def sign(n,bits): return (n^(1<<(bits-1)))-(1<<(bits-1))
        previous=0
        for call in fixture['open_calls']:
            pos, stub, ref=(int(call[key],16) for key in ('at','stub','selref'))
            self.assertGreater(pos,previous)
            self.assertEqual(word(pos)>>26,0b100101) # BL
            self.assertEqual(pos+4*sign(word(pos)&0x3ffffff,26),stub)
            adrp, ldr=word(stub), word(stub+4)
            self.assertEqual(adrp&0x9f00001f,0x90000001) # ADRP x1
            self.assertEqual(ldr&0xffc003ff,0xf9400021) # LDR x1, [x1, #offset]
            pages=sign(((adrp>>5)&0x7ffff)*4+((adrp>>29)&3),21)
            self.assertEqual((stub&~4095)+(pages<<12)+((ldr>>10)&0xfff)*8,ref)
            name=struct.unpack_from('<Q',image,ref)[0]&0xffffffff
            self.assertEqual(image[name:image.index(b'\0',name)].decode(),call['selector'])
            previous=pos
        self.assertEqual([call['selector'] for call in fixture['open_calls']],
                         ['close','setCanvas:','setKeyboardOverlay:','setBundleID:'])

class WindowMemorySourceGuards(unittest.TestCase):
    def test_hooks_guard_exact_abi_and_forward_native_arguments(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        for selector in ('moveHost:', 'resizeHost:', 'openApplication:inView:keyboardOverlay:completion:',
                         'layoutHost','viewDidLayoutSubviews'):
            self.assertIn(selector,source)
        self.assertIn('PXCloneClassInstanceMethodMatches',source)
        self.assertIn('PXWMOriginalOpen(self,command,bundle,canvas,overlay,completion)',source)
        for forbidden in ('SIGKILL','terminateApplication:',
                          'object_getIvar','PXCloneFunctionAt','method_setImplementation'):
            self.assertNotIn(forbidden,source)
        # The new exact class-method hook only observes and forwards the native
        # external-open event; it must never send an extra open/retry request.
        self.assertIn('PXCloneClassMethodMatches(panel, externalOpen, @encode(void), objects, NULL)',source)
        self.assertNotIn('PXCloneSendVoid',source.split('static void PXWMExternalOpen(',1)[1].split('/* A parked app',1)[0])
        self.assertNotIn('objc_msgSend',source.split('static void PXWMExternalOpen(',1)[1].split('/* A parked app',1)[0])
        self.assertIn('PXWindowMemoryInstall(', (ROOT/'Tweak.xm').read_text())
        self.assertIn('PXWMScheduleRestore(ticket)',source)
        self.assertIn('restore_retry_scheduled',source)
        self.assertIn('static BOOL PXWMForegroundNotifying;',source)
        self.assertIn('static BOOL PXWMLoadNotifying;',source)
        self.assertIn('if (!PXWMForegroundNotifying)',source)
        self.assertIn('if (!PXWMLoadNotifying)',source)
        self.assertIn('if (context && !context.resolved) PXWMScheduleRestore(context)',source)
        self.assertLess(source.index('if (!PXWMForegroundNotifying)'),source.index('if (!PXWMLoadNotifying)') )
        self.assertIn('restore_geometry_ready',source)
        self.assertIn('save_skipped_non_normal_or_reset',source)
        self.assertIn('PXWMResolveGestureOrientation(YES, &orientationKnown, &orientation, key)',source)
        self.assertNotIn('&stamp.orientationKnown',source)
        self.assertNotIn('&stamp.orientation,',source)
        self.assertIn('PXWMMayWaitForGestureGeometry(normal, stamp.samples, 30)',source)
        self.assertIn('context.savePending = NO',source)
        self.assertIn('currentEpoch',source)
        self.assertIn('UIApplicationDidBecomeActiveNotification',source)
        self.assertIn('restore_retry_limit',source)
        self.assertIn('restore_retry_direction_changed',source)
        self.assertIn('const NSUInteger maxAttempts = 100',source)
        self.assertIn('if (animation && attempt < 20)',source)
        self.assertIn('PXWMResolveGestureOrientation(true,&known,&firstKey,0)',
                      (ROOT/'tests/window_memory_harness.c').read_text())
        self.assertIn('PXWMCaptureGestureOrientation(context, &startingKey)',source)
        self.assertIn('PXWMMayWaitForGestureGeometry',source)

    def test_memory_binding_is_published_only_after_native_open_returns(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        start=source.index('static void PXWMOpen(')
        end=source.index('static void PXWMLayout(',start)
        method=source[start:end]
        forwarded=method.rindex('PXWMOriginalOpen(self,command,bundle,canvas,overlay,forwardCompletion)')
        publish=method.index('objc_setAssociatedObject(self, PXWMContextKey, ticket')
        self.assertLess(method.index('objc_setAssociatedObject(self, PXWMOpenTicketKey, ticket'),forwarded)
        self.assertLess(forwarded,method.index('PXWMNativeReturned(&ticket->native'))
        self.assertLess(method.index('PXWMNativeReturned(&ticket->native'),publish)
        self.assertLess(publish,method.index('PXWMTryRestore(ticket)'))
        close=source[source.index('static void PXWMClose('):source.index('static void PXWMControllerLayout(')]
        self.assertIn('PXWMNativeClose(&ticket->native)',close)
        self.assertIn('if (PXWMOriginalClose) PXWMOriginalClose(self,command);',close)
        self.assertNotIn('return;',close)

    def test_initial_geometry_is_prepared_before_native_content_layout(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        method=source.split('static void PXWMLayout(id self,SEL command) {',1)[1].split('static void PXWMClose(',1)[0]
        self.assertLess(method.index('PXWMPrepareInitialLayout(context)'),method.index('PXWMOriginalLayout(self,command)'))
        self.assertIn('PXWMOpenTicketKey',method)
        controller=source.split('static void PXWMControllerLayout(',1)[1].split('static Class PXWMVendorClass(',1)[0]
        self.assertIn('context->native.entering && !context.resolved',controller)
        self.assertLess(controller.index('PXWMPrepareInitialLayoutWithNativeFrame(context, NULL, YES)'),controller.index('PXWMTryRestore(context)'))
        prepare=source.split('static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,\n                                                   const PXWMRect *nativeFrameOverride,\n                                                   BOOL allowingVisibleTicket) {',1)[1].split('\nstatic BOOL PXWMPrepareInitialLayout(',1)[0]
        for check in ('PXWMMayPrepareInitialLayout(', 'context->native.initialCleanupSeen',
                      'PXWMReadGeometry(context, YES', 'PXWindowMemoryGeometry(snapshot, context.bundle, key',
                      'PXWMRestore(saved, native.reference, native.frame', 'restore_initial_geometry_prepared'):
            self.assertIn(check,prepare)
        self.assertNotIn('PXCloneSendVoid',prepare)  # Never recursively invoke native layout.
        self.assertNotIn('saveGeometry:',prepare)   # Preparing a record is not a user save.
        normal=source.split('static BOOL PXWMNormalGeometry(',1)[1].split('static void PXWMVerifyRestore(',1)[0]
        self.assertIn('PXWMReadGeometry(context, NO',normal)
        for forbidden in ('card.hidden =','card.alpha =','window.hidden =','removeAllAnimations',
                          'setAnimationDuration:0','setFrame:(CGRect)'):
            self.assertNotIn(forbidden,source)

    def test_saved_frame_precedes_native_content_recalculation(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        restore=source.split('static void PXWMTryRestore(',1)[1].split('static BOOL PXWMCaptureGestureOrientation(',1)[0]
        perform=restore.split('[UIView performWithoutAnimation:^{',1)[1].split('}];',1)[0]
        self.assertLess(perform.index('card.frame = requested;'),perform.index('PXCloneSendVoid(context.bridge, layout)'))
        self.assertLess(restore.index('PXCloneSendVoid(context.bridge, layout)'),restore.index('CGRect actual = card.frame'))
        initial=source.split('static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,\n                                                   const PXWMRect *nativeFrameOverride,\n                                                   BOOL allowingVisibleTicket) {',1)[1].split('\nstatic BOOL PXWMPrepareInitialLayout(',1)[0]
        self.assertNotIn('PXWMOriginalLayout(context.bridge',initial)
        open_method=source.split('static void PXWMOpen(',1)[1].split('static void PXWMLayout(',1)[0]
        completion=open_method.split('forwardCompletion = ^(BOOL ok) {',1)[1].split('nativeCompletion(ok);',1)[0]
        self.assertNotIn('PXWMOriginalLayout(self, NSSelectorFromString(@"layoutHost"))',completion)
        self.assertIn('0x6aef8', (ROOT/'evidence/native-layout/README.md').read_text())

    def test_initial_open_frame_write_is_redirected_and_content_remeasured_once(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        hook=source.split('static void PXWMCardSetFrame(',1)[1].split('/* One settle pass',1)[0]
        self.assertIn('context.initialTargetActive',hook)
        self.assertIn('PXWMContextForCardFrame((UIView *)self)',hook)
        preflight=hook.split('BOOL preflightReady =',1)[1].split('if (context && context.initialTargetActive',1)[0]
        self.assertIn('PXWMInitialFrameMayPrepare(context)',preflight)
        self.assertIn('context.initialTargetActive',preflight)
        self.assertIn('PXWMReadGeometry(context, YES, &pendingDefault, &pending, &key)',preflight)
        self.assertIn('window.hidden',source)
        self.assertIn('PXWMOpeningTicketOwnsCanvas(context, context.canvas)',source)
        self.assertIn('PXWMRect initialNative = context.initialNativeFrame;',preflight)
        self.assertIn('PXWMPrepareInitialLayoutWithNativeFrame(context, &initialNative, YES)',preflight)
        self.assertIn('if (!geometryReady)',preflight)
        self.assertLess(preflight.index('PXWMReadGeometry(context, YES, &pendingDefault, &pending, &key)'),preflight.index('PXWMPrepareInitialLayoutWithNativeFrame(context, &initialNative, YES)'))
        self.assertIn('CACurrentMediaTime() < context.initialTargetDeadline',hook)
        self.assertIn('frame = target;',hook)
        self.assertIn('context.initialNativeFrame',hook)
        self.assertIn('if (sameNative && !same)',hook)
        self.assertLess(hook.index('if (sameNative && !same)'),hook.index('frame = target;'))
        self.assertLess(hook.index('restore_initial_frame_substituted'),hook.index('PXWMOriginalCardSetFrame(self, command, frame)'))
        settle=source.split('static void PXWMScheduleInitialSettle(',1)[1].split('static BOOL PXWMPrepareInitialLayout(',1)[0]
        self.assertIn('current.initialTargetActive = NO;',settle)
        self.assertIn('restore_initial_settle_skipped_native_change',settle)
        self.assertLess(settle.index('if (!matches && !nativeDefault)'),settle.index('card.frame = target;'))
        self.assertLess(settle.index('card.frame = target;'),settle.index('PXWMOriginalLayout(current.bridge, NSSelectorFromString(@"layoutHost"))'))
        self.assertIn('current.initialContentRefreshed = YES;',settle)
        self.assertNotIn('PXWMScheduleInitialSettle(current)',settle)
        prepare=source.split('static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,\n                                                   const PXWMRect *nativeFrameOverride,\n                                                   BOOL allowingVisibleTicket) {',1)[1].split('static BOOL PXWMPrepareInitialLayout(PXWMContext *context)',1)[0]
        self.assertIn('PXWMMayPrepareInitialLayout(',prepare)
        self.assertIn('visibleTicketPermission',prepare)
        self.assertIn('store.isLoaded && [snapshot[@"enabled"] boolValue]',prepare)
        self.assertIn('context.initialTargetDeadline = CACurrentMediaTime() + 2.0;',prepare)
        gesture=source.split('static void PXWMGestureAction(',1)[1].split('static void PXWMMove(',1)[0]
        self.assertIn('context.initialTargetActive = NO;',gesture)
        detach=source.split('static PXWMContext *PXWMDetachBinding(id bridge)',1)[1].split('\n}',1)[0]
        self.assertIn('context.initialTargetActive = NO;',detach)
        install=source.split('PXWM_HOOK(panel,move',1)[1]
        self.assertIn('PXWM_HOOK(PXWMCardClass,cardFrame,PXWMCardSetFrame,',install)
        self.assertIn('PXWMOriginalSetSourceSize',install)
        source_size=source.split('static void PXWMSetSourceSize(',1)[1].split('\n}',1)[0]
        self.assertLess(source_size.index('PXWMOriginalSetSourceSize(self, command, size)'),source_size.index('PXWMPrepareInitialLayoutWithNativeFrame(context, NULL, YES)'))
        self.assertIn('PXWMOpeningTicketOwnsCanvas(candidate, candidate.canvas)',source_size)
        self.assertNotIn('dispatch_after',source_size)

    def test_initial_geometry_requires_native_source_size_not_default_canvas_axes(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        read=source.split('static BOOL PXWMReadGeometry(',1)[1].split('static BOOL PXWMNormalGeometry(',1)[0]
        self.assertIn('CGSize content = CGSizeZero;',read)
        self.assertIn('else if (!preparingInitialLayout)',read)
        self.assertIn('!isfinite(content.width)',read)
        self.assertIn('content.width <= 0 || content.height <= 0',read)
        self.assertIn('if (!preparingInitialLayout)',read)
        self.assertIn('!PXWMObject(context.bridge, @"scene")',read)
        self.assertIn('hasHostedSurface',read)
        self.assertIn('BOOL ticketOwnsIncoming = PXWMTicketMayUseIncomingAssociation(context, preparingInitialLayout) && bundleMatches;',read)
        self.assertIn('BOOL bridgeCanvasMatches = PXWMObject(context.bridge, @"canvas") == canvas;',read)
        self.assertIn('BOOL bundleMatches = [bridgeBundle isEqual:context.bundle] || bridgeBundle == nil;',read)
        self.assertIn('&& !ticketOwnsIncoming) return NO;',read)
        self.assertIn('PXWMInitialFrameMayPrepare',source)
        self.assertNotIn('BOOL ticketBeforeBundle = preparingInitialLayout && currentTicket && bridgeBundle == nil;',read)
        self.assertNotIn('(![bridgeBundle isEqual:context.bundle] && !ticketBeforeBundle)',read)
        check=source.split('static void PXWMVerifyRestore(',1)[1].split('static BOOL PXWMPrepareInitialLayout(',1)[0]
        self.assertIn('PXWMBindingIsActive(check)',check)
        self.assertIn('check.generation != expectedGeneration',check)
        self.assertIn('check.savePending',check)
        self.assertIn('unsignedLongLongValue] != epoch',check)

    def test_alpha455_native_layout_reads_actual_source_size(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha455-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        self.assertEqual(hashlib.sha256(image).hexdigest(),fixture['sample_sha256'])
        def word(pos): return struct.unpack_from('<I',image,pos)[0]
        def sign(n,bits): return (n^(1<<(bits-1)))-(1<<(bits-1))
        def branch(pos):
            w=word(pos)
            self.assertIn(w>>26,(0b100101,0b000101))
            return pos+4*sign(w&0x3ffffff,26)
        imp=next(m['imp'] for m in fixture['methods'] if m['selector']=='layoutHost')
        self.assertEqual(word(int(imp,16)),0xd503237f)  # pacibsp prologue
        # layoutHost reads the real hosted source size through its own stub.
        self.assertEqual(word(0x6af48)>>26,0b100101)
        self.assertEqual(branch(0x6af48),0x7f620)
        stub=0x7f620
        a,l=word(stub),word(stub+4)
        self.assertEqual(a&0x9f00001f,0x90000001)
        self.assertEqual(l&0xffc003ff,0xf9400021)
        pages=sign(((a>>5)&0x7ffff)*4+((a>>29)&3),21)
        ref=(stub&~4095)+(pages<<12)+((l>>10)&0xfff)*8
        self.assertEqual(ref,0x9f090)
        name=struct.unpack_from('<Q',image,ref)[0]&0xffffffff
        self.assertEqual(image[name:image.index(b'\x00',name)],b'sourceSize')
        # hostedSourceSize is a tail branch to that same getter, not a separate guess.
        tail=next(m['imp'] for m in fixture['methods'] if m['selector']=='hostedSourceSize')
        self.assertEqual(word(int(tail,16))>>26,0b000101)
        self.assertEqual(branch(int(tail,16)),stub)

    def test_only_user_completed_geometry_can_save(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        self.assertIn('UIGestureRecognizerStateEnded',source)
        self.assertIn('gesture_cancel_no_save',source)
        self.assertIn('isHostedKeyboardVisible',source)
        self.assertIn('fullscreenHandoff',source)
        self.assertIn('CGAffineTransformIsIdentity',source)
        self.assertIn('stamp.generation != context.generation',source)
        region=source[source.index('static void PXWMClose'):source.index('static void PXWMControllerLayout')]
        self.assertNotIn('saveGeometry:',region)

    def test_store_root_is_pinned_and_does_not_touch_accounts(self):
        source=(ROOT/'Common/PXWindowMemoryStore.m').read_text()
        for required in ('PXCloneEnsureStorage','PXCloneCurrentPrefsPath', 'O_NOFOLLOW','flock(',
                         'PXCloneWriteTraceAt','PXCloneTraceIOVerified','readState:', 'notify_post'):
            self.assertIn(required,source)
        for forbidden in ('CFPreferencesSetAppValue','CXHiddenItems','NSHomeDirectory','@"/var/mobile/Library/Preferences'):
            self.assertNotIn(forbidden,source)
        self.assertIn('save_discarded_after_reset',source)
        self.assertIn('while (events.count > 256)',source)

    def test_ui_is_real_cached_and_entry_is_unique(self):
        source=(ROOT/'Prefs/PXWindowMemoryController.m').read_text()
        header=(ROOT/'Prefs/PXWindowMemoryController.h').read_text()
        self.assertIn(': PSListController',header)
        self.assertIn('if (!_specifiers)',source)
        self.assertIn('_specifiers = items',source)
        self.assertIn('UIAlertActionStyleCancel',source)
        data=plistlib.loads((ROOT/'layout/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist').read_bytes())
        entries=[row for row in data['items'] if row.get('detail')=='PXWindowMemoryController']
        self.assertEqual(len(entries),1)
        self.assertTrue(entries[0]['isController'])
        self.assertNotIn('bundle',entries[0])
        self.assertIn('PXWindowMemoryStore.m',(ROOT/'Makefile').read_text())

APPLE = sys.platform == 'darwin' and shutil.which('xcrun')
if sys.platform == 'darwin' and not APPLE:
    raise RuntimeError('Apple CI must execute the real Foundation storage tests, not skip them')

@unittest.skipUnless(APPLE, 'Apple Foundation compiler/runtime required; portable and source tests are separate')
class WindowMemoryAppleStorage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory()
        cls.binary=Path(cls.build.name)/'window-memory-store'
        subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',
                        '-framework','Foundation',str(ROOT/'tests/window_memory_store_host.m'),
                        str(ROOT/'Common/PXWindowMemoryStore.m'),'-o',str(cls.binary)],check=True)
    @classmethod
    def tearDownClass(cls): cls.build.cleanup()
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name).resolve()/'Containers/Shared/AppGroup/.jbroot-fixture'
        self.parent=self.root/'var/mobile/Library/Preferences'
        self.parent.mkdir(parents=True)
        self.env={**os.environ,'PXWM_TEST_ROOT':str(self.root)}
    def tearDown(self): self.temp.cleanup()
    def run_action(self,action,success=True):
        result=subprocess.run([str(self.binary),action],env=self.env,text=True,capture_output=True,timeout=20)
        self.assertEqual(result.returncode==0,success,result.stdout+result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])
    @property
    def statefile(self): return self.parent/'com.niubiprass.clonex.window-memory.plist'

    def test_real_store_roundtrip_across_processes(self):
        self.assertTrue(self.run_action('saveA')['ok'])
        state=self.run_action('read')['snapshot']
        self.assertEqual(state['apps']['com.example.a']['0'],[50,140,260,520,0,0,390,844])
        self.assertEqual(plistlib.loads(self.statefile.read_bytes()),state)
        self.assertEqual(self.statefile.stat().st_mode & 0o777,0o600)

    def test_clear_invalidates_late_save_and_keeps_enabled(self):
        self.run_action('saveA'); self.run_action('clear'); self.run_action('late')
        state=self.run_action('read')['snapshot']
        self.assertEqual(state['apps'],{})
        self.assertTrue(state['enabled'])
        self.assertGreater(state['epoch'],0)

    def test_disable_preserves_entries_but_rejects_new_save(self):
        self.run_action('saveA'); self.run_action('disable'); self.run_action('saveB')
        state=self.run_action('read')['snapshot']
        self.assertFalse(state['enabled'])
        self.assertIn('com.example.a',state['apps'])
        self.assertNotIn('com.example.b',state['apps'])
        self.run_action('enable'); self.run_action('saveB')
        self.assertIn('com.example.b',self.run_action('read')['snapshot']['apps'])

    def test_move_preserves_last_resize_size_and_cannot_create_size(self):
        self.run_action('move')
        self.assertEqual(self.run_action('read')['snapshot']['apps'],{})
        self.run_action('saveA')
        old=self.run_action('read')['snapshot']['apps']['com.example.a']['0']
        self.run_action('move')
        updated=self.run_action('read')['snapshot']['apps']['com.example.a']['0']
        self.assertEqual(updated[2:],old[2:])
        self.assertNotEqual(updated[:2],old[:2])
        self.run_action('moveNoSlot')
        self.assertNotIn('2',self.run_action('read')['snapshot']['apps']['com.example.a'])

    def test_position_transaction_uses_latest_size_and_respects_clear_disable(self):
        self.run_action('resizeThenMove')
        self.assertEqual(self.run_action('read')['snapshot']['apps']['com.example.a']['0'][2:4],
                         [220,476.10256410256414])
        self.run_action('moveThenResize')
        expected=self.run_action('read')['snapshot']['apps']['com.example.a']['0']
        self.assertEqual(expected[:4],[100,90,220,476.10256410256414])
        self.run_action('disable'); self.run_action('move')
        self.assertEqual(self.run_action('read')['snapshot']['apps']['com.example.a']['0'],expected)
        self.run_action('enable'); self.run_action('clear'); self.run_action('moveLate')
        self.assertEqual(self.run_action('read')['snapshot']['apps'],{})

    def test_concurrent_writers_merge_different_apps(self):
        jobs=[subprocess.Popen([str(self.binary),action],env=self.env,stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE,text=True) for action in ('saveA','saveB')]
        for job in jobs:
            out,err=job.communicate(timeout=25)
            self.assertEqual(job.returncode,0,out+err)
        self.assertEqual(set(self.run_action('read')['snapshot']['apps']),{'com.example.a','com.example.b'})

    def test_corrupt_document_is_not_overwritten(self):
        damaged=b'not a plist'
        self.statefile.write_bytes(damaged)
        state=self.run_action('read')
        self.assertFalse(state['loaded'])
        self.assertTrue(state['error'])
        self.run_action('saveA',success=False)
        self.assertEqual(self.statefile.read_bytes(),damaged)

    def test_symlink_state_cannot_overwrite_outside_root(self):
        outside=Path(self.temp.name)/'protected'
        outside.write_bytes(b'keep-this')
        self.statefile.symlink_to(outside)
        self.assertFalse(self.run_action('read')['loaded'])
        self.run_action('saveA',success=False)
        self.assertEqual(outside.read_bytes(),b'keep-this')

    def test_new_document_does_not_modify_account_preferences(self):
        accounts=self.parent/'com.niubiprass.clonex.plist'
        original=plistlib.dumps({'CXStore':{'CXHiddenItems':['fake#id']},'other':321})
        accounts.write_bytes(original)
        self.run_action('saveA'); self.run_action('clear'); self.run_action('disable')
        self.assertEqual(accounts.read_bytes(),original)

    def test_malformed_app_entry_never_raises(self):
        self.assertTrue(self.run_action('malformed')['ok'])

    def test_diagnostics_are_bounded_and_persisted(self):
        self.run_action('logs')
        filename=self.parent/'com.niubiprass.clonex.window-memory-diagnostics.plist'
        logs=plistlib.loads(filename.read_bytes())
        self.assertLessEqual(len(logs),256)
        self.assertGreater(len(logs),200)
        self.assertTrue(any(event['event']=='fixture' for event in logs))
        self.assertTrue(all(event['build']=='clone0.107' for event in logs))

if __name__ == '__main__': unittest.main(verbosity=2)
