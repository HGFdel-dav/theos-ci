#!/usr/bin/env python3
# MiniSight 宿主侧静态守卫：窗口坐标 / 长按开关 / 录屏状态机 / 与桌宠的接口契约
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
def read(name):
    with open(os.path.join(ROOT, name), encoding='utf-8') as f:
        return f.read()

tweak = read('Tweak.xm')
pet_h = read('MiniSightPet.h')
pet_m = read('MiniSightPet.m')
layout = read('MiniSightLayout.h')
makefile = read('Makefile')
fails, checks = [], 0

def ok(cond, label):
    global checks
    checks += 1
    if not cond:
        fails.append(label)

# ---- 1. 窗口永远整屏，位置只落在子视图上 ----
ok('gMiniSightWindow.center' not in tweak, '1a 仍在移动 window.center')
ok(tweak.count('gMiniSightWindow.frame = rect;') == 1, '1b window.frame 应只有一处整屏赋值')
ok('MiniSightSetAnchor' in tweak and 'gMiniSightAnchor' in tweak, '1c 缺少统一锚点入口')
ok('gMiniSightPet.centerBounds' in tweak, '1d 未把可行范围交给桌宠')
# 所有 .center = 赋值必须在 MiniSightSetAnchor 或 PlaceBubble 的让位里
center_lines = [l.strip() for l in tweak.splitlines()
                if re.search(r'\b(gMiniSightPet|gMiniSightPill)\.center\s*=', l)]
ok(len(center_lines) <= 3, '1e 出现了额外的 .center 赋值：%r' % center_lines)

# ---- 2. 气泡恒在上方，不再“放不下就翻到下面” ----
ok('above ?' not in tweak, '2a 仍存在上下翻转分支')
place = tweak[tweak.index('static void MiniSightPlaceBubble(CGFloat w, CGFloat h) {'):]
place = place[:place.index('\n}\n')]
ok('MSLayoutAnchorForBubble' in place, '2b 气泡让位未走布局层')
ok('MSLayoutBubble' in place, '2c 气泡矩形未走布局层')
ok(place.count('addQuadCurveToPoint') == 2, '2d 尾巴应为两段二次曲线')
ok('addLineToPoint' not in place, '2e 尾巴里仍有直线段')
ok('cornerCurve' in place, '2f 缺少 continuous 圆角')

# ---- 3. Recording uses the owned, fail-closed SpringBoard controller ----
recorder = read('MiniSightRecorder.m')
recorder_header = read('MiniSightRecorder.h')
recorder_core = read('tools/recorder/MiniSightRecorderCore.h')
ok('MiniSightRecorder.m' in makefile and 'MiniSightRecorder.h' in tweak, '3a recorder implementation is not built/imported')
ok('MiniSightRecorder.sharedRecorder toggle' in tweak and 'gMiniSightRecorderConfigured' in tweak,
   '3b manual long-press is not routed behind configuration readiness')
ok('configureAutomaticEnabled:automatic' in tweak and 'setAutomaticActive:(active && gMiniSightRecorderAutomaticEnabled)' in tweak,
   '3c automatic source is not independently gated')
config_body = tweak[tweak.index('static void MiniSightConfigureRecorderWithCompletion(void (^completion)(void)) {'):]
config_body = config_body[:config_body.index('\n}\n')]
ok('setAutomaticEnabled:automatic manualEnabled:manual' in config_body and
   config_body.index('setAutomaticEnabled:automatic') < config_body.index('dispatch_async') and
   'MiniSightReadActivitySnapshot();' in config_body and 'setAutomaticActive:gMiniSightActivityExecuting' not in tweak,
   '3c2 recorder source flags must precede IO; capture must use a fresh activity snapshot')
ok('executingCount' in tweak and 'MiniSightActivityNote' in tweak and 'pendingApprovalCount' not in tweak[tweak.index('static void MiniSightApplyActivitySnapshot'):tweak.index('static void MiniSightReadActivitySnapshot')],
   '3d automatic capture must depend only on valid device-execution phase')
ok('gMiniSightActivityPID' in tweak and 'gMiniSightActivityInstanceID' in tweak and 'activeProcessAlive' in tweak,
   '3d2 transient snapshot read failure can stop a live owned recording')
ok('setAutomaticActive:NO' not in tweak[tweak.index('static void MiniSightDestroyUI(void) {'):tweak.index('static void MiniSightReloadSettings(void) {')],
   '3d3 UI reconstruction must not end an active automatic recording')
