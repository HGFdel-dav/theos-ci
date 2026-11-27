#!/usr/bin/env python3
"""Production C gate + deterministic adapter models + source contract tests.
This is not an iOS build and does not execute the Objective-C/private APIs.
"""
from pathlib import Path
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCH = (ROOT / 'Common/PXCloneLaunch.m').read_text()
TWEAK = (ROOT / 'Tweak.xm').read_text()
CRANE = (ROOT / 'Common/PXCloneCrane.m').read_text()

class QueueModel:
    """Mirror latest-target-wins without cancelling external authentication."""
    def __init__(self):
        self.current = None
        self.pending = None
        self.auth_outstanding = False
        self.opened = []
        self.token = 0
        self.quarantined = False

    def request(self, target):
        if self.current == target:
            self.pending = None
        elif self.current:
            self.pending = target
        else:
            self.current = target
            self.token += 1

    def switch_started(self):
        self.auth_outstanding = True
        return self.token

    def switch_returned(self, token, raw_authentication_flag=False, active_matches=True):
        if token != self.token or not self.auth_outstanding:
            return
        # A real callback returns both NO/YES; only active readback determines
        # whether the chosen account may be opened. Never emulate cancellation
        # by treating the raw NO flag as a failed callback.
        self.auth_outstanding = False
        if self.pending or self.quarantined or not active_matches:
            self.drain()
        else:
            self.opened.append(('split', self.current))
            self.drain()

    def drain(self):
        self.current = None
        self.quarantined = False
        if self.pending:
            target, self.pending = self.pending, None
            self.request(target)

    def timeout(self):
        if self.auth_outstanding:
            self.quarantined = True

class LaunchQueueTests(unittest.TestCase):
    def test_a_b_a_and_new_c_all_use_split(self):
        m = QueueModel()
        for target in ['A', 'B', 'A', 'C', 'A']:
            m.request(target)
            token = m.switch_started()
            m.switch_returned(token)
        self.assertEqual(m.opened, [('split', x) for x in ['A', 'B', 'A', 'C', 'A']])

    def test_return_to_a_is_not_cancelled_by_pending_b(self):
        m = QueueModel()
        m.request('A')
        token = m.switch_started()
        m.request('B')
        m.request('A')
        self.assertIsNone(m.pending)
        m.switch_returned(token)
        self.assertEqual(m.opened, [('split', 'A')])

    def test_pending_return_a_waits_for_actual_b_callback(self):
        m = QueueModel()
        m.request('B')
        old = m.switch_started()
        m.request('A')
        self.assertEqual(m.current, 'B')
        m.switch_returned(old)
        self.assertEqual(m.current, 'A')
        self.assertEqual(m.opened, [])
        new = m.switch_started()
        m.switch_returned(old)  # stale B callback cannot open B or finish A
        self.assertTrue(m.auth_outstanding)
        m.switch_returned(new)
        self.assertEqual(m.opened, [('split', 'A')])

    def test_quarantine_never_starts_concurrent_authentication(self):
        m = QueueModel()
        m.request('B')
        token = m.switch_started()
        m.timeout()
        m.request('A')
        self.assertEqual(m.current, 'B')
        self.assertTrue(m.auth_outstanding)
        m.switch_returned(token)
        self.assertEqual(m.current, 'A')
        self.assertFalse(m.auth_outstanding)
        self.assertEqual(m.opened, [])

    def test_wrong_active_after_callback_never_opens_account(self):
        m = QueueModel()
        m.request('B')
        m.switch_returned(m.switch_started(), raw_authentication_flag=False, active_matches=False)
        self.assertEqual(m.opened, [])

    def test_real_no_and_yes_callbacks_both_open_only_after_matching_active(self):
        for raw in (False, True):
            m = QueueModel()
            m.request('B')
            m.switch_returned(m.switch_started(), raw_authentication_flag=raw, active_matches=True)
            self.assertEqual(m.opened, [('split', 'B')])

    def test_cancel_without_callback_never_enters_readback_or_open(self):
        m = QueueModel()
        m.request('B')
        m.switch_started()
        m.timeout()  # Crane has not delivered a callback
        self.assertTrue(m.auth_outstanding)
        self.assertTrue(m.quarantined)
        self.assertEqual(m.opened, [])

    def test_only_consecutive_duplicate_is_debounced(self):
        last, accepted = None, []
        for target in ['A', 'A', 'B', 'A']:
            if target != last:
                accepted.append(target)
            last = target
        self.assertEqual(accepted, ['A', 'B', 'A'])

