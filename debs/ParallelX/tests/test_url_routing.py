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
        self.assertIn('if (containers.count >= 2) {', ROUTER)
        self.assertIn('if (containers.count < 2) return NO;', ROUTER)
        handler = ROUTER.split('+ (BOOL)handleOpenRequest', 1)[1]
        # No chooser may be presented for a single-container bundle.
        self.assertLess(handler.index('containers.count >= 2'), handler.index('presentChooserForBundle'))

    def test_cold_catalog_is_awaited_instead_of_forwarded(self):
        # A request can beat the first async catalog load. Forwarding there was
        # why payment links still opened the CURRENT account.
        self.assertIn('PXURLRouterCatalogReady', ROUTER)
        self.assertIn('PXURLRouterCatalogWaitLimit', ROUTER)
        self.assertIn('[self loadCatalogForRequest:request proceed:once bundle:bundle attempt:0]', ROUTER)
        handler = ROUTER.split('+ (BOOL)handleOpenRequest', 1)[1].split('+ (void)loadCatalogForRequest', 1)[0]
        # Only "no block" and "no bundle at all" may decline; the
        # cold-catalog path must keep ownership and return YES.
        self.assertEqual(handler.count('return NO;'), 3)
        self.assertEqual(handler.count('return YES;'), 2)

    def test_any_app_can_route_before_springboard(self):
        # The payment page lives in the SOURCE app (Unicom/Mobile/Taobao...).
        # SpringBoard never sees those opens, so every app hooks openURL.
        self.assertIn('+ (BOOL)handleOpenURL:(nullable NSURL *)url', ROUTER_H)
        self.assertIn('applicationsForOpeningURL:', ROUTER)
        self.assertIn('applicationForURL:', ROUTER)
        self.assertIn('NSBundle.mainBundle.bundleIdentifier', ROUTER)
        self.assertIn('recentAppHandoff', ROUTER)
        # Web URLs keep their normal handling.
        self.assertIn('PXURLRouterSchemeIsWeb', ROUTER)
        self.assertIn('APP-BOOT', TWEAK)
        # The filter must no longer be SpringBoard-only.
        plist = (ROOT / 'ParallelXClone.plist').read_text()
        self.assertNotIn('com.apple.springboard', plist)
        self.assertIn('PXInstallProbeHooks();', TWEAK)
        self.assertIn('PXInAppReentry', TWEAK)

    def test_request_target_falls_back_to_nested_selectors(self):
        self.assertIn('PXURLRouterBundleFromRequest', ROUTER)
        self.assertIn('PXURLRouterValue', ROUTER)
        for key in ('@"target"', '@"bundleID"', '@"bundleIdentifier"'):
            self.assertIn(key, ROUTER)
        # Still guarded against unknown objects.
        self.assertIn('@catch (NSException *exception) { (void)exception; return nil;', ROUTER)

    def test_unknown_bundle_never_throws(self):
        # All request fields are read through respondsToSelector + @try.
        self.assertIn('respondsToSelector:selector', ROUTER)
        self.assertIn('@catch (NSException *exception) { (void)exception;', ROUTER)
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

    def test_unconfirmed_switch_fails_closed(self):
        # Opening the wrong account is worse than asking for a retry.
        activate = ROUTER.rsplit('+ (void)activateContainer:', 1)[1].split('+ (void)waitForContainer:', 1)[0]
        self.assertIn('无法读取当前账号', activate)
        self.assertEqual(activate.count('proceed();'), 1)  # only the coincident case
        self.assertIn('showRoutingError', activate)
        wait = ROUTER.rsplit('+ (void)waitForContainer:', 1)[1].split('+ (void)showRoutingError:', 1)[0]
        self.assertIn('attempt >= PXURLRouterPollLimit', wait)
        self.assertIn('账号未切换完成', wait)
        timeout = wait.split('attempt >= PXURLRouterPollLimit', 1)[1]
        self.assertNotIn('proceed();', timeout.split('dispatch_after', 1)[0])

    def test_router_can_present_its_own_error(self):
        self.assertIn('+ (void)showRoutingError:', ROUTER)
        self.assertIn('stringByAppendingString:message', ROUTER)

    def test_chooser_uses_its_own_alert_window(self):
        self.assertIn('UIWindowLevelAlert + 1', ROUTER)
        self.assertIn('UIAlertControllerStyleActionSheet', ROUTER)
        self.assertIn('makeKeyAndVisible', ROUTER)
        self.assertIn('style:UIAlertActionStyleCancel', ROUTER)

    def test_header_contract(self):
        self.assertIn('+ (BOOL)handleOpenRequest:(nullable id)request', ROUTER_H)
        self.assertIn('at most once', ROUTER_H)

    def test_router_is_built_into_the_tweak(self):
        self.assertIn('Common/PXCloneURLRouter.m', MAKEFILE)
        # The settings bundle compiles a narrower file list and never routes.
        prefs_section = MAKEFILE.split('ParallelXPrefsUI_FILES', 1)[1]
        self.assertNotIn('PXCloneURLRouter.m', prefs_section.split('include', 1)[0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