ok('MiniSightRecorderSourceAutomatic' in recorder_core and 'source != m->owner' in recorder_core,
   '3e recorder stop is not owner-scoped')
ok('MSRMethodMatches' in recorder and 'os.majorVersion != 15 || os.minorVersion != 5' in recorder,
   '3f backend ABI or exact OS gate is missing')
ok('MiniSightRecorderStartReply' not in recorder and 'MSRStartReply' in recorder_core,
   '3g recorder state transitions bypass shared reducer')
ok('loadValuesAsynchronouslyForKeys:' in recorder and 'AVKeyValueStatusLoaded' in recorder,
   '3h saved video is not asynchronously verified')
ok('startRecordingWithHandler' not in tweak and 'stopRecordingWithOutputURL' not in tweak,
   '3i legacy ReplayKit path remains active')
ok('MiniSightRecorderIssueText' in tweak and 'systemErrorCode' in tweak,
   '3j recorder error code is not surfaced')
ok('recording-last.json' in tweak and 'result.fileURL.lastPathComponent' in tweak,
   '3k successful recordings lack a discoverable result index')

# ---- 4. 长按开关真正生效 ----
ok('minisight.longPress' in tweak, '4a 未读取长按开关')
ok('MiniSightLongPressEnabled()' in tweak, '4b 缺少长按开关读取函数')
toggle = tweak[tweak.index('static void MiniSightToggleRecording'):]
toggle = toggle[:toggle.index('\n}\n')]
ok('MiniSightLongPressEnabled()) return;' in toggle and 'gMiniSightRecorderManualEnabled' in toggle,
   '4c 关闭开关后仍会切换录屏')
lp = tweak[tweak.index('- (void)handleLongPress:(UILongPressGestureRecognizer *)press {'):]
lp = lp[:lp.index('\n}\n')]
ok('MiniSightToggleRecording();' in lp and 'refreshPreferences:' in toggle, '4d 长按未读取当前手动开关')
ok('UIGestureRecognizerStateBegan' in lp, '4e 长按缺 Began 分支')
ok('MiniSightInteractionBegin' in lp, '4f 长按未冻结漫游')
# 长按手势必须挂在宿主这一侧（不是桌宠内部）
ok('action:@selector(handleLongPress:)' in tweak, '4g 长按手势未由宿主安装')
ok('minimumPressDuration = 0.9' in tweak, '4h 长按阈值被改动')
ok('allowableMovement = 10.0' in tweak, '4i 长按允许位移未设置（会跟拖动手势抢）')

# ---- 5. 与桌宠的接口契约：用到的属性/方法必须都在头文件里 ----
header_api = set(re.findall(r'@property[^;]*?\)\s*(?:nullable\s+)?[\w<>* ]*?(\w+);', pet_h))
header_api |= set(re.findall(r'-\s*\((?:instancetype|void|BOOL)\)\s*(\w+)', pet_h))
header_api |= set(re.findall(r'\^\)?\s*(\w+)\)', pet_h))
header_api |= {'center','bounds','frame','hidden','superview','layer','centerBounds'}
used = set(re.findall(r'gMiniSightPet\.(\w+)\s*=', tweak))
used |= set(re.findall(r'\[\s*gMiniSightPet\s+(\w+)\]', tweak))
used |= set(re.findall(r'\[\s*\[\s*MiniSightPetView\s+alloc\]\s+(\w+):', tweak))
missing = sorted(u for u in used if u not in header_api)
ok(not missing, '5a Tweak.xm 用了头文件里没有的桌宠成员：%r' % missing)
ok('setSuspended' in tweak or 'suspend' in tweak.lower(), '5b 未处理息屏挂起')
ok('roamingPaused' in tweak and 'interactionActive' in tweak, '5c 拖动/长按未与漫游互斥')
ok('reducedWork' in tweak, '5d 低电量未降档')
ok('NSProcessInfoPowerStateDidChangeNotification' in tweak, '5e 未监听低电量变化')
power = tweak[tweak.rindex('- (void)handlePowerStateChange:'):]
power = power[:power.index('\n}\n')]
ok('dispatch_async(dispatch_get_main_queue()' in power and power.index('dispatch_async(dispatch_get_main_queue()') < power.index('gMiniSightPet.reducedWork'),
   '5f 电源通知回调未先切主线程再操作 UI')
ok('MiniSightResources.m' in makefile and 'ImageIO' in makefile, '8c 资源加载实现/框架未纳入插件构建')
ok('gMiniSightBubbleScroll.contentSize' in tweak and 'scrollEnabled' in tweak,
   '8d 气泡正文缺少限高滚动')
