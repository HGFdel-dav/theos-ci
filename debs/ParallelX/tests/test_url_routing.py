#!/usr/bin/env python3
"""Source contracts for payment-only clone routing; not an iOS runtime test."""
import re
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TWEAK = (ROOT / 'Tweak.xm').read_text()
ROUTER = (ROOT / 'Common/PXCloneURLRouter.m').read_text()
ROUTER_H = (ROOT / 'Common/PXCloneURLRouter.h').read_text()
MAKEFILE = (ROOT / 'Makefile').read_text()

def method(text, marker):
    start = text.rfind(marker)
    if start < 0: raise AssertionError('method missing: ' + marker)
    brace = text.find('{', start)
    if brace < 0: raise AssertionError('body missing: ' + marker)
    depth = 1
    for i in range(brace + 1, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if not depth: return text[start:i + 1]
    raise AssertionError('unclosed: ' + marker)

class TestPaymentRouter(unittest.TestCase):
    def test_bundle_entry_requires_actual_payment_url_before_crane(self):
        body = method(ROUTER, '+ (BOOL)handleOpenRequest:')
        self.assertIn('paymentURLForRequest:request options:options', body)
        self.assertLess(body.index('paymentURLForRequest:'), body.index('containersForBundle:'))
        self.assertIn('if (!url) return NO;', body)
        self.assertNotIn('loadCatalogForRequest:', ROUTER)

    def test_url_entry_classifies_before_resolving_target(self):
        body = method(ROUTER, '+ (BOOL)handleOpenURL:')
        self.assertIn('[self isPaymentURL:url]', body)
        self.assertLess(body.index('isPaymentURL:url'), body.index('PXURLRouterBundleForURL(url)'))
        self.assertLess(body.index('PXURLRouterBundleForURL(url)'), body.index('containersForBundle:'))

    def test_only_payment_requests_start_transaction(self):
        body = method(ROUTER, '+ (BOOL)beginBundle:')
        self.assertIn('containers.count < 2', body)
        self.assertIn('PXURLRouterActive', body)
        self.assertIn('PXURLRouterNextToken', body)
        self.assertNotIn('PXURLRouterPending', ROUTER)
        self.assertNotIn('PXURLRouterLastAppHandoff', ROUTER)
        self.assertNotIn('WATCHDOG', ROUTER)
        self.assertNotIn('CatalogWait', ROUTER)

    def test_cancel_failure_and_forward_are_request_scoped(self):
        body = method(ROUTER, '+ (void)endTransaction:')
        self.assertIn('transaction.proceed = nil;', body)
        self.assertIn('PXURLRouteAbort', body)
        self.assertNotRegex(body, r'\bproceed\s*\(')
        verify = method(ROUTER, '+ (void)verifyTransaction:')
        self.assertIn('activeContainerForBundle:', verify)
        self.assertIn('PXURLRouteMayForward', verify)
        self.assertIn('forward()', verify)
        self.assertLess(verify.index('PXURLRouteMayForward'), verify.index('forward()'))

    def test_account_switch_waits_for_old_process_and_crane_readback(self):
        stop = method(ROUTER, '+ (void)stopOldProcess:')
        switch = method(ROUTER, '+ (void)switchTransaction:')
        self.assertIn('queryApplicationRunning:', stop)
        self.assertIn('terminateApplication:', stop)
        self.assertIn('requestSwitchToContainer:', switch)
        self.assertNotIn('reloadApplicationWithIdentifier:', switch)
        self.assertIn('rawAuthenticationFlag', switch)

    def test_window_fallback_never_steals_parallelx_handle(self):
        self.assertNotIn('makeKeyAndVisible', ROUTER)
        self.assertNotIn('[[UIWindow alloc]', ROUTER)
        self.assertIn('Never create a scene-less key window', ROUTER)
        self.assertIn('UIAlertControllerStyleActionSheet', ROUTER)
        self.assertIn('style:UIAlertActionStyleCancel', ROUTER)

    def test_runtime_is_springboard_only_and_settings_dylib_does_not_route(self):
        plist = (ROOT / 'ParallelXClone.plist').read_text()
        self.assertIn('<string>com.apple.springboard</string>', plist)
        self.assertNotIn('APP-BOOT', TWEAK)
        self.assertIn('PXCloneURLRouter.m', MAKEFILE)
        prefs = MAKEFILE.split('ParallelXPrefsUI_FILES', 1)[1].split('include', 1)[0]
        self.assertNotIn('PXCloneURLRouter.m', prefs)

if __name__ == '__main__': unittest.main(verbosity=2)