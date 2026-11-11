# ReynardDefault 1.5.43 本地候选

**状态：本地静态检查通过；未推送、未 CI 编译、未安装、未注销/重启、未真机验收。**

## 范围与授权

用户明确：只交付一个原生 DEB；不带 WebExtension/XPI，不安装、不写扩展配置、不弹“添加插件”；保留 Safari/其他 App→Reynard、设置面板和控制中心。验证真实用户点击外部协议并完整保留参数；启动、刷新、历史、后台和自动重定向不能拉 App。已批准本地核实修改，未批准推送或安装。

## 本轮改动

- 不注入 Helper? **仍注入 `com.minh-ton.Reynard.Helper`**，因为在设备旧记录中真实网页点击运行在 Helper；这是原生进程不是扩展。延迟到主线程再安装 XUL Hook，避免在 dyld 回调内改代码。
- 真实点击由 `nsDocShell::OnLinkClick` 证明；再核验 `UserNavigationInvolvement == Activation`、用户手势、非下载、无 POST/header、顶层上下文和前台状态。所有条件汇总到 `RDProtocolCore.h` 并由 20,686 个主机组合断言覆盖。
- Helper 命中后写一个共享待处理网址并发 Darwin 通知；主 App 仅在“本次通知已到达（armed）”且启用时消费，避免单纯回前台重放。写入同步失败则保留 Gecko 原导航。
- 关闭 handoff 时丢弃待处理值。协议 scheme 先在原生层剔除内部协议；Telegram 仅对已知 action 补 `//`，其余字节保留。
- XUL UUID、`OnLinkClick`、`GetBrowsingContext`、`GetParent` 四处均做指令/边界防护。
- 保留原有 SpringBoard、设置和控制中心文件；`ReynardDefault.plist` 是唯一变化保护文件，其清单哈希已同步。

## 本地已通过

- `run_checks.py`：O0/O2 26 项旧策略、C++ 策略编译、20,686 项协议/点击组合、arm64e 非 PAC 汇编门禁、20 个保护哈希、6 个 plist、图标、无扩展载荷。
- `raw_vtable_call.cpp` 额外编译三参数、无参和五参数原始 XUL 调用。
- 无 `.xpi`、`extensions.json`、`RDHandoffPayload`、`RDExtensionInstall`。

## 未验证 / 风险

- **尚无 iOS 编译或 DEB 验包；C 主机测试不等于真实 ABI。**
- `CFPreferences` 跨 App/Helper 沙盒同一路径尚未真机证明；同步成功也不等于主 App 已收到、已打开目标 App。
- Helper 注入重走 1.5.39 的路径；1.5.39 的整机异常根因仍未证实，延迟安装只是降低回调风险，不是已证明修复。
- 顶层判断依赖 `GetBrowsingContext/GetParent` 偏移与指令保护；版本不符就拒绝 Hook。
- 系统已接收的外链不能撤销；目标 App 拒绝时原页面能否自动续载尚未真机验证。
- 设置关闭后旧通知、并发两次点击、Helper 被回收等运行时竞态未真机覆盖。

历史 1.5.38 说明保留在下方，仅作背景，不代表当前已通过项。

---
# 历史基线记录：ReynardDefault 1.5.38