class ProductionGateTests(unittest.TestCase):
    def test_production_c_flow_executes_on_host(self):
        compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler, 'host C compiler required for production policy test')
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / 'flow'
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(ROOT / 'tests/flow_harness.c'), '-o', str(exe)], check=True,
                           capture_output=True, text=True)
            output = subprocess.check_output([str(exe)], text=True)
        count = int(re.search(r'production_flow_checks=(\d+)', output)[1])
        self.assertGreater(count, 80000)

class LaunchSourceGuards(unittest.TestCase):
    def test_single_controller_for_all_clone_items(self):
        self.assertIn('requestBundle:bundle container:container', TWEAK)
        self.assertNotIn('if ([active isEqualToString:container])', TWEAK)
        self.assertNotIn('PXCurrentTransition', TWEAK)
        self.assertNotIn('PXLiveTransitions', TWEAK)
        self.assertNotIn('0.8 * NSEC_PER_SEC', TWEAK)

    def test_raw_crane_flag_never_short_circuits_actual_account_verification(self):
        callback = CRANE.split('void (^callback)(BOOL)', 1)[1].split('    @try {', 1)[0]
        self.assertIn('reply(rawAuthenticationFlag)', callback)
        self.assertNotIn('activeContainerForBundle:', callback)
        self.assertNotIn('&&', callback)
        self.assertNotIn('verified', callback)
        header = (ROOT / 'Common/PXCloneCrane.h').read_text()
        self.assertIn('NOT a success flag', header)
        self.assertIn('requestSwitchToContainer:', header)
        self.assertIn('PXCloneFlowAcceptCraneReply(&self->_flow, token, rawAuthenticationFlag)', LAUNCH)
        self.assertIn('crane_reply_no', LAUNCH)
        self.assertIn('crane_reply_yes', LAUNCH)
        self.assertIn('container_readback_empty', LAUNCH)
        self.assertIn('container_readback_timeout', LAUNCH)

    def test_only_authenticated_no_reload_api(self):
        self.assertIn('reloadApplication:usingBiometricsIfNeededWithSuccessHandler:', CRANE)
        self.assertIn('manager, selector, containerID, bundleID, NO, callback', CRANE)
        self.assertIn('reloadApplicationWithIdentifier:', CRANE + TWEAK + LAUNCH)
        self.assertNotIn('+ (BOOL)selectContainer:', CRANE)
        self.assertIn('if (returned) return;', CRANE)

    def test_close_then_wait_real_exit_then_authenticate(self):
        self.assertIn('switcherRemovedApplication:', LAUNCH)
        self.assertIn('PXCloneFlowClosing, PXCloneFlowTerminating', LAUNCH)
        self.assertIn('applicationProcessesForBundleIdentifier:', LAUNCH)
        self.assertIn('isRunning', LAUNCH)
        self.assertIn('kill(value.intValue, 0)', LAUNCH)
        self.assertIn('errno != ESRCH', LAUNCH)
        self.assertNotIn('SIGKILL', LAUNCH)
        self.assertIn('进程列表查询异常', LAUNCH)
        self.assertIn('if (!available || (raw &&', LAUNCH)
        self.assertIn('_oldProcesses.count == 1 && _oldPIDs.count == 1', LAUNCH)
        self.assertNotIn('_oldProcesses.count == 0 ||', LAUNCH)

    def test_real_bridge_owner_and_non_nil_native_builder(self):
        self.assertIn('PXLaunchClass(@"PXSceneBridge")', LAUNCH)
        self.assertIn('openApplication:inView:keyboardOverlay:completion:', LAUNCH)
        self.assertIn('PXOriginalHostedOpen(self, command, bundle, canvas, overlay, wrapped)', LAUNCH)
        self.assertIn('@"externalOpenApplication:"', LAUNCH)
        self.assertNotIn('@"applicationActivated:"', LAUNCH)
        self.assertNotIn('@"prepareWindowForBundleID:wasFullscreen:completion:"', LAUNCH)

    def test_native_completion_and_visible_surface_both_required(self):
        self.assertIn('_nativeOpenReturned', LAUNCH)
        self.assertIn('hasHostedSurface', LAUNCH)
        self.assertIn('ancestor.hidden || ancestor.alpha <= 0.1', LAUNCH)
        self.assertIn('CGRectIntersection', LAUNCH)
        self.assertIn('PXCloneFlowMaySucceed', LAUNCH)
        self.assertIn('activeContainerForBundle:_bundle', LAUNCH)

    def test_missing_native_completion_retries_only_without_weakening_success_gates(self):
        self.assertIn('if (!_reuse && _openingBridge && !_completionReceived && _splitRetries < 2)', LAUNCH)
        self.assertIn('[self recordOpenDiagnostic:@"open_timeout_before_retry" force:YES];', LAUNCH)
        start=LAUNCH.index('- (void)retrySplit:(uint64_t)token {')
        end=LAUNCH.index('- (void)nativeOpenReturned:',start)
        retry=LAUNCH[start:end]
        self.assertIn('activeContainerForBundle:self->_bundle', retry)
        self.assertIn('native_retry_account_mismatch', retry)
        self.assertIn('if (_pending) { [self finish:token error:nil]; return; }', retry)
        succeed=LAUNCH.split('if (PXCloneFlowMaySucceed(',1)[1].split('}',1)[0]
        self.assertIn('verified, visible', succeed)
        self.assertIn('_nativeOpenReturned', LAUNCH)
        self.assertIn('hasHostedSurface', LAUNCH)

        self.assertIn('if ([controller tokenForOpeningBundle:bundle] == token && weakBridge)', LAUNCH)
        self.assertIn('if (completionDelivered)', LAUNCH)
        self.assertIn('completionDelivered = YES;', LAUNCH)
        self.assertIn('PXCloneFlowQuarantined', LAUNCH)
        self.assertIn('authentication_quarantined', LAUNCH)
        self.assertNotIn('[PXCurrentTransition cancel]', TWEAK + LAUNCH)
        self.assertNotIn('controller->_', LAUNCH)

    def test_new_accounts_refresh_on_real_change_and_menu_open(self):
        self.assertIn('_observers_didChangeContainersOfApplicationWithIdentifier:', TWEAK)
        self.assertIn('_observers_didChangeContainerSettingsForContainerWithIdentifier:onApplicationWithIdentifier:', TWEAK)
        self.assertIn('UIGestureRecognizerStateBegan', TWEAK)
        self.assertIn('PXRefreshInFlight', TWEAK)
        self.assertIn('PXRefreshPending', TWEAK)

    def test_trace_is_bounded_private_and_same_mapped_domain(self):
        writer = (ROOT / 'Common/PXCloneTrace.m').read_text()
        paths = (ROOT / 'Common/PXClonePaths.m').read_text()
        self.assertIn('_trace.count > 32', LAUNCH)
        self.assertIn('PXCloneTrace writeEvents:snapshot', LAUNCH)
        self.assertIn('self->_reportedTraceState = state;', LAUNCH)
        self.assertIn('PXCloneCurrentTracePath(&error)', writer)
        self.assertIn('PXCloneEnsureStorage(&error)', writer)
        self.assertIn('PXCloneWriteTraceAt(directory,', writer)
        io = (ROOT / 'Common/PXCloneTraceIO.h').read_text()
        self.assertIn('renameat(directory, temporary, directory, name)', io)
        self.assertIn('memcmp(buffer, bytes + consumed', io)
        self.assertIn('PXTraceDirectoryIsCurrent(rootPath, parent, directory, rootIdentity)', writer)
        self.assertIn('static NSString *tracePath', writer)
        self.assertIn('.launch-trace', paths)
        self.assertNotIn('/var/mobile/Library/Preferences', LAUNCH + writer)
        self.assertNotIn('standardUserDefaults', LAUNCH + writer)
        self.assertNotIn('CFPreferencesSetAppValue', LAUNCH + writer)
        self.assertNotIn('/var/jb', LAUNCH + writer)
        self.assertNotIn('jbroot-', LAUNCH + writer)
        self.assertNotIn('NSLog(', LAUNCH + writer)
        self.assertNotIn('syslog(', LAUNCH + writer)
        self.assertNotIn('system(', LAUNCH + writer)

    def test_no_unscoped_fullscreen_or_url_launch_hooks(self):
        blocked = LAUNCH.split('- (BOOL)blocksFullscreen:(NSString *)bundle {')[1].split('\n}', 1)[0]
        self.assertIn('_flow.phase == PXCloneFlowOpening', blocked)
        self.assertIn('[_bundle isEqual:bundle]', blocked)
        # Only exact, ABI-checked selectors may be hooked - never a wildcard.
        self.assertNotIn('FBSOpenApplication', LAUNCH)
        self.assertIn('openURL:options:completionHandler:', TWEAK)
        self.assertIn('openSensitiveURL:withOptions:', TWEAK)
        self.assertIn('PXCloneClassInstanceMethodMatches(app, options', TWEAK)

