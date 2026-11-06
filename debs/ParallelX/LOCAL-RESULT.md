# clone0.8 本轮对照与本地验证

## 结论边界
这是源码修复和静态证据，未编译 iOS、未安装、未做真机 A→B→A。不能把下列通过等同运行修好。

## 已复核事实
1. **菜单项为自定义动作不等于只能全屏。** alpha391 `PXPanelEntry +externalOpenApplication:` ObjC入口0x29be8（v24@0:8@16）→Swift helper0x537fc→0x2971c→0x33e28创建窗口、host/canvas/overlay；0x35eb8载入`openApplication:inView:keyboardOverlay:completion:`，0x35ed4传bundle/view/overlay和非空completion实际调用。旧回答「externalOpen就是全屏入口」缺证据，已纠正。
2. **原生托管ABI** `PXSceneBridge -openApplication:inView:keyboardOverlay:completion:` 0x65fc8，v48@0:8@16@24@32@?40。0x667e8/0x667ec向completion传YES，0x66284/0x66288传NO；原生builder Block descriptor0x86328+32→0x7526d为`v12@?0B8`。本轮保留它完整views/原始completion，只包装令牌/单次完成/回调观测。
3. **旧场景查询找错类。** `+sharedBridge`在PXSceneBridge（0x5c444），不在PXPanelEntry。且原版可能创建独立bridge，单例有无scene不等于所有窗口已释放；本轮跟踪真实开窗收到的bridge（弱表），关闭后检查scene/canvas。
4. **按bundle关闭原生上下文。** `PXPanelEntry +switcherRemovedApplication:` 0x299a0，v24@0:8@16→0x526f8：匹配当前hostedBundle才调0x22f40；遍历停靠host，仅匹配同bundle的调0x23870。当前host helper移除视图，0x234b4..0x234d4按flag选择close/closeForFullscreen；此入口传0，走close。停靠helper0x2398c removeFromSuperview、0x23a20..0x23a38 close。`PXSceneBridge -close`0x66c44递增generation、清scene/bundle/canvas、释放托管和键盘。不是close-all，不调用closeApplicationAndRemoveSwitcherCard（后者可kill9）。
5. **ScreenCore 2.0.5顺序证据。** 包SHA256 `4081026da03c7b2b8f2c4ccef444aa2a26b389c740199c6eb7de2aa428dad0e5`；arm64e不同容器分支0x49cf8 sc_beginClosing，0x49ddc stopSceneForSession completion；此Block descriptor0x99928+32→0x79c39=`v8@?0`。后续0x4a628调用terminateApplicationForContainerSwitch...，SCSystemSceneDriver 0x5c868通过FBSystemService sharedInstance请求`terminateApplication:forReason:andReport:withDescription:completion:`；全局completion descriptor0x985a8+16→0x79c39=`v8@?0`。0x5d1e4用FBProcessManager的applicationProcessesForBundleIdentifier:/processesForBundleIdentifier:和isRunning；0x5d6ac轮询，60次×0.1s上限，不能把termination请求当退出完成。本轮复用顺序，原生PX负责窗口，不搬SC引擎。
6. **真实Crane ABI复核。** 从设备只读读取libcrane.dylib（FAT SHA256 `93bf47dfe0c4cde45da81be16c56c00cb749021998943132a64c9b620f56d311`）并静态分arm64e（非注入/执行）。`-setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:`0x84c8把w4设1，即默认reload=YES。显式reload版0x84d4编码v44@0:8@16@24B32@?36。本轮只走后者reload:NO，保留认证，去掉reloadApplication主动拉起造成的全屏竞争。
7. **新增/改名账号** 使用真实Crane方法`_observers_didChangeContainersOfApplicationWithIdentifier:`（0x67a0/v24@0:8@16）、`_observers_didChangeContainerSettingsForContainerWithIdentifier:onApplicationWithIdentifier:`（0x68d8/v32@0:8@16@24），加PXPanelEntry -dragHandle:（0x32224/v24@0:8@16）Began后后台合并刷新。目录/隐藏状态未变时不重新编码PNG/重写5个偏好值/发dock通知。

## 源码行为
- 所有虚拟账号仅进一个串行控制器：清旧PX上下文→验证scene/canvas释放→请求旧进程退出并核对旧process/PID与当前列表→Crane认证reload:NO→active回读→完整原生分屏builder→completion+真实surface+可见层级/屏内区域检查。
- 当前账号的已验证PID和容器均一致才可复用；否则宁可清场重启同账号，不拿仅active配置当运行账号证据。
- 新点击只留一个最新pending。认证尚未回调时不取消/并发切换；超45s进入隔离等待，迟到回调收尾后才处理最新账号。快速A→B→A不再被0.8s全局去重吞掉。
- 失败有短提示，严格停止，不全屏兜底。仅Opening阶段、仅当前bundle阻止PX openFullscreenApplication分支；普通应用/桌面打开不改。
- 最多32条不含账号名/消息/凭据的阶段证据，写入PXCloneCurrentPrefsPath派生的同隐根`.launch-trace.plist`，路径缓存、异步原子写；不依赖当场抓日志，不写真实var。

## 本地检查
- 完整tools/validate.py：103项host测试通过；原版DEB精确哈希、vendor16文件逐字节、plists、roothide/rootless维护脚本、control一致、结构/unused守卫均过。
- 生产C阶段门禁直接在主机编译运行：85,040断言（这不是编译iOS插件）。覆盖回环、跳阶段、旧令牌、错误账号、待切新目标、未可见、认证超时隔离等。
- Python队列/菜单测试为确定性模型与源码约束，不假称执行ObjC私有服务或真机测试。
- 本机Objective-C tree-sitter解析器调用发生Segmentation fault；无可用语法/类型检查结果，未记为通过。iOS ARC/类型/链接/PAC/包维护脚本与签名须CI再验。

## 未验证与风险
- 设备FBSystemService/FBProcessManager的实际运行时编码、权限与响应未调用；源码在使用前逐参校验（reason允许q/i），不可用则显式失败而不乱调。
- 旧窗口异步关闭、原生scene generation取消、认证弹层和分屏可见判据均待真机。可见不等于画面可交互或真实登录账号已人工验收。
- Crane从未返回的认证无法安全撤销：超时会提示并阻止并发，不承诺安全重试；不会放行旧回调打开错误账号。
- 若最后一个分身删除导致目录完全空，仍保留既有空目录不删行保护；点击时实时containerExists阻断被删目标，未来独立处理空目录删除UX。

## 状态
本地候选clone0.8；已获用户本轮commit/push/CI授权，当前推进至GitHub CI；未安装/注销/重启，原clone0.7交付包未改。只读设备取库未修改设备或设置。
