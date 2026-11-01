#!/usr/bin/env python3
"""Local-only guards for the chat panel. Never runs Theos, Xcode or a device.

Compiles and runs the portable ChatCore test, then statically checks the
production sources for the promises the panel makes: no key logging, 30 s / 512
token budget, main-thread API, a key-capable separate window, and the Makefile
wiring. Exits non-zero on the first broken promise.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
AI_H = (ROOT / "MiniSightAI.h").read_text()
AI_M = (ROOT / "MiniSightAI.m").read_text()
PANEL_H = (ROOT / "MiniSightChatPanel.h").read_text()
PANEL_M = (ROOT / "MiniSightChatPanel.m").read_text()
CORE_H = (ROOT / "tools/chat/ChatCore.h").read_text()
CORE_C = (ROOT / "tools/chat/ChatCore.c").read_text()
TEST_C = (ROOT / "tests/chat/chat_test.c").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()
README = (ROOT / "README.md").read_text()

results = []


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    results.append(name)


def code_only(text):
    return re.sub(
        r"/\*.*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'",
        " ",
        text,
        flags=re.S,
    )


def balanced(text):
    stack = []
    closes = {")": "(", "]": "[", "}": "{"}
    for char in code_only(text):
        if char in "([{":
            stack.append(char)
        elif char in closes:
            if not stack or stack.pop() != closes[char]:
                return False
    return not stack


# ---- portable build & test -------------------------------------------------

with tempfile.TemporaryDirectory() as tmp:
    binary = pathlib.Path(tmp) / "chat_test"
    build = subprocess.run(
        ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
         "-o", str(binary), str(ROOT / "tests/chat/chat_test.c"),
         str(ROOT / "tools/chat/ChatCore.c")],
        capture_output=True, text=True,
    )
    check("c_build_clean", build.returncode == 0)
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    check("c_test_pass", run.returncode == 0 and "checks passed" in run.stdout)
    checks_run = re.search(r"(\d+) checks passed", run.stdout)
    check("c_test_has_coverage", bool(checks_run) and int(checks_run.group(1)) >= 100)

# ---- structure -------------------------------------------------------------

for label, text in (("ai", AI_H), ("panel", PANEL_H)):
    check("guard_" + label, bool(re.search(r"#ifndef MINISIGHT_[A-Z_]+_H", text)))

for label, text in (("ai_h", AI_H), ("ai_m", AI_M), ("panel_h", PANEL_H), ("panel_m", PANEL_M)):
    check("balanced_" + label, balanced(text))
    check("sections_" + label,
          len(re.findall(r"@(interface|implementation|protocol)\b", text)) ==
          len(re.findall(r"@end\b", text)))

check("prefix_uniform", "MiniSightChatPanel" in PANEL_H and "MiniSightAI" in AI_H)
check("no_private_classes", all(
    token not in AI_M + PANEL_M
    for token in ("SpringBoard", "%hook", "objc_msgSend", "NSClassFromString", "performSelector")))
check("shared_core_include", '#import "tools/chat/ChatCore.h"' in AI_H)

# ---- Makefile / docs -------------------------------------------------------

check("makefile_lists_ai", "MiniSightAI.m" in MAKEFILE)
check("makefile_lists_panel", "MiniSightChatPanel.m" in MAKEFILE)
check("makefile_lists_core", "tools/chat/ChatCore.c" in MAKEFILE)
check("makefile_arc", "-fobjc-arc" in MAKEFILE)
check("readme_section", "AI 多轮聊天面板" in README and "MiniSightChatPanel" in README)

# ---- AI behaviour ----------------------------------------------------------

check("reads_same_config", 'MSBridgeRead(container, @"ai.json"' in AI_M)
check("config_fields", all(f'config[@"{field}"]' in AI_M for field in ("url", "key", "model")))
check("bearer_auth", '"Bearer "' in AI_M and 'forHTTPHeaderField:@"Authorization"' in AI_M)
check("timeout_30", "kMiniSightAITimeout = 30.0" in AI_M and
      "request.timeoutInterval = kMiniSightAITimeout" in AI_M)
check("max_tokens_512", "kMiniSightAIMaxTokens = 512" in AI_M and
      '@"max_tokens": @(kMiniSightAIMaxTokens)' in AI_M)
check("core_endpoint_builder", "MSChatBuildEndpoint(" in AI_M)
check("core_extractor", "MSChatExtractReplyText(" in AI_M)
check("core_context", "MSChatContextAdd(&_history" in AI_M and
      "MSCHAT_MAX_MESSAGES" in CORE_H and "MSCHAT_MAX_CHARS" in CORE_H)
check("no_streaming", "stream" not in AI_M.lower().replace("nsurlsession", ""))
check("duplicate_guard", "if (!MSChatBeginRequest(&_requestState)) return;" in AI_M)
check("cancel", "MSChatCancelRequest(" in AI_M)
check("empty_success_is_error", "MiniSightAIIssueEmpty" in AI_M and
      "extract != MSChatExtractOK || !text[0]" in AI_M)
check("response_size_bound", "kMiniSightAIMaxResponseBytes" in AI_M and
      "data.length > kMiniSightAIMaxResponseBytes" in AI_M)
check("every_issue_has_text", all(
    f"case MSChatIssue{name}:" in CORE_C
    for name in ("Config", "URL", "Timeout", "Network", "Empty", "Cancelled", "HTTP")))
check("timeout_error_mapping", "NSURLErrorTimedOut" in AI_M and "MiniSightAIIssueTimeout" in AI_M)
check("container_release_guard", "fileExistsAtPath:container" in AI_M and "isEqualToString:self.containerPath" in AI_M)
check("main_thread_ai", "[NSThread isMainThread]" in AI_M and "dispatch_get_main_queue()" in AI_M)
check("weak_callbacks", "__weak typeof(self) weakSelf" in AI_M and "weakSelf" in AI_M)
check("no_key_logging", "NSLog" not in AI_M and "NSLog" not in PANEL_M)

# ---- Panel behaviour -------------------------------------------------------

check("separate_key_window", "MiniSightChatWindow : UIWindow" in PANEL_M)
check("can_become_key", "- (BOOL)canBecomeKeyWindow { return YES; }" in PANEL_M)
check("key_lifecycle", "makeKeyAndVisible" in PANEL_M and "resignKeyWindow" in PANEL_M)
check("full_screen", "MSChatScreenRect(self.window.windowScene)" in PANEL_M and
      "root.leadingAnchor" in PANEL_M)
check("background_dismiss", "backgroundTapped" in PANEL_M and "UITapGestureRecognizer" in PANEL_M)
check("rounded_bottom_panel", "layer.cornerRadius = kMSChatCorner" in PANEL_M and
      "kCALayerMinXMinYCorner" in PANEL_M)
check("keyboard_avoidance", "UIKeyboardWillChangeFrameNotification" in PANEL_M and
      "updateCardBottomAnimated" in PANEL_M)
check("rotation_and_safe_area", "UIDeviceOrientationDidChangeNotification" in PANEL_M and
      "safeAreaInsets" in PANEL_M and "UIInterfaceOrientationIsLandscape" in PANEL_M)
check("dynamic_colors", "colorWithDynamicProvider" in PANEL_M and
      "UIUserInterfaceStyleUnspecified" in PANEL_M)
check("controls", all(x in PANEL_M for x in ('@"发送"', '@"取消"', '@"清空"', '@"✕"')))
check("max_30_messages", "kMSChatMaxMessages = 30.0" in PANEL_M and
      "self.rows.count > (NSUInteger)kMSChatMaxMessages" in PANEL_M)
check("disable_while_sending", "self.sendButton.enabled = NO" in PANEL_M and
      "if (self.sending) return;" in PANEL_M)
check("close_hides", "self.window.hidden = YES" in PANEL_M and "if (!self.visible) return;" in PANEL_M)
check("host_callbacks", all(x in PANEL_H for x in ("replyHandler", "errorHandler", "visibilityHandler")))
check("main_thread_panel", "[NSThread isMainThread]" in PANEL_M)
check("no_host_bubble_dependency", "Tweak.xm" not in PANEL_M)

# ---- portable test coverage ------------------------------------------------

for token in ("MSChatBuildEndpoint", "MSCHAT_MAX_CHARS", "MSChatExtractReplyText",
              "MSChatCancelRequest", "401", "429", "500", "userinfo", "user:pass"):
    check("test_covers_" + token.lower(), token in TEST_C or token.lower() in TEST_C.lower())

print("chat local checks: %d passed" % len(results))
for name in results:
    print("PASS " + name)
