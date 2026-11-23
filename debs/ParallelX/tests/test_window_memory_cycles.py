"""Portable production cycle policy + native byte evidence, not UIKit acceptance."""
import hashlib,json,re,shutil,struct,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Common/PXWindowMemory.m').read_text()
STORE=(ROOT/'Common/PXWindowMemoryStore.m').read_text()
POLICY=(ROOT/'Common/PXWindowMemoryPolicy.h').read_text()

class WindowMemoryCycles(unittest.TestCase):
    def compile_run(self,root,mutation=False):
        exe=root/'cycle'
        flags=['-Wno-unused-parameter'] if mutation else []
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',*flags,str(root/'tests/window_memory_cycle_harness.c'),'-lm','-o',str(exe)],check=True,capture_output=True)
        return subprocess.run([str(exe)],capture_output=True,text=True)
    def test_production_cycle_replays_failure_and_preserves_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);(d/'Common').mkdir();(d/'tests').mkdir()
            (d/'Common/PXWindowMemoryPolicy.h').write_text(POLICY)
            shutil.copyfile(ROOT/'tests/window_memory_cycle_harness.c',d/'tests/window_memory_cycle_harness.c')
            p=self.compile_run(d)
            self.assertEqual(p.returncode,0,p.stderr)
            self.assertGreater(int(re.search(r'checks=(\d+)',p.stdout)[1]),3000)
    def test_mutations_are_killed_by_real_production_policy(self):
        for old,new in [
            ('PXWMGeometry next = saved;', 'PXWMGeometry next = observed;'),
            ('eventActive && wasParked && bindingActive && generationMatches &&','eventActive && bindingActive &&'),
            ('!interacting && !savePending && epochMatches && !alreadyApplied;', '!interacting;'),
            ('return startingSizeKnown && PXWMValidRect(before)', 'return PXWMValidRect(before)'),
        ]:
            with self.subTest(mutation=old),tempfile.TemporaryDirectory() as tmp:
                d=Path(tmp);(d/'Common').mkdir();(d/'tests').mkdir()
                self.assertEqual(POLICY.count(old),1)
                (d/'Common/PXWindowMemoryPolicy.h').write_text(POLICY.replace(old,new))
                shutil.copyfile(ROOT/'tests/window_memory_cycle_harness.c',d/'tests/window_memory_cycle_harness.c')
                self.assertNotEqual(self.compile_run(d,mutation=True).returncode,0)
    def test_save_kind_is_carried_from_original_recognizer(self):
        gesture=SOURCE.split('static void PXWMGestureAction(',1)[1].split('static void PXWMMove(',1)[0]
        self.assertIn('stamp.resizing = command == NSSelectorFromString(@"resizeHost:")',gesture)
        self.assertIn('PXWMCaptureGestureFrame(context, &startingFrame)',gesture)
        self.assertLess(gesture.index('stamp.startingFrame = startingFrame'),gesture.index('if (original) original(panel,command,gesture);',gesture.index('stamp.startingFrame')))
        settle=SOURCE.split('static void PXWMSettleSave(',1)[1].split('static void PXWMGestureAction(',1)[0]
        self.assertIn('if (stamp.resizing)',settle)
        self.assertIn('PXWMUserSizeChanged(stamp.startingSizeKnown, stamp.startingFrame, geometry.frame)',settle)
        self.assertIn('savePosition:geometry',settle)
        self.assertIn('saveGeometry:geometry',settle)
        self.assertIn('gesture_cancel_no_save',gesture)
    def test_position_merge_occurs_under_latest_document_lock(self):
        fn=STORE.split('- (void)change:',1)[1].split('- (void)saveGeometry:',1)[0]
        self.assertLess(fn.index('[self lockDocument:&error]'),fn.index('PXWMUpdateRememberedPosition(latest, geometry, &merged)'))
        self.assertIn('!PXWMUnpackGeometry(frames[key], &latest)',fn)
        self.assertIn('if (!noRememberedSize && !error && ![frames[key] isEqual:packed])',fn)
        self.assertIn('position_no_size_no_save',fn)
        self.assertIn('if (ok && changed)',fn)
        self.assertIn('[self writeDocument:next name:PXWMStateFile error:&error]',fn)
        self.assertIn('![confirmed isEqual:next]',fn)
        self.assertIn('notify_post(PXWindowMemoryNotification.UTF8String)',fn)
    def test_expansion_scope_is_native_event_not_a_frame_timer(self):
        expand=SOURCE.split('static BOOL PXWMIsParked(',1)[1].split('/* The vendor',1)[0]
        self.assertIn('context.canvas.window != triggerWindow',expand)
        self.assertIn('PXWMMayApplyExpansion',expand)
        self.assertIn('@finally { PXWMExpansionScope = previous;',expand)
        for forbidden in ('dispatch_after','dispatch_async','saveGeometry:','savePosition:', 'card.frame =', 'object_getIvar','PXCloneFunctionAt','objc_msgSend','context.resolved = NO'):
            self.assertNotIn(forbidden,expand)
        hook=SOURCE.split('static void PXWMCardSetFrame(',1)[1].split('static void PXWMScheduleInitialSettle(',1)[0]
        self.assertLess(hook.index('PXWMExpansionTarget(context, frame, &expandedTarget)'),hook.index('PXWMOriginalCardSetFrame(self, command, frame)'))
        self.assertIn('event.applied = YES;',expand)
        self.assertIn('PXWMRestore(saved, geometry.reference, nativeFrame, &restored)',expand)
        self.assertIn('PXCloneClassInstanceMethodMatches(dockCoordinator, restoreDock, @encode(void), objects)',SOURCE)
    def test_park_cancels_late_save_without_replacing_the_native_gesture(self):
        park=SOURCE.split('static void PXWMPrepareForNativePark(',1)[1].split('static PXWMContext *PXWMDetachBinding(',1)[0]
        self.assertIn('context.generation++;',park)
        self.assertIn('context.savePending = NO; context.pendingGesture = nil;',park)
        self.assertIn('context.initialTargetActive = NO;',park)
        self.assertIn('PXWMOriginalDockTapped(self, command, sender)',park)
        self.assertIn('PXWMOriginalBottomDoubleTapped(self, command)',park)
        self.assertIn('PXWMOriginalBottomHeld(self, command, gesture)',park)
        self.assertNotIn('saveGeometry:',park)
        self.assertNotIn('savePosition:',park)
        self.assertNotIn('card.frame =',park)
        settle=SOURCE.split('static void PXWMSettleSave(',1)[1].split('static void PXWMGestureAction(',1)[0]
        self.assertIn('!context.savePending || context.pendingGesture != stamp',settle)
        action=SOURCE.split('static BOOL PXWMConfiguredAction(',1)[1].split('/* The vendor',1)[0]
        self.assertIn('return PXWMOriginalConfiguredAction(self, command, action)',action)
        self.assertIn('return PXWMOriginalConfiguredActionSearch(self, command, action, fromSearch)',action)

    def test_dock_hooks_match_original_relative_method_table(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha440-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        start,end=(int(v,16) for v in fixture['selref_range'])
        def relative(a):return a+struct.unpack_from('<i',image,a)[0]
        def cstr(a):return image[a:image.index(b'\0',a)].decode()
        for m in fixture['dock_methods']:
            a=int(m['entry'],16)
            self.assertEqual(relative(a+8),int(m['imp'],16))
            self.assertEqual(cstr(relative(a+4)),m['encoding'])
            name=relative(a)
            if start<=name<end:name=struct.unpack_from('<Q',image,name)[0]&0xffffffff
            self.assertEqual(cstr(name),m['selector'])

    def test_native_alpha440_dock_frame_is_set_before_native_content_layout(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha440-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        self.assertEqual(hashlib.sha256(image).hexdigest(),fixture['sample_sha256'])
        def word(a):return struct.unpack_from('<I',image,a)[0]
        def branch(a):
            w=word(a);self.assertIn(w>>26,(0b100101,0b000101))
            o=w&0x3ffffff;o=o-(1<<26) if o&(1<<25) else o
            return a+o*4
        # ObjC method entry -> verified Swift thunk, not a guessed Swift ABI call.
        self.assertEqual(branch(0x4c68c),0x4c4fc)
        self.assertEqual(branch(0x4c614),0x49204)
        self.assertEqual(branch(0x39448),0x49204) # native external-open reuse
        self.assertEqual(word(0x54570),0xf9400a80) # captured existing docked host
        self.assertEqual(branch(0x5457c),0x4f620)
        self.assertEqual(word(0x4f650),0xf9400c14) # card at native dockedHost+24
        # setTransform -> setFrame -> layoutIfNeeded -> bridge.layoutHost
        for a,ref,selector in [(0x4f658,0x96f48,b'setTransform:'),(0x4f67c,0x96e28,b'setFrame:'),(0x4f69c,0x96bd0,b'layoutIfNeeded'),(0x4f6b0,0x96bc8,b'layoutHost')]:
            self.assertEqual((word(a)>>10)&0xfff,(ref&4095)//8)
            name=struct.unpack_from('<Q',image,ref)[0]&0xffffffff
            self.assertEqual(image[name:image.index(b'\0',name)],selector)

if __name__=='__main__':unittest.main(verbosity=2)
