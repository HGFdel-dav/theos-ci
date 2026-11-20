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
        for old,new in [('observedEpoch == currentEpoch','(observedEpoch == currentEpoch || true)'),
                        ('g.frame.x >= g.reference.x - tolerance','true'),
                        ('(!resolved || (keyKnown && previousKey != currentKey))',
                         '(!resolved || !keyKnown || previousKey != currentKey)'),
                        ('orientationKnown && gestureKey == currentKey &&', 'orientationKnown &&')]:
            with self.subTest(old=old), tempfile.TemporaryDirectory() as temp:
                target=Path(temp)
                (target/'Common').mkdir(); (target/'tests').mkdir()
                self.assertEqual(policy.count(old),1)
                (target/'Common/PXWindowMemoryPolicy.h').write_text(policy.replace(old,new))
                shutil.copy2(ROOT/'tests/window_memory_harness.c',target/'tests/harness.c')
                binary=target/'negative'
                subprocess.run(['cc','-std=c11','-Wno-unused-parameter',str(target/'tests/harness.c'),'-lm','-o',str(binary)],check=True)
                run=subprocess.run([str(binary)],capture_output=True,text=True)
                self.assertNotEqual(run.returncode,0)

    def test_native_method_table_bytes_match_fixture(self):
        fixture=json.loads((ROOT/'tests/fixtures/window-memory-alpha391-abi.json').read_text())
        image=(ROOT/fixture['sample']).read_bytes()
        self.assertEqual(hashlib.sha256(image).hexdigest(),fixture['sample_sha256'])
        def relative(pos): return pos+struct.unpack_from('<i',image,pos)[0]
        def cstr(pos): return image[pos:image.index(b'\0',pos)].decode()
        for method in fixture['methods']:
            with self.subTest(selector=method['selector']):
                entry=method['entry']
                self.assertEqual(relative(entry+8),method['imp'])
                self.assertEqual(cstr(relative(entry+4)),method['encoding'])
                name=relative(entry)
                if 0x8e5b8<=name<0x8f8b8: name=struct.unpack_from('<Q',image,name)[0]&0xffffffff
                self.assertEqual(cstr(name),method['selector'])

class WindowMemorySourceGuards(unittest.TestCase):
    def test_hooks_guard_exact_abi_and_forward_native_arguments(self):
        source=(ROOT/'Common/PXWindowMemory.m').read_text()
        for selector in ('moveHost:', 'resizeHost:', 'openApplication:inView:keyboardOverlay:completion:',
                         'layoutHost','viewDidLayoutSubviews'):
            self.assertIn(selector,source)
        self.assertIn('PXCloneClassInstanceMethodMatches',source)
        self.assertIn('PXWMOriginalOpen(self,command,bundle,canvas,overlay,completion)',source)
        for forbidden in ('SIGKILL','terminateApplication:','externalOpenApplication:',
                          'object_getIvar','PXCloneFunctionAt','method_setImplementation'):
            self.assertNotIn(forbidden,source)
        self.assertIn('PXWindowMemoryInstall(', (ROOT/'Tweak.xm').read_text())

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
        self.assertTrue(all(event['build']=='clone0.93' for event in logs))

if __name__ == '__main__': unittest.main(verbosity=2)
