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

# ---- 3. 录屏：成功提示只能出现在真实回调里 ----
i_req  = tweak.index('startRecordingWithHandler')
i_start_msg = tweak.index('MiniSightSay(@"开始录屏")')
ok(i_start_msg > i_req, '3a “开始录屏” 出现在启动回调之前')
i_err = tweak.index('if (error) {', i_req)
ok(i_err < i_start_msg, '3b 启动失败分支未在成功提示之前 return')
i_stop = tweak.index('stopRecordingWithOutputURL')
i_saved = tweak.index('录屏已保存')
ok(i_saved > i_stop, '3c “录屏已保存” 出现在停止回调之前')
i_serr = tweak.index('if (error) {', i_stop)
ok(i_serr < i_saved, '3d 保存失败分支未在成功提示之前')
ok('MiniSightRecStarting' in tweak and 'MiniSightRecStopping' in tweak, '3e 缺少启停中间态')
ok('attributesOfItemAtPath' in tweak and 'AVURLAsset' in tweak, '3f 保存后未校验文件字节/时长')
ok('bytes < 1024.0' in tweak or 'bytes < 1024' in tweak, '3g 未拒绝空文件')

# ---- 4. 长按开关真正生效 ----
ok('minisight.longPress' in tweak, '4a 未读取长按开关')
ok('MiniSightLongPressEnabled()' in tweak, '4b 缺少长按开关读取函数')
toggle = tweak[tweak.index('static void MiniSightToggleRecording'):]
toggle = toggle[:toggle.index('\n}\n')]
ok('if (!MiniSightLongPressEnabled()) return;' in toggle, '4c 关闭开关后仍会切换录屏')
lp = tweak[tweak.index('- (void)handleLongPress:(UILongPressGestureRecognizer *)press {'):]
lp = lp[:lp.index('\n}\n')]
ok('MiniSightLongPressEnabled()' in lp, '4d 长按手势没看开关')
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
ok('MiniSightShowStatusLine(why)' in tweak, '10d 出错时没显示原因')
ok(tweak.count('else MiniSightSayPresetLine();') == 2, '10e 预设话调用点数量不对（只该剩「没配过」和「无话可说」两处）')
ok('else if (why.length) MiniSightShowStatusLine(why);' in tweak, '10e2 有原因时仍可能走到预设话')
ok('if (data.length) MiniSightShowStatusLine(@"AI 设置没填全（地址/Key/模型）");' in tweak, '10e3 填了但没填全时没提示')
ok('MiniSightAIDetail' in tweak and 'ai-last.txt' in tweak, '10f 没留诊断文件/摘要')
ok('withString:@"***"' in tweak, '10g 诊断文本没做 key 脱敏')
ok('timeoutInterval = 6.0' in tweak, '10h 超时时间与提示不一致')
ok('AI 被限流（429）' in tweak, '10i 429 文案缺失')

print('检查项：%d' % checks)
for f in fails:
    print('FAIL ' + f)
sys.exit(1 if fails else 0)
for f in fails:
    print('FAIL ' + f)
sys.exit(1 if fails else 0)