ok('NSString *text = action.length ? [NSString stringWithFormat:@"%@\\n%@", action, command] : command;' in tweak,
   '8e 审批命令仍被 UI 截断')
ok('MiniSightCancelConfirm(void) {' in tweak and 'kMiniSightConfirmCancel' in tweak,
   '8f 审批隐藏/取消未拒绝收口')

# ---- 6. 桌宠侧：不再自己吃手势、不再递归 ----
ok('addGestureRecognizer' not in pet_m.split('@implementation')[1], '6a 桌宠内部仍在创建手势')

# ---- 7. RootHide 规矩：不硬编码真实 Preferences 路径 ----
ok('/var/mobile/Library/Preferences' not in tweak, '7a Tweak.xm 硬编码了真实 Preferences 路径')
ok('MiniSightAppContainer' in tweak, '7b 未走 App 容器读设置')

# ---- 8. 构建配置 ----
ok('AVFoundation' in makefile, '8a Makefile 未链接 AVFoundation')
ok('MiniSightLayout.h' in tweak, '8b 未包含布局头文件')

# ---- 9. 括号配平（粗查截断/漏闭合） ----
for name, text in (('Tweak.xm', tweak), ('MiniSightPet.m', pet_m), ('MiniSightLayout.h', layout)):
    ok(text.count('{') == text.count('}'), '9 %s 花括号不配平 %d/%d' % (name, text.count('{'), text.count('}')))

# ---- 10. AI 出错的诊断（429/401/404 不能静默换成预设话） ----
ok('statusCode' in tweak, '10a 没看 HTTP 状态码')
ok('status == 429' in tweak, '10b 没专门处理 429 限流')
ok('MiniSightAIShortReason(status, detail)' in tweak, '10c 没把状态码翻成人话')
ok('MiniSightAIResponseText' in tweak and 'MiniSightAITextFromObject' in tweak, '10d AI 响应格式覆盖不够')
ok('MiniSightSayPresetLine();' in tweak, '10e AI 失败没有预制回退')
ok('AI 配置不完整；保留原配置并回退预制句子' in tweak, '10e2 不完整配置没有安全回退')
ok('AI 返回了空内容（200），已回退预制句子' in tweak, '10e3 空响应没有安全回退')
ok('MiniSightAIDetail' in tweak and 'ai-last.txt' in tweak, '10f 没留诊断文件/摘要')
ok('withString:@"***"' in tweak, '10g 诊断文本没做 key 脱敏')
ok('timeoutInterval = 6.0' in tweak, '10h 超时时间与提示不一致')
ok('AI 被限流（429）' in tweak, '10i 429 文案缺失')

# ---- 11. 两种显示模式严格隔离：常驻 vs MCP 活动 ----
show_body = tweak[tweak.index('static void MiniSightShow(void) {'):]
show_body = show_body[:show_body.index('\n}\n')]
reload_body = tweak[tweak.index('static void MiniSightReloadSettings(void) {'):]
reload_body = reload_body[:reload_body.index('\n}\n')]
callback = tweak[tweak.index('static void MiniSightDarwinCallback('):]
callback = callback[:callback.index('\n}\n')]
confirm = tweak[tweak.index('static void MiniSightShowConfirm(void) {'):]
confirm = confirm[:confirm.index('\n}\n')]
ok('if (!MiniSightAlwaysShow() && !gMiniSightBurst) return;' in show_body,
   '11a 调用模式 show 缺少活动门禁')
ok('MiniSightAlwaysShow() || (gMiniSightBurst && wasVisible)' in reload_body and 'MiniSightShow();' in reload_body,
   '11b 切换常驻后未主动显示')
ok('if (!MiniSightShown() || (!MiniSightAlwaysShow() && !gMiniSightBurst)) return;' in confirm,
   '11c 空闲确认通知仍可唤醒窗口')
ok('if (gMiniSightBurst || MiniSightAlwaysShow()) {' in callback,
   '11d 状态通知未受活动/常驻约束')
ok('gMiniSightIdleHide' not in tweak and 'gMiniSightMaxShow' not in tweak,
   '11e 存在会截断有效 MCP 调用的自动隐藏计时器')
ok('dispatch_after' not in tweak[tweak.index('static void MiniSightArmIdleHide(void)'):tweak.index('static void MiniSightShowLine(')],
   '11f 状态通知仍能启动空闲自动隐藏')

print('检查项：%d' % checks)
for f in fails:
    print('FAIL ' + f)
sys.exit(1 if fails else 0)
