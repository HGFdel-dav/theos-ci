#!/usr/bin/env python3
"""Production C gate + deterministic adapter models + source contract tests.
This is not an iOS build and does not execute the Objective-C/private APIs.
"""
from pathlib import Path
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
        self.assertNotIn('reloadApplicationWithIdentifier:', CRANE + TWEAK + LAUNCH)
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

    def test_late_callbacks_and_quarantine_are_guarded(self):
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
        self.assertNotIn('openURL', LAUNCH + TWEAK)
        self.assertNotIn('FBSOpenApplication', LAUNCH)

if __name__ == '__main__':
    unittest.main(verbosity=2)
