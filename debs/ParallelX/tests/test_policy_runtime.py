#!/usr/bin/env python3
"""Host model of PXCloneTransition and negative guards for PXCloneRuntime.

The model runs the same ordered rules as the ObjC transaction: one token, one
switch callback, bounded verification, exactly one terminal callback.
"""
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMON = os.path.join(ROOT, "Common")
TIMEOUT = 3.0
INTERVAL = 0.25


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


class Transition:
    def __init__(self, container="C1"):
        self.container = container
        self.finished = []
        self.state = "idle"
        self.switch_calls = 0
        self.token = Transition.next_token()
        self.attempt = 0

    _token = 0

    @classmethod
    def next_token(cls):
        cls._token += 1
        return cls._token

    def begin(self):
        if self.state != "idle":
            self.finish(False, "busy")
            return
        self.state = "switching"

    def switch(self, ok):
        if self.finished:
            return
        self.switch_calls += 1
        if self.switch_calls > 1:
            return
        if not ok:
            self.finish(False, "switch")
            return
        self.state = "verifying"
        self.attempt = 0

    def verify(self, active):
        if self.finished or self.state != "verifying":
            return
        if active == self.container:
            self.state = "ready"
            self.finish(True, None)
            return
        self.attempt += 1
        if self.attempt * INTERVAL >= TIMEOUT:
            self.state = "failed"
            self.finish(False, "timeout")

    def cancel(self):
        if self.finished:
            return
        self.state = "cancelled"
        self.finish(False, "cancel")

    def finish(self, ok, reason):
        if self.finished:
            return
        self.finished.append((ok, reason))


class PolicyTests(unittest.TestCase):
    def test_success_and_verified_finishes_once(self):
        t = Transition()
        t.begin()
        t.switch(True)
        t.verify("C1")
        t.verify("C1")
        self.assertEqual(t.finished, [(True, None)])

    def test_switch_failure_never_verifies(self):
        t = Transition()
        t.begin()
        t.switch(False)
        t.verify("C1")
        self.assertEqual(t.finished, [(False, "switch")])

    def test_duplicate_switch_callback_ignored(self):
        t = Transition()
        t.begin()
        t.switch(True)
        t.switch(False)
        self.assertEqual(t.switch_calls, 2)
        t.verify("C1")
        self.assertEqual(t.finished, [(True, None)])

    def test_wrong_container_times_out(self):
        t = Transition()
        t.begin()
        t.switch(True)
        for _ in range(12):
            t.verify("C2")
        self.assertEqual(t.finished, [(False, "timeout")])

    def test_retry_then_success(self):
        t = Transition()
        t.begin()
        t.switch(True)
        t.verify("C2")
        t.verify("C1")
        self.assertEqual(t.finished, [(True, None)])

    def test_cancel_finishes_once(self):
        t = Transition()
        t.begin()
        t.cancel()
        t.cancel()
        t.switch(True)
        self.assertEqual(t.finished, [(False, "cancel")])

    def test_new_transaction_has_new_token(self):
        a, b = Transition(), Transition()
        self.assertGreater(b.token, a.token)

    def test_old_scene_still_draining_must_fail_at_deadline(self):
        t = Transition()
        t.begin()
        t.switch(True)
        for _ in range(12):
            t.verify("settling")
        self.assertEqual(t.finished, [(False, "timeout")])

    def test_second_begin_finishes_busy(self):
        t = Transition()
        t.begin()
        t.begin()
        self.assertEqual(t.finished, [(False, "busy")])

    def test_timeout_is_bounded(self):
        self.assertLessEqual(TIMEOUT, 3.0)
        self.assertGreater(INTERVAL, 0)


class PolicySourceGuards(unittest.TestCase):
    def test_completion_copied_and_main(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("_completion = [completion copy]", source)
        self.assertIn("dispatch_get_main_queue()", source)

    def test_token_and_single_finish_guard(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("_finished", source)
        self.assertIn("PXNextToken", source)

    def test_switch_success_requires_verify(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("isEqualToString:self.containerID", source)
        self.assertIn("PXClonePolicyVerifyTimeout", source)

    def test_switch_stage_has_watchdog(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("container switch timed out", source)


class RuntimeSourceGuards(unittest.TestCase):
    def test_return_type_and_argument_count_checked(self):
        source = read("Common/PXCloneRuntime.m")
        self.assertIn("numberOfArguments", source)
        self.assertIn("methodReturnType", source)

    def test_block_signature_rejected_for_object(self):
        source = read("Common/PXCloneRuntime.m")
        self.assertIn("actual[1] == '?'", source)

    def test_calls_wrapped_in_exception_guard(self):
        source = read("Common/PXCloneRuntime.m")
        self.assertGreaterEqual(source.count("@try"), 6)
        self.assertGreaterEqual(source.count("@catch"), 6)

    def test_hook_fails_closed_without_substrate(self):
        source = read("Common/PXCloneRuntime.m")
        self.assertIn('dlsym(RTLD_DEFAULT, "MSHookFunction")', source)
        self.assertIn("if (!hook) return NO", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