class LaunchDiagnosticProductionTests(unittest.TestCase):
    def compile_harness(self, root, output):
        cc = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(cc)
        subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                        str(root / 'tests/launch_diagnostics_harness.c'), '-o', str(output)],
                       check=True, capture_output=True, text=True)

    def test_real_diagnostic_policy_selection_and_pinned_disk_roundtrip(self):
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / 'launch-diagnostics'
            self.compile_harness(ROOT, exe)
            result = subprocess.check_output([str(exe)], text=True)
        self.assertGreater(int(re.search(r'launch_diagnostics_checks=(\d+)', result)[1]), 8400)

    def test_production_mutations_are_caught_not_just_marker_strings(self):
        changes = [
            ('PXCloneLaunchDiagnostics.h', 'return checked & ~passed & PXLaunchDiagAll;', 'return checked & passed & PXLaunchDiagAll;'),
            ('PXCloneLaunchDiagnostics.h', 'if (!force && state->hasWritten)', 'if (state->hasWritten)'),
            ('PXCloneTraceHistory.h', 'if (duplicate) continue;', 'if (duplicate) { /* deliberate mutation */ }'),
            ('PXCloneTraceHistory.h', 'before.st_size > PXCloneTraceReadLimit', 'before.st_size > PXCloneTraceReadLimit + 10'),
        ]
        for name, old, new in changes:
            with self.subTest(header=name, mutation=old), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'Common').mkdir(); (root / 'tests').mkdir()
                for file in ('PXCloneLaunchDiagnostics.h', 'PXCloneTraceHistory.h', 'PXCloneTraceIO.h'):
                    shutil.copy(ROOT / 'Common' / file, root / 'Common' / file)
                shutil.copy(ROOT / 'tests/launch_diagnostics_harness.c', root / 'tests')
                path = root / 'Common' / name
                text = path.read_text(); self.assertEqual(text.count(old), 1)
                path.write_text(text.replace(old, new))
                exe = root / 'mutant'; self.compile_harness(root, exe)
                import resource
                def no_core(): resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
                result = subprocess.run([str(exe)], capture_output=True, preexec_fn=no_core)
                self.assertNotEqual(result.returncode, 0, 'mutated production policy escaped executable negative test')

    def test_existing_visibility_loop_is_byte_identical_to_published_baseline(self):
        loop = LAUNCH.split('- (void)pollOpened:(uint64_t)token {', 1)[1]
        loop = loop.split('    NSArray *candidates', 1)[1].split('    if (_pending)', 1)[0]
        # alpha440+clone0.102: all original gates and early exits retained.
        self.assertEqual(hashlib.sha256(loop.encode()).hexdigest(),
                         '9789e316362d2a14822fd1b6cb9d349c2fd367d7de9492d11422f7e47d0d6188')
        self.assertNotIn('PXLaunchDiagnostic', loop)
        self.assertIn('if (++_attempt >= 100)', LAUNCH)
        self.assertIn('if (_splitRetries < 2)', LAUNCH)
        self.assertIn('if (_pending)', LAUNCH)

    def test_last_snapshot_is_forced_before_native_cleanup(self):
        finish = LAUNCH.split('- (void)finish:(uint64_t)token error:(NSError *)error {', 1)[1].split('- (void)record:', 1)[0]
        self.assertLess(finish.index('recordOpenDiagnostic:@"open_before_cleanup" force:YES'),
                        finish.index('@"switcherRemovedApplication:"'))
        self.assertLess(finish.index('@"switcherRemovedApplication:"'),finish.index('record:@"failed"'))
        self.assertLess(finish.index('record:@"failed"'),finish.index('showError:error.localizedDescription'))
        self.assertIn('PXCloneTrace writeEvents:snapshot completion:',LAUNCH)
        writer_tail=LAUNCH.split('PXCloneTrace writeEvents:snapshot completion:',1)[1].split('    } transactions:_transactions];',1)[0]
        self.assertIn('self->_reportedTraceState = state;',writer_tail)
        self.assertNotIn('showError:',writer_tail)
        self.assertNotIn('_pendingErrorNotices',LAUNCH)
        self.assertIn('@"CXLaunchFailures": mergedFailures', (ROOT/'Common/PXCloneTrace.m').read_text())
        self.assertIn('lastOpen', LAUNCH)
        self.assertIn('failureID', LAUNCH)
        self.assertNotIn('NSNull', LAUNCH)  # NSNull is not property-list encodable (offscreen intersection!)
        self.assertIn('@"valid": @NO', LAUNCH)
        observer = LAUNCH.split('- (void)observeOpenCandidates:(NSArray *)candidates visible:(BOOL)visible active:(NSString *)active {', 1)[1].split('- (void)recordOpenDiagnostic:', 1)[0]
        for forbidden in ('finish:', 'retrySplit:', 'PXCloneFlowMaySucceed', 'switcherRemovedApplication:', 'PXRequestTermination'):
            self.assertNotIn(forbidden, observer)
        self.assertIn('@catch', observer)

    def test_history_is_loaded_and_only_committed_after_verified_write(self):
        writer = (ROOT / 'Common/PXCloneTrace.m').read_text()
        self.assertLess(writer.index('PXCloneReadTraceAt('), writer.index('PXCloneWriteTraceAt('))
        self.assertLess(writer.index('PXCloneWriteTraceAt('), writer.index('failures = mergedFailures;'))
        self.assertIn('@"CXLaunchTrace": limited ?: @[]', writer)
        self.assertIn('@"CXLaunchFailures": mergedFailures', writer)
        self.assertIn('PXCloneTraceStateReadbackFailure', writer)
        self.assertIn('data.length > PXCloneTraceReadLimit', writer)
        self.assertIn('PXCloneTraceImportLegacyEvents', writer)


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('xcrun'),
                     'Apple Foundation/notify runtime required; portable C and I/O tests execute separately')
class LaunchTraceAppleWriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.build.name) / 'trace-writer'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-parameter', '-framework', 'Foundation',
                        str(ROOT / 'tests/trace_writer_host.m'), str(ROOT / 'Common/PXCloneTrace.m'),
                        '-o', str(cls.binary)], check=True)
    @classmethod
    def tearDownClass(cls): cls.build.cleanup()
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'Containers/Shared/AppGroup/.jbroot-fixture'
        self.parent = self.root / 'var/mobile/Library/Preferences'
        self.parent.mkdir(parents=True)
        self.env = {**os.environ, 'PXTRACE_TEST_ROOT': str(self.root)}
        self.file = self.parent / 'fixture.launch-trace.plist'
    def tearDown(self): self.temp.cleanup()
    def action(self, action):
        result = subprocess.run([str(self.binary), action], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)['state']
    def read(self): return plistlib.loads(self.file.read_bytes())

    def test_failure_survives_successes_and_writer_process_restarts(self):
        self.assertEqual(self.action('fail'), 1)
        saved = self.read()['CXLaunchFailures'][0]
        for _ in range(5): self.assertEqual(self.action('success'), 1)
        doc = self.read()
        self.assertEqual(doc['CXLaunchFailures'], [saved])
        self.assertEqual(saved['code'], 19)
        self.assertEqual(saved['summary']['lastOpen']['poll'], 100)
        self.assertLessEqual(len(saved['events']), 12)
        self.assertEqual(len(doc['CXLaunchTrace']), 32)
        self.assertFalse(any(e['stage'] == 'failed' for e in doc['CXLaunchTrace']))
        self.assertEqual(self.file.stat().st_mode & 0o777, 0o600)

    def test_repeated_snapshots_deduplicate_and_fifth_failure_evicts_only_oldest(self):
        self.assertEqual(self.action('duplicate'), 1)
        self.assertEqual(len(self.read()['CXLaunchFailures']), 1)
        first = self.read()['CXLaunchFailures'][0]['failureID']
        for _ in range(4): self.assertEqual(self.action('fail'), 1)
        history = self.read()['CXLaunchFailures']
        self.assertEqual(len(history), 4)
        self.assertNotIn(first, [item['failureID'] for item in history])

    def test_legacy_failed_summary_is_imported_without_inventing_gate(self):
        self.file.write_bytes(plistlib.dumps({'CXLaunchTrace': [
            {'stage': 'failed', 'code': 19, 'token': 1, 'time': 100.0}]}))
        self.assertEqual(self.action('success'), 1)
        failure = self.read()['CXLaunchFailures'][0]
        self.assertEqual(failure['code'], 19)
        self.assertTrue(failure['summary']['legacy'])
        self.assertNotIn('lastOpen', failure['summary'])

    def test_corrupt_file_is_preserved_not_replaced_by_success(self):
        original = b'broken prior evidence'
        self.file.write_bytes(original)
        self.assertEqual(self.action('success'), 5)
        self.assertEqual(self.file.read_bytes(), original)

    def test_symlink_cannot_redirect_history_read_or_write(self):
        target = Path(self.temp.name) / 'protected'
        target.write_bytes(b'keep this')
        self.file.symlink_to(target)
        self.assertEqual(self.action('success'), 5)
        self.assertEqual(target.read_bytes(), b'keep this')

    def test_account_configuration_is_never_rewritten(self):
        account = self.parent / 'com.niubiprass.clonex.plist'
        original = plistlib.dumps({'CXStore': {'fixture': ['preserve']}})
        account.write_bytes(original)
        self.assertEqual(self.action('fail'), 1)
        self.assertEqual(self.action('success'), 1)
        self.assertEqual(account.read_bytes(), original)

