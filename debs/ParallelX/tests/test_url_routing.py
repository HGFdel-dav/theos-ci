#!/usr/bin/env python3
"""Static checks for the external-URL account chooser (SpringBoard handoff).

The router must only own requests for bundles that really have several Crane
containers, must let the original request run exactly once, and must change the
active container through Crane's own request API rather than a bare setter.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TWEAK = (ROOT / 'Tweak.xm').read_text()
ROUTER = (ROOT / 'Common/PXCloneURLRouter.m').read_text()
ROUTER_H = (ROOT / 'Common/PXCloneURLRouter.h').read_text()
MAKEFILE = (ROOT / 'Makefile').read_text()


class TestURLRouting(unittest.TestCase):
    def test_hook_target_and_forwarding(self):
        self.assertIn('systemService:handleOpenApplicationRequest:withCompletion:', TWEAK)
        self.assertIn('NSClassFromString(@"FBSystemService")', TWEAK)
        # The original implementation runs when the router declines, and the
        # router's own proceed block is the only other caller.
        body = TWEAK.split('static void PXHandleOpenRequest', 1)[1].split('static BOOL PXInstallURLRoutingHook', 1)[0]
        self.assertEqual(body.count('PXOrigHandleOpenRequest(self'), 1)
        self.assertIn('if ([PXCloneURLRouter handleOpenRequest:request proceed:proceed]) return;', body)
        self.assertIn('proceed();', body)

    def test_hook_is_part_of_the_bounded_bootstrap(self):
        self.assertIn('BOOL routingReady = PXInstallURLRoutingHook();', TWEAK)
        self.assertIn('launchReady && routingReady', TWEAK)

    def test_only_multi_container_bundles_are_intercepted(self):
        self.assertIn('if (containers.count < 2) {', ROUTER)
        guard = ROUTER.split('if (containers.count < 2) {', 1)[1].split('return NO;', 1)
        self.assertEqual(len(guard), 2)
        # No chooser may be presented for a single-container bundle.
        self.assertLess(ROUTER.index('containers.count < 2'), ROUTER.index('presentChooserForBundle'))

    def test_unknown_bundle_never_throws(self):
        # All request fields are read through respondsToSelector + @try.
        self.assertIn('respondsToSelector:selector', ROUTER)
        self.assertIn('@catch (__unused NSException *exception)', ROUTER)
        for key in ('applicationIdentifier', 'bundleIdentifier', 'targetApplicationIdentifier'):
            self.assertIn(key, ROUTER)

    def test_original_request_runs_exactly_once(self):
        self.assertIn('PXURLRouterOnce', ROUTER)
        self.assertIn('if (done) return;', ROUTER)
        self.assertIn('done = YES;', ROUTER)
        # The cancel action deliberately does not forward the request.
        cancel = ROUTER.split('style:UIAlertActionStyleCancel', 1)[1]
        self.assertNotIn('proceed()', cancel.split('}]];', 1)[0])

    def test_account_change_uses_crane_request_api(self):
        self.assertIn('[PXCloneCrane requestSwitchToContainer:', ROUTER)
        self.assertIn('waitForContainer:', ROUTER)
        self.assertIn('PXURLRouterPollLimit', ROUTER)
        # A bare container setter would bypass Crane's authentication path.
        self.assertNotIn('setActiveContainerIdentifier', ROUTER)
        self.assertNotIn('setActiveContainer', ROUTER)

    def test_switch_failure_still_proceeds(self):
        # A pending payment URL must not be swallowed when the switch fails.
        activate = ROUTER.split('+ (void)activateContainer:', 1)[1]
        self.assertGreaterEqual(activate.count('proceed();'), 3)
        wait = ROUTER.split('+ (void)waitForContainer:', 1)[1]
        self.assertIn('attempt >= PXURLRouterPollLimit', wait)
        self.assertIn('proceed();', wait)

    def test_chooser_uses_its_own_alert_window(self):
        self.assertIn('UIWindowLevelAlert + 1', ROUTER)
        self.assertIn('UIAlertControllerStyleActionSheet', ROUTER)
        self.assertIn('makeKeyAndVisible', ROUTER)
        self.assertIn('style:UIAlertActionStyleCancel', ROUTER)

    def test_header_contract(self):
        self.assertIn('+ (BOOL)handleOpenRequest:(nullable id)request', ROUTER_H)
        self.assertIn('exactly once', ROUTER_H)

    def test_router_is_built_into_the_tweak(self):
        self.assertIn('Common/PXCloneURLRouter.m', MAKEFILE)
        # The settings bundle compiles a narrower file list and never routes.
        prefs_section = MAKEFILE.split('ParallelXPrefsUI_FILES', 1)[1]
        self.assertNotIn('PXCloneURLRouter.m', prefs_section.split('include', 1)[0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
