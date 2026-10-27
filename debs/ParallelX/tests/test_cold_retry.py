#!/usr/bin/env python3
"""Host-side guards for the cold-start retry. No iOS runtime, no ABI execution.

These only prove the *source* keeps the agreed contract:
  - retry arms only on cold start
  - retry never touches payment / chooser / container-switch code paths
  - retry is bounded (2 retries) and converges in both directions
  - success cancels, duplicates do not stack
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = (ROOT / 'pxclone/CXHook.m').read_text()
RETRY = (ROOT / 'pxclone/CXColdRetry.inc').read_text()

MAX_ATTEMPTS = 3  # first try + two retries


class RetryModel:
    """Mirrors CXPollRetryState/CXStartColdRetryIfNeeded decision order."""

    def __init__(self):
        self.active = {}
        self.requests = []          # (bundle, attempt)
        self.log = []

    def start(self, bundle, running=False, chooser=False, route_pending=False):
        if running:
            self.log.append(('skip', bundle, 'hot'))
            return
        if chooser:
            self.log.append(('skip', bundle, 'chooser'))
            return
        if route_pending:
            self.log.append(('skip', bundle, 'route'))
            return
        if bundle in self.active:
            self.log.append(('skip', bundle, 'duplicate'))
            return
        self.active[bundle] = {'attempt': 1, 'last_pid': 0, 'elapsed': 0.0}
        self.requests.append((bundle, 1))

    def cancel(self, bundle):
        if bundle in self.active:
            del self.active[bundle]
            self.log.append(('cancel', bundle))

    def poll(self, bundle, pid, scene, elapsed):
        st = self.active.get(bundle)
        if st is None:
            return
        if scene:
            self.cancel(bundle)
            return
        died = st['last_pid'] > 0 and pid == 0
        if pid > 0:
            st['last_pid'] = pid
        if died or elapsed >= 5.0:
            if st['attempt'] >= MAX_ATTEMPTS:
                del self.active[bundle]
                self.log.append(('giveup', bundle, st['attempt']))
                return
            st['attempt'] += 1
            st['elapsed'] = 0.0
            if not died:
                st['last_pid'] = pid
            self.requests.append((bundle, st['attempt']))


class ColdStartRetryContract(unittest.TestCase):
    def test_cold_start_only(self):
        m = RetryModel()
        m.start('com.ss.iphone.ugc.Aweme', running=True)
        self.assertEqual(m.requests, [])
        m.start('com.ss.iphone.ugc.Aweme', running=False)
        self.assertEqual(m.requests, [('com.ss.iphone.ugc.Aweme', 1)])

    def test_skips_while_chooser_or_route_pending(self):
        for kwargs in ({'chooser': True}, {'route_pending': True}):
            m = RetryModel()
            m.start('x', **kwargs)
            self.assertEqual(m.requests, [], kwargs)

    def test_duplicate_click_does_not_stack(self):
        m = RetryModel()
        m.start('x')
        m.start('x')
        self.assertEqual(m.requests, [('x', 1)])
        self.assertIn(('skip', 'x', 'duplicate'), m.log)

    def test_process_death_triggers_retry_up_to_two(self):
        m = RetryModel()
        m.start('x')
        for expected in (2, 3):
            m.poll('x', pid=42, scene=False, elapsed=1.0)
            m.poll('x', pid=0, scene=False, elapsed=1.5)
            self.assertEqual(m.requests[-1], ('x', expected))
        m.poll('x', pid=43, scene=False, elapsed=1.0)
        m.poll('x', pid=0, scene=False, elapsed=1.5)
        self.assertNotIn('x', m.active)
        self.assertIn(('giveup', 'x', 3), m.log)
        self.assertEqual(len(m.requests), 3)

    def test_no_scene_timeout_retries_then_gives_up(self):
        m = RetryModel()
        m.start('x')
        m.poll('x', pid=42, scene=False, elapsed=5.0)
        m.poll('x', pid=42, scene=False, elapsed=5.0)
        m.poll('x', pid=42, scene=False, elapsed=5.0)
        self.assertEqual([a for _, a in m.requests], [1, 2, 3])
        self.assertNotIn('x', m.active)

    def test_success_cancels_and_stops_polling(self):
        m = RetryModel()
        m.start('x')
        m.poll('x', pid=42, scene=False, elapsed=1.0)
        m.poll('x', pid=42, scene=True, elapsed=1.5)
        self.assertNotIn('x', m.active)
        before = len(m.requests)
        m.poll('x', pid=42, scene=False, elapsed=9.0)
        self.assertEqual(len(m.requests), before)

    def test_window_is_three_attempts_never_unbounded(self):
        m = RetryModel()
        m.start('x')
        for _ in range(20):
            m.poll('x', pid=0, scene=False, elapsed=5.0)
        self.assertLessEqual(len(m.requests), MAX_ATTEMPTS)


class ColdStartRetrySource(unittest.TestCase):
    def test_armed_from_every_split_entry(self):
        # 分屏开窗有两个入口：CXOpenInSplit（分身/URL）与 openApplication 钩子
        # （面板点普通图标的主路径）。四个挂点，定义只在 .inc。
        self.assertEqual(HOOK.count('CXStartColdRetryIfNeeded('), 4)
        self.assertEqual(RETRY.count('static void CXStartColdRetryIfNeeded('), 1)
        self.assertRegex(HOOK, r'CXInternalOpen = wasInternal;\s*\}\s*\n\s*//[^\n]*\n\s*CXStartColdRetryIfNeeded\(bundleID\);')

    def test_open_application_arms_after_forwarding(self):
        # 必须先把请求转交给 PX，再挂重试；普通图标那支还要先判字符串
        body = re.search(r'static void CXOpenAppHook.*?\n\}', HOOK, re.S).group(0)
        self.assertEqual(body.count('CXStartColdRetryIfNeeded'), 3)
        self.assertRegex(body, r'CXOrigOpenApp\(self, _cmd, app, view, overlay, completion\);\s*\n\s*//[^\n]*\n\s*if \(\[app isKindOfClass:NSString\.class\]\) CXStartColdRetryIfNeeded\(app\);')

    def test_payment_and_chooser_paths_untouched(self):
        # 选账号函数体里不应出现 retry 调用
        body = re.search(r'static void CXPromptContainerThenOpen.*?\n\}', HOOK, re.S).group(0)
        self.assertNotIn('CXStartColdRetryIfNeeded', body)
        self.assertNotIn('CXCancelColdRetry', body)

    def test_success_signal_cancels(self):
        body = re.search(r'static void CXPrepareWindow.*?\n\}', HOOK, re.S).group(0)
        self.assertIn('CXCancelColdRetry(bundleID)', body)
        self.assertIn('CXCancelColdRetry(realBundle)', body)

    def test_bounded_and_guarded(self):
        self.assertIn('state.attempt >= 3', RETRY)
        self.assertEqual(RETRY.count('state.attempt >= 3'), 2)
        self.assertIn('CXShowingChooser', RETRY)
        self.assertIn('CXSystemRoutePending', RETRY)
        self.assertIn('already retrying', RETRY)

    def test_no_fullscreen_fallback(self):
        # 只重发分屏请求，不碰 applicationActivated / 全屏
        self.assertNotIn('applicationActivated', RETRY)
        self.assertIn('CXOpenInSplitImpl(bundleID)', RETRY)

    def test_retry_stays_internal(self):
        self.assertIn('CXInternalOpen = YES', RETRY)
        self.assertIn('CXInternalOpen = wasInternal', RETRY)

    def test_module_is_included_once(self):
        self.assertEqual(HOOK.count('#include "CXColdRetry.inc"'), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
