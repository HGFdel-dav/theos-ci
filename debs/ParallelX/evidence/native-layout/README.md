# alpha451 原版开窗与贴边放大（静态证据）

样本：`vendor/alpha451/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib`，754112 B。
SHA256：`1e6af715a04e9f8b7bcf53c58235419f94bd25b4adcb05abc26a028d0849abdb`。

相对方法表中的宿主类/实例归属、参数编码与 alpha440 核对。旧版 248 个类及实例方法条目在新版仍有相同编码；新版多 9 个条目，包括手动返回点位记录相关入口。它们不替代现有分身、付款、窗口记忆或开窗诊断。只检查本轮接入相关路径，不把编码一致等同完整行为相同。

## 布局与开窗

- `PXSceneBridge.layoutHost` 从 `0x6aef8` 开始。`0x6af48` 通过 `0x7eb60` 读取 `sourceSize`（选择器引用 `0x9f080`）；`hostedSourceSize` 在 `0x6cd20` 尾跳转到同一桩。
- 开窗桥 `openApplication:inView:keyboardOverlay:completion:` 仍为实例方法，从 `0x73598` 开始。按顺序在 `0x73614` 调 `close`、`0x73674` 调 `setCanvas:`、`0x73680` 调 `setKeyboardOverlay:`、`0x7368c` 调 `setBundleID:`，随后 `0x73698` 发布相机宿主状态。保持先清理旧场景再接新画布的顺序。
- `externalOpenApplication:` 仍是 `PXPanelEntry` 的类方法；两个 `performConfiguredAction` 仍是 `PXSceneBridge` 的实例方法。这里不改原入口的挂接类别或业务流转。

## 贴边放大

- `PXDockCoordinator restoreDockTapped:`（实例方法，`v24@0:8@16`）`0x4c9c8` → `0x4c86c` → `0x49574`；按应用匹配已有停靠 host 的分支也从 `0x3975c` 进入 `0x49574`。
- 动画使用捕获的停靠 host，`0x54778` → `0x4f990`。由同一个 host 取卡片和画布桥，依次执行 `setTransform:`（还原为单位变换）、`setFrame:`、`layoutIfNeeded`、`layoutHost`。四个实际消息调用点是 `0x4f9e4`、`0x4fa04`、`0x4fa14`、`0x4fa24`。
- `dockTapped:`、`bottomDoubleTapped`、`bottomHeld:` 保留相同入口及编码。沿用 0.103 的单次原生放大目标替换和独立尺寸/位置保存，不加计时压框，也不改作者的窗口或内容布局。

旧版实现说明里的 alpha440 地址属于历史证据，不参与新版运行或判定。上述 0x 地址仅用于静态测试与取证；没有在设备执行样本，首帧、内容、手势和相邻功能仍需真机核对。
