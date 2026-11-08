#!/usr/bin/env python3
"""Source-level URL-hook checks only; no iOS behavior or private ABI proof.

Run with PYTHONDONTWRITEBYTECODE=1. The production router state machine is
validated separately; these checks locate the exact hook and installer bodies.
"""
import re
import unittest
from pathlib import Path

TWEAK = (Path(__file__).resolve().parents[1] / "Tweak.xm").read_text()


def body(name):
    match = re.search(r"^static (?:void|BOOL) " + re.escape(name) + r"\([^;]*?\) \{", TWEAK, re.M)
    if not match:
        raise AssertionError("Missing function: " + name)
    start = match.end()
    depth = 1
    for index in range(start, len(TWEAK)):
        if TWEAK[index] == "{":
            depth += 1
        elif TWEAK[index] == "}":
            depth -= 1
            if depth == 0:
                return TWEAK[start:index]
    raise AssertionError("Unclosed function: " + name)


class URLHookSourceSafety(unittest.TestCase):
    def test_every_entry_filters_before_async_ownership(self):
        entries = {
            "PXHandleOpenRequest": "hasTargetURL:request options:nil",
            "PXHandleWorkspaceRequest": "handleOpenRequest:request options:options",
            "PXHandleOpenURLCore": "scheme.length",
            "PXProbeOpenURL": "isPaymentURL:url",
            "PXProbeOpenURLOptions": "isPaymentURL:url",
        }
        for name, predicate in entries.items():
            with self.subTest(entry=name):
                source = body(name)
                gate = source.index("if (!NSThread.isMainThread || PXURLForwardDepth")
                payment = source.index(predicate)
                forward = source.index("PX_FORWARD_URL(")
                proceed = source.index("void (^proceed)(void)")
                self.assertLess(gate, payment)
                self.assertLess(forward, proceed)
                if "handleOpenRequest:" in predicate:
                    # The delegate needs the proceed block, so it is built first.
                    self.assertLess(proceed, payment)
                else:
                    self.assertLess(payment, forward)
                self.assertNotIn("dispatch_async", source)
                self.assertNotIn("PXCloneCrane", source)
                if " copy]" in source:
                    self.assertLess(forward, source.index(" copy]"))
                    self.assertLess(source.index(" copy]"), proceed)

    def test_private_callbacks_are_copied_and_only_forwarded(self):
        cases = (
            ("PXHandleOpenRequest", "completion", "ownedCompletion", "PXOrigHandleOpenRequest"),
            ("PXHandleWorkspaceRequest", "result", "ownedResult", "PXOrigWorkspaceRequest"),
            ("PXHandleOpenURLCore", "result", "ownedResult", "PXOrigOpenURLCore"),
        )
        for name, argument, owned, original in cases:
            with self.subTest(entry=name):
                source = body(name)
                self.assertIn(f"id {owned} = [{argument} copy];", source)
                delayed = source.split("void (^proceed)(void)", 1)[1].split("};", 1)[0]
                self.assertIn(original + "(self, command,", delayed)
                self.assertIn(", " + owned + "));", delayed)
                self.assertNotRegex(delayed, r"\b" + argument + r"\b")
                self.assertNotRegex(source, r"\b(?:result|completion|ownedResult|ownedCompletion)\s*\(")

    def test_uikit_completion_uses_public_signature_and_copy(self):
        self.assertIn("typedef void (^PXOpenURLCompletion)(BOOL success);", TWEAK)
        self.assertIn("typedef void (*PXOpenURLOptionsIMP)(id, SEL, NSURL *, NSDictionary *, PXOpenURLCompletion);", TWEAK)
        source = body("PXProbeOpenURLOptions")
        self.assertIn("PXOpenURLCompletion ownedCompletion = [completion copy];", source)
        self.assertIn("PXOrigOpenURLOptions(self, command, url, options, ownedCompletion)", source)
        self.assertNotRegex(source, r"\b(?:completion|ownedCompletion)\s*\(")

    def test_sb_request_has_only_confirmed_block_encoding(self):
        source = body("PXInstallURLRoutingHook")
        sb = source.split("if (!PXWorkspaceRequestInstalled)", 1)[1].split("if (!PXOpenURLCoreInstalled)", 1)[0]
        self.assertIn('_handleOpenApplicationRequest:options:activationSettings:origin:withResult:', sb)
        self.assertIn('PXClassDeclaringSelector(selector, @encode(void), @[@"@", @"@", @"@", @"@", @"@?"])', sb)
        self.assertNotIn("shapes", sb)
        self.assertNotIn('@[@"@", @"@", @"@", @"@", @"@"]', sb)

    def test_core_and_optional_fb_have_full_abi_gates(self):
        source = body("PXInstallURLRoutingHook")
        core = source.split("if (!PXOpenURLCoreInstalled)", 1)[1].split("if (!PXServiceRequestInstalled)", 1)[0]
        self.assertIn('_openURLCore:display:animating:activationSettings:origin:withResult:', core)
        self.assertIn('NSString *boolType = [NSString stringWithUTF8String:@encode(BOOL)];', core)
        self.assertIn('PXClassDeclaringSelector(selector, @encode(void),', core)
        self.assertIn('@[@"@", boolType, boolType, @"@", @"@", @"@?"]', core)
        fb = source.split("if (!PXServiceRequestInstalled)", 1)[1]
        gate = 'PXCloneClassInstanceMethodMatches(service, selector, @encode(void), @[@"@", @"@", @"@?"])'
        self.assertIn(gate, fb)
        self.assertLess(fb.index(gate), fb.index("PXCloneHookMessage"))
        self.assertIn("return PXWorkspaceRequestInstalled || PXOpenURLCoreInstalled;", source)

    def test_each_successful_install_has_an_independent_guard(self):
        groups = (
            ("PXInstallURLRoutingHook", "PXWorkspaceRequest", "PXOrigWorkspaceRequest"),
            ("PXInstallURLRoutingHook", "PXOpenURLCore", "PXOrigOpenURLCore"),
            ("PXInstallURLRoutingHook", "PXServiceRequest", "PXOrigHandleOpenRequest"),
            ("PXInstallProbeHooks", "PXOpenURL", "PXOrigOpenURL"),
            ("PXInstallProbeHooks", "PXOpenURLOptions", "PXOrigOpenURLOptions"),
            ("PXInstallProbeHooks", "PXWorkspaceSensitiveOpen", "PXOrigWorkspaceSensitiveOpen"),
            ("PXInstallProbeHooks", "PXWorkspacePublicOpen", "PXOrigWorkspacePublicOpen"),
        )
        for installer, prefix, original in groups:
            with self.subTest(hook=prefix):
                source = body(installer)
                guard = "if (!" + prefix + "Installed"
                assignment = re.search(r"\b" + original + r" = \([^;]+\)original;", source)
                self.assertIsNotNone(assignment)
                self.assertLess(source.index(guard), assignment.start())
                self.assertLess(assignment.end(), source.index(prefix + "Installed = YES;"))
                self.assertEqual(len(re.findall(r"\b" + original + r" =", source)), 1)
        self.assertNotIn("for (NSString *name", body("PXInstallProbeHooks"))

    def test_ls_selectors_have_their_own_originals(self):
        self.assertIn("return PXRouteWorkspaceOpen(self, command, url, options, PXOrigWorkspaceSensitiveOpen);", body("PXProbeWorkspaceSensitiveOpen"))
        self.assertIn("return PXRouteWorkspaceOpen(self, command, url, options, PXOrigWorkspacePublicOpen);", body("PXProbeWorkspacePublicOpen"))
        self.assertNotRegex(TWEAK, r"\bPXOrigWorkspaceOpen\b")
        source = body("PXInstallProbeHooks")
        self.assertIn('NSSelectorFromString(@"openSensitiveURL:withOptions:")', source)
        self.assertIn('NSSelectorFromString(@"openURL:withOptions:")', source)
        for selector, wrapper in (("sensitive", "PXProbeWorkspaceSensitiveOpen"), ("publicOpen", "PXProbeWorkspacePublicOpen")):
            self.assertIn(f'PXCloneClassInstanceMethodMatches(workspace, {selector}, @encode(BOOL), @[@"@", @"@"])', source)
            self.assertIn(f"PXCloneHookMessage(workspace, {selector}, (IMP){wrapper}, &original)", source)

    def test_bool_paths_return_original_result(self):
        for name, original in (("PXProbeOpenURL", "PXOrigOpenURL"), ("PXRouteWorkspaceOpen", "original")):
            source = body(name)
            self.assertIn(f"PX_FORWARD_URL(return {original}(self, command, url", source)
            self.assertIn("return forwarded ? originalResult : YES;", source)
            self.assertTrue(source.rstrip().endswith("return originalResult;"))

    def test_reentry_depth_is_exception_safe_and_not_a_timestamp(self):
        macro = TWEAK.split("#define PX_FORWARD_URL(expression)", 1)[1].split("typedef", 1)[0]
        self.assertIn("BOOL pxMainForward = NSThread.isMainThread;", macro)
        self.assertIn("if (pxMainForward) ++PXURLForwardDepth;", macro)
        self.assertIn("@try { expression; }", macro)
        self.assertIn("@finally { if (pxMainForward) --PXURLForwardDepth; }", macro)
        routing = TWEAK.split("static NSUInteger PXURLForwardDepth;", 1)[1].split("#undef PX_FORWARD_URL", 1)[0]
        for stale in ("PXInAppReentry", "recentAppHandoff", "noteAppHandoff", "timeIntervalSince", "systemUptime"):
            self.assertNotIn(stale, routing)

    def test_hook_probe_reports_every_entry_without_payload(self):
        routing = TWEAK.split("static NSUInteger PXURLForwardDepth;", 1)[1].split("#undef PX_FORWARD_URL", 1)[0]
        logs = re.findall(r'\[PXCloneProbe log:@"([^"\n]*)"\];', routing)
        self.assertGreaterEqual(len(logs), 6)
        # Every entry must be observable: silence is what hid the wrong door.
        for marker in ("FBREQ hit", "SBREQ hit", "SBURL hit", "SBREQ payment=1", "FBREQ payment=1"):
            self.assertIn(marker, routing)
        # Only a class name or the URL itself; never the whole request object.
        self.assertIn("NSStringFromClass([request class])", routing)
        self.assertNotIn("[request description]", routing)

    def test_bootstrap_remains_springboard_only(self):
        source = body("PXBootstrap")
        self.assertIn('BOOL springboard = [bundleID isEqualToString:@"com.apple.springboard"];', source)
        self.assertIn("if (!springboard) return;", source)
        self.assertLess(source.index("if (!springboard) return;"), source.index("PXInstallProbeHooks();"))
        self.assertIn("BOOL launchReady = [PXCloneLaunchController installNativeHooks];", source)
        self.assertIn("BOOL routingReady = PXInstallURLRoutingHook();", source)
        self.assertNotIn("APP-BOOT", source)


if __name__ == "__main__":
    unittest.main()
