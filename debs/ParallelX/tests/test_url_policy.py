from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROUTER = (ROOT / 'Common/PXCloneURLRouter.m').read_text()
POLICY = (ROOT / 'Common/PXCloneURLPolicy.h').read_text()
CRANE = (ROOT / 'Common/PXCloneCrane.m').read_text()

def implementation(text, marker):
    # The class extension also declares these selectors; test the definition.
    start = text.rfind(marker)
    if start < 0:
        raise AssertionError('method missing: ' + marker)
    brace = text.find('{', start)
    depth = 1
    for i in range(brace + 1, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0: return text[start:i + 1]
    raise AssertionError('method body missing: ' + marker)

class URLPolicyTests(unittest.TestCase):
    def test_production_c_policy_and_transaction_gate(self):
        compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td) / 'url-policy'
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                str(ROOT / 'tests/url_policy_harness.c'), '-o', str(binary)],
                check=True, capture_output=True, text=True)
            output = subprocess.check_output([str(binary)], text=True)
        count = int(re.search(r'payment_route_policy_checks=(\d+)', output)[1])
        self.assertGreater(count, 150000)

    def test_nonpayment_and_notification_bail_out_before_crane(self):
        for selector, predicate in (
                ('+ (BOOL)handleOpenURL:', 'scheme.length'),
                ('+ (BOOL)handleOpenRequest:', 'paymentURLForRequest:request options:options')):
            body = implementation(ROUTER, selector)
            self.assertLess(body.index(predicate), body.index('containersForBundle:'))
        classified = implementation(ROUTER, '+ (NSURL *)paymentURLForRequest:')
        self.assertIn('[self isPaymentURL:url]', classified)
        self.assertNotIn('PXURLRouterCatalogWait', ROUTER)
        self.assertNotIn('PXURLRouterPending', ROUTER)
        self.assertNotIn('WATCHDOG', ROUTER)
        self.assertNotIn('PXURLRouterLastAppHandoff', ROUTER)

    def test_request_url_fields_are_explicit_and_not_source_return_fields(self):
        helper = ROUTER.split('static NSURL *PXURLRouterTargetURL', 1)[1].split('static UIViewController *PXURLRouterPresenter', 1)[0]
        for key in ('@"url"', '@"targetURL"', '@"openURL"', '@"UIApplicationLaunchOptionsURLKey"'):
            self.assertIn(key, helper)
        self.assertNotIn('@"sourceURL"', helper)
        self.assertNotIn('@"returnURL"', helper)

    def test_old_process_exits_before_account_switch_and_forward(self):
        stop = implementation(ROUTER, '+ (void)stopOldProcess:')
        switch = implementation(ROUTER, '+ (void)switchTransaction:')
        verify = implementation(ROUTER, '+ (void)verifyTransaction:')
        self.assertIn('queryApplicationRunning:', stop)
        self.assertIn('terminateApplication:', stop)
        self.assertIn('if (!transaction.requiresExit || !running)', stop)
        self.assertIn('requestSwitchToContainer:', switch)
        self.assertNotIn('reloadApplicationWithIdentifier:', switch)
        self.assertIn('activeContainerForBundle:', verify)
        self.assertIn('PXURLRouteMayForward', verify)
        self.assertIn('BOOL exited = !transaction.requiresExit || !running;', verify)
        self.assertIn('if (!processKnown || !exited)', verify)
        self.assertIn('transaction.selected, matches, processKnown, exited', verify)

    def test_unknown_process_state_never_means_exited(self):
        query = implementation(CRANE, '+ (BOOL)queryApplicationRunning:')
        self.assertIn('if (!manager)', query)
        self.assertIn('if (!processes ||', query)
        self.assertIn('processesForBundleIdentifier:', query)
        self.assertIn('((id (*)(id, SEL, id))objc_msgSend)(manager, list, bundleID)', query)
        exception = query.split('@catch', 1)[1]
        self.assertIn('return NO;', exception)
        self.assertNotIn('PXCloneSendId1(manager, list', query)

    def test_cancel_and_failure_clear_original_opener(self):
        finish = implementation(ROUTER, '+ (void)endTransaction:')
        self.assertIn('transaction.proceed = nil;', finish)
        self.assertIn('PXURLRouteAbort', finish)
        self.assertNotRegex(finish, r'\bproceed\s*\(')
        self.assertIn('if (alert.presentingViewController)', finish)

    def test_alert_never_creates_a_scene_less_window(self):
        presenter = ROUTER.split('static UIViewController *PXURLRouterPresenter', 1)[1].split('@implementation', 1)[0]
        self.assertNotIn('makeKeyAndVisible', ROUTER)
        self.assertIn('initWithWindowScene:scene', ROUTER)
        self.assertIn('return nil; // Never create a scene-less key window', presenter)
        self.assertIn('UIApplication.sharedApplication', presenter)

if __name__ == '__main__':
    unittest.main(verbosity=2)
