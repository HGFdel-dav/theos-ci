#!/usr/bin/env python3
"""Host-side regression guards. No iOS runtime, payment, or ABI execution here."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = (ROOT / 'pxclone/CXHook.m').read_text()
ROUTE = (ROOT / 'pxclone/CXSystemRouting.inc').read_text()

class RouteModel:
    def __init__(self):
        self.items = []
        self.selected = False
        self.done = False
        self.forwarded = []
        self.results = []
        self.waiting = False
    def enqueue(self, value):
        assert not self.done
        self.items.append(value)
    def choose(self):
        self.selected = True
        self.advance()
    def advance(self):
        if self.done or self.waiting:
            return
        if self.items:
            self.forwarded.append(self.items.pop(0))
            self.waiting = True
        else:
            self.done = True
    def complete(self, value):
        if not self.waiting or self.done:
            return
        self.results.append(value)
        self.waiting = False
        self.advance()
    def cancel(self):
        assert not self.selected
        self.results.extend(('cancel', value) for value in self.items)
        self.items.clear()
        self.done = True

class RoutingRegressions(unittest.TestCase):
    def test_two_calls_do_not_open_before_choice(self):
        r = RouteModel()
        r.enqueue('requestA'); r.enqueue('requestB')
        self.assertEqual(r.forwarded, [])
        r.choose()
        self.assertEqual(r.forwarded, ['requestA'])
        r.complete('okA')
        self.assertEqual(r.forwarded, ['requestA', 'requestB'])
        r.complete('okB')
        self.assertTrue(r.done)
    def test_cancel_does_not_forward_either_request(self):
        r = RouteModel(); r.enqueue('A'); r.enqueue('B'); r.cancel()
        self.assertEqual(r.forwarded, [])
        self.assertEqual(r.results, [('cancel', 'A'), ('cancel', 'B')])
    def test_true_callback_type_and_early_copy(self):
        self.assertIn('typedef void (^CXSystemCompletion)(NSError *error);', HOOK)
        self.assertIn('item.completion = [completion copy];', ROUTE)
        self.assertNotIn('CXClaimRequestRoute', HOOK)
        self.assertNotIn('CXInternalOpen || CXShowingChooser', ROUTE)
    def test_cancel_has_no_fallback_launch(self):
        self.assertNotIn('cancelled, forward unchanged', HOOK + ROUTE)
        self.assertIn('cancelled; reject %lu requests, no forward', ROUTE)
        self.assertIn('callback(error ?: CXRouteError', ROUTE)
    def test_dismantle_window_after_copying_button_callback(self):
        tap = HOOK.split('- (void)tapped:', 1)[1].split('@end', 1)[0]
        self.assertLess(tap.index('[self.pick copy]'), tap.index('CXCloseChooser()'))
        cancel = tap.split('- (void)cancelled', 1)[1]
        self.assertLess(cancel.index('[self.cancel copy]'), cancel.index('CXCloseChooser()'))
    def test_queued_payload_and_process_exit_guard(self):
        self.assertIn('item.request = request', ROUTE)
        self.assertIn('CXOrigSystemRequest(item.receiver, item.selector, item.service, item.request, result)', ROUTE)
        self.assertIn('errno == ESRCH', ROUTE)
        self.assertIn('Previous account process has not exited', ROUTE)
        self.assertNotIn('CXReplayURL(', ROUTE)

if __name__ == '__main__':
    unittest.main(verbosity=2)