class QuietDiagnosticSourceTests(unittest.TestCase):
    def test_original_error_ui_remains_byte_identical(self):
        start=LAUNCH.index('- (void)showError:(NSString *)message {')
        end=LAUNCH.index('\n@end',start)
        self.assertEqual(hashlib.sha256(LAUNCH[start:end].encode()).hexdigest(),
                         '28e3793f4066e88abc58b8b0236416134403cb3969902ab377b82ebc10083345')
        for text in ('诊断编号', '日志已保存', '日志未确认保存', 'PXCloneFailureNotice', '_pendingErrorNotices'):
            self.assertNotIn(text,LAUNCH)

    def test_failure_id_and_final_snapshot_are_retained_without_user_input(self):
        record=LAUNCH.split('- (void)record:(NSString *)stage code:(NSInteger)code {',1)[1].split('- (void)showError:',1)[0]
        self.assertIn('NSString *failureID = NSUUID.UUID.UUIDString;',record)
        self.assertIn('entry[@"failureID"] = failureID;',record)
        self.assertIn('@"lastOpen": _lastOpenDiagnostic ?: @{}',record)
        writer=record.split('PXCloneTrace writeEvents:snapshot completion:',1)[1]
        self.assertNotIn('showError:',writer)
        history=(ROOT/'Common/PXCloneTraceHistory.h').read_text()
        self.assertIn('record[@"events"] = transaction;',history)
        self.assertIn('PXCloneFailureLimit = 4',history)
        self.assertIn('PXCloneFailureEventLimit = 12',history)

if __name__ == '__main__':
    unittest.main(verbosity=2)
