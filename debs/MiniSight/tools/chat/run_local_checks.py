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
check("timeouts_configured_before_session", "kMiniSightAIRequestTimeout = 45.0" in AI_M and
      "kMiniSightAIResourceTimeout = 60.0" in AI_M and
      "request.timeoutInterval = kMiniSightAIRequestTimeout" in AI_M and
      AI_M.index("configuration.timeoutIntervalForRequest =") < AI_M.index("self.session = [NSURLSession"))
check("hard_deadline_generation_guard", "kMiniSightAIHardDeadline = 65.0" in AI_M and
      "MSChatAcceptsReply(&strongSelf->_requestState, generation)" in AI_M and
      "dispatch_block_cancel(self.timeoutBlock)" in AI_M)
check("max_tokens_2048", "kMiniSightAIMaxTokens = 2048" in AI_M and
      '@"max_tokens": @(kMiniSightAIMaxTokens)' in AI_M)
check("core_endpoint_builder", "MSChatBuildEndpoint(" in AI_M)
check("core_extractor", "MSChatExtractReplyText(" in AI_M)
check("core_context", "MSChatContextAdd(&_history" in AI_M and
      "MSCHAT_MAX_MESSAGES" in CORE_H and "MSCHAT_MAX_CHARS" in CORE_H)
check("no_streaming", '@"stream"' not in AI_M and "uploadTaskWithStreamedRequest" not in AI_M)
check("bounded_receiving", "didReceiveData:(NSData *)data" in AI_M and
      "data.length > kMiniSightAIMaxResponseBytes - self.buffer.length" in AI_M and
      "self.completed = YES" in AI_M)
check("reject_redirects", "willPerformHTTPRedirection" in AI_M and "completionHandler(nil)" in AI_M)
duplicate_branch = AI_M.split('if (!MSChatBeginRequest(&_requestState)) {', 1)[-1].split('const unsigned long generation', 1)[0]
check("duplicate_guard", 'if (!MSChatBeginRequest(&_requestState)) {' in AI_M and 'return;' in duplicate_branch and 'sendUserText:' not in duplicate_branch)
check("cancel", "MSChatCancelRequest(" in AI_M)
check("empty_success_is_error", "MiniSightAIIssueEmpty" in AI_M and
      "extract != MSChatExtractOK || !reply.length" in AI_M and
      "回复额度用完但未生成正文" in AI_M)
check("request_diagnostics", all(stage in AI_M for stage in
      ("ai begin", "ai network", "ai callback", "ai parse", "ai finish")) and
      "reply.requestID" in AI_M and "chat display request=%@" in PANEL_M)
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
chat_window_impl = PANEL_M[PANEL_M.index("@implementation MiniSightChatWindow"):]
chat_window_impl = chat_window_impl[:chat_window_impl.index("@end")]
check("overlay_stays_nonkey", "- (BOOL)canBecomeKeyWindow { return NO; }" in chat_window_impl)
check("editor_can_be_key", "MiniSightChatEditorWindow : UIWindow" in PANEL_M and
      "- (BOOL)canBecomeKeyWindow { return YES; }" in PANEL_M)
check("key_lifecycle", "makeKeyWindow" in PANEL_M and "resignKeyWindow" in PANEL_M)
check("getter_direct_ivar", "- (BOOL)isVisible { return _visible; }" in PANEL_M and
      "- (BOOL)isSending { return _sending; }" in PANEL_M and
      "- (BOOL)isVisible { return self.visible; }" not in PANEL_M)
check("ai_initialized", "_ai = [[MiniSightAI alloc] initWithContainer:nil];" in PANEL_M)
check("close_generation_guard", "generation != self.lifecycleGeneration || self.visible || !self.closing" in PANEL_M)
check("request_generation_guard", "generation != strongSelf.requestGeneration" in PANEL_M)
check("teardown_no_lazy_build", "- (void)hideWithoutKey" in PANEL_M and "if (!self.built) return;" in PANEL_M)
check("no_previous_key_window", "previousKeyWindow" not in PANEL_M and "[previous makeKeyWindow]" not in PANEL_M)
check("existing_panel_query", "+ (nullable instancetype)existingPanel;" in PANEL_H and
      "+ (instancetype)existingPanel" in PANEL_M)
check("separate_editor_input", "self.inputField.alpha = 0.01;" in PANEL_M and
      "[self.editorWindow makeKeyWindow];" in PANEL_M and "editorWindow.editorField = editor;" in PANEL_M)
check("full_screen", "MSChatScreenRect(self.window.windowScene)" in PANEL_M and
      "self.window.frame = screen;" in PANEL_M and "anchor.window" in PANEL_M)
check("background_dismiss", "backgroundTapped" in PANEL_M and "UITapGestureRecognizer" in PANEL_M)
check("floating_bubble_panel", "MiniSightChatBubble" in PANEL_M and "MSChatFloatingLayout(" in PANEL_M and "dimView" not in PANEL_M)
check("keyboard_avoidance", "UIKeyboardWillChangeFrameNotification" in PANEL_M and
      "updateCardBottomAnimated" in PANEL_M)
check("rotation_and_safe_area", "UIDeviceOrientationDidChangeNotification" in PANEL_M and
      "safeAreaInsets" in PANEL_M and "UIInterfaceOrientationIsLandscape" in PANEL_M)
check("dynamic_colors", "colorWithDynamicProvider" in PANEL_M and
      "UIUserInterfaceStyleUnspecified" in PANEL_M)
check("controls", all(x in PANEL_M for x in ('@"发送"', '@"取消回复"', '@"清空对话"', '@"收起对话"')))
check("max_30_messages", "kMSChatMaxMessages = 30.0" in PANEL_M and
      "MSCHAT_MAX_MESSAGES" in CORE_H and "(NSUInteger)4" in PANEL_M)
check("disable_while_sending", "self.sendButton.enabled = NO" in PANEL_M and
      'if (self.sending || !self.visible) {' in PANEL_M and '@"busy" : @"not_visible"' in PANEL_M)
check("close_hides", "self.window.hidden = YES" in PANEL_M and "if (!self.visible || self.closing) return;" in PANEL_M and "performClose" in PANEL_M)
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
