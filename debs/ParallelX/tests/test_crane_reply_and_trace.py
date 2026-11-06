"""Pinned device-static callback evidence and actual production root policy.
Not an iOS execution test; no device configuration or account content read.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]

class CraneReplyEvidence(unittest.TestCase):
    def test_no_biometric_branch_calls_set_active_then_replies_no(self):
        f = json.loads((ROOT / 'tests/fixtures/crane-reply-arm64e.json').read_text())
        instructions = {row['label']: row for row in f['instructions']}
        no = instructions['plain_reply_flag_no']
        yes = instructions['authenticated_reply_flag_yes']
        self.assertEqual(no['word'], 0x52800001)   # mov w1, #0
        self.assertEqual(yes['word'], 0x52800021)  # mov w1, #1
        for name in ('plain_switch_call', 'authenticated_switch_call'):
            call = instructions[name]
            self.assertEqual(call['word'] >> 26, 0x25)  # BL
            relative = call['word'] & 0x3ffffff
            if relative & (1 << 25):
                relative -= 1 << 26
            self.assertEqual(call['address'] + relative * 4, f['set_active_stub'])
        self.assertLess(instructions['plain_switch_call']['address'], no['address'])
        self.assertLess(no['address'], instructions['plain_reply_invoke']['address'])
        branch = instructions['requires_auth_false_branch']
        delta = ((branch['word'] >> 5) & 0x7ffff) * 4
        self.assertEqual(branch['address'] + delta, 0x8694)
        self.assertEqual(f['settings_key'], 'requireBiometricAuthentication')
        self.assertEqual(f['encoding'], 'v44@0:8@16@24B32@?36')

class RootAndTraceTests(unittest.TestCase):
    def test_production_root_selection_and_containment_policy(self):
        cc = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / 'root-policy'
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/root_policy_harness.c'), '-o', str(exe)],
                           check=True, capture_output=True, text=True)
            text = subprocess.check_output([str(exe)], text=True)
        self.assertGreater(int(re.search(r'root_policy_checks=(\d+)', text)[1]), 900)

    def test_real_pinned_directory_io_and_symlink_negative_cases(self):
        cc = shutil.which('cc') or shutil.which('clang')
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / 'trace-io'
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/trace_io_harness.c'), '-o', str(exe)],
                           check=True, capture_output=True, text=True)
            text = subprocess.check_output([str(exe)], text=True)
        self.assertGreater(int(re.search(r'trace_io_checks=(\d+)', text)[1]), 25)

    def test_current_domain_alias_cannot_be_migration_cleanup_target(self):
        p = (ROOT / 'Common/PXClonePaths.m').read_text()
        prefs = (ROOT / 'Common/PXClonePrefs.m').read_text()
        self.assertIn('source.st_dev == target.st_dev && source.st_ino == target.st_ino', p)
        self.assertIn('PXCloneIsCurrentPrefsFile(path)', prefs)
        self.assertIn('if (!before || !now || ![before isEqual:now]) continue;', prefs)
        self.assertIn('!reviewed || !PXSameDictionary(reviewed, PXReadDictionary(path, NULL))', prefs)
        self.assertIn('id domainStore = raw[PXStoreKey]', prefs)
        self.assertIn('domainStore : nil) : raw', prefs)

    def test_path_cache_and_candidate_scope_are_explicit(self):
        p = (ROOT / 'Common/PXClonePaths.m').read_text()
        self.assertIn('PXCloneJBROOT(@"/")', p)
        discovery = p.split('static NSString *PXDiscoverRoot', 1)[1].split('NSString *PXCloneActiveRoot', 1)[0]
        self.assertIn('PXCloneROOTFS(group)', discovery)
        self.assertIn('/Containers/Shared/AppGroup', discovery)
        self.assertNotIn('Bundle/Application', discovery.split('// One bounded', 1)[-1].split('NSMutableArray', 1)[-1])
        self.assertIn('PXCloneRootOutranks', discovery)
        self.assertIn('st.st_dev', discovery)
        self.assertIn('st.st_ino', discovery)
        self.assertIn('if (selectedRoot) return selectedRoot', p)
        self.assertIn('if (resolved) selectedRoot = [resolved copy]', p)
        self.assertIn('!PXCloneIsRootHide()', p)
        self.assertNotRegex(p, r'\.jbroot-[0-9a-fA-F-]{8,}')

    def test_directory_creation_cannot_precede_parent_scope_check(self):
        p = (ROOT / 'Common/PXClonePaths.m').read_text().split('BOOL PXCloneEnsureStorage', 1)[1]
        self.assertLess(p.index('PXClonePathIsContained'), p.index('createDirectoryAtPath'))
        self.assertIn('O_NOFOLLOW', p)
        self.assertIn('PXClonePathIsContained', p)

    def test_trace_is_confirmed_only_after_atomic_write_and_byte_readback(self):
        p = (ROOT / 'Common/PXCloneTrace.m').read_text()
        self.assertIn('static NSString *tracePath', p)
        self.assertIn('PXCloneCurrentTracePath(&error)', p)
        io = (ROOT / 'Common/PXCloneTraceIO.h').read_text()
        self.assertIn('PXCloneWriteTraceAt(directory,', p)
        self.assertEqual(p.count('PXTraceDirectoryIsCurrent(rootPath, parent, directory, rootIdentity)'), 2)
        self.assertIn('fchmod(file, 0600)', io)
        self.assertIn('AT_SYMLINK_NOFOLLOW', io)
        self.assertIn('!S_ISREG(old.st_mode)', io)
        self.assertIn('renameat(directory, temporary, directory, name)', io)
        self.assertIn('PXCloneTraceStatePathFailure', p)
        self.assertIn('PXCloneTraceStateSerializationFailure', p)
        self.assertIn('PXCloneTraceStateWriteFailure', p)
        self.assertIn('PXCloneTraceStateReadbackFailure', p)
        self.assertIn('memcmp(buffer, bytes + consumed', io)
        self.assertLess(p.index('PXCloneWriteTraceAt(directory,'), p.index('PXPublishTraceState(PXCloneTraceStatePersisted'))
        self.assertNotIn('writeToFile:tracePath', p)
        self.assertNotIn('error:NULL', p)
        self.assertNotIn('CFPreferencesSetAppValue', p)
        self.assertNotIn('snapshot = [snapshot', p)  # no assignment to a const block capture

    def test_file_failures_have_an_independent_status_and_visible_feedback(self):
        p = (ROOT / 'Common/PXCloneTrace.m').read_text()
        view = (ROOT / 'Prefs/PXCloneAccountsController.m').read_text()
        launch = (ROOT / 'Common/PXCloneLaunch.m').read_text()
        self.assertIn('notify_set_state', p)
        self.assertIn('notify_get_state', p)
        self.assertIn('PXCloneTraceNotification', view)
        self.assertIn('descriptionForState:traceState', view)
        self.assertIn('_reportedTraceState == state', launch)
        self.assertIn('[self showError:message]', launch)
        self.assertNotIn('CXStore', p)
        make = (ROOT / 'Makefile').read_text()
        self.assertEqual(make.count('Common/PXCloneTrace.m'), 2)

if __name__ == '__main__':
    unittest.main(verbosity=2)
