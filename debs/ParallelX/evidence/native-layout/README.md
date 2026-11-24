# alpha455 原版开窗与贴边放大（静态证据）

样本：`vendor/alpha455/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib`，754208 B。
SHA256：`324e10caca12770671e2c4b35e25c6dc7033939ebdcaf6c439993e9deb2d7389`。

## 作者 alpha455 相对 alpha451 的变化

- 16 个载荷路径不变，只有 `ParallelX.dylib` 有实际代码变化（754112→754208 B）。
- `ParallelXCameraSupport.dylib` 与 `ParallelXPrefs` 所有非签名段逐字节相同，仅 UUID/签名不同。
- Root/Window/System/External/Keyboard/Info/SettingsHelp、PreferenceLoader 配置及三张图标逐字节相同；本项目的两条设置叠加仍然成立。
- 本轮关注的 7 个宿主/停靠类共 197 个方法，selector 与参数编码和 alpha451 相同；开窗、布局、贴边入口未换类或换签名。这只证明本轮接入点可用，不声称作者其他行为完全没变。

## 布局与开窗

- `PXSceneBridge.layoutHost` 从 `0x6aef8` 开始。`0x6af48` 通过 `0x7f620` 读取 `sourceSize`（选择器引用 `0x9f090`）；`hostedSourceSize` 在 `0x6d4f0` 尾跳到同一桩。
- 开窗桥 `openApplication:inView:keyboardOverlay:completion:` 仍是实例方法，从 `0x73d68` 开始。按顺序在 `0x73de4` 调 `close`、`0x73e44` 调 `setCanvas:`、`0x73e50` 调 `setKeyboardOverlay:`、`0x73e5c` 调 `setBundleID:`，随后 `0x73e68` 发布相机宿主状态。仍是先清理旧场景再接新画布。
- `externalOpenApplication:` 仍是 `PXPanelEntry` 的类方法；两个 `performConfiguredAction` 仍是 `PXSceneBridge` 的实例方法。挂接类别和业务参数未变。

## 贴边放大

- `PXDockCoordinator restoreDockTapped:`（实例方法，`v24@0:8@16`）仍从 `0x4c9c8` 开始，分支 `0x4c9fc → 0x4c86c → 0x49574`；按应用匹配已有停靠 host 的 `0x3975c → 0x49574` 分支也保留。
- 动画仍使用捕获的停靠 host，`0x54778 → 0x4f990`；由同一 host 取卡片和画布桥，依次执行 `setTransform:`、`setFrame:`、`layoutIfNeeded`、`layoutHost`。四个消息调用点仍是 `0x4f9e4`、`0x4fa04`、`0x4fa14`、`0x4fa24`；对应选择器引用变为 `0x9f038`、`0x9ef18`、`0x9ecb0`、`0x9eca8`，`objc_msgSend` 桩为 `0x7d294`。
- `dockTapped:`、`bottomDoubleTapped`、`bottomHeld:` 入口及编码不变。沿用 clone0.103 的单次原生放大目标替换和独立尺寸/位置保存，不加计时压框，也不改作者的窗口或内容布局。

上述 0x 地址仅用于静态测试与取证；没有在设备执行样本，首帧、内容、手势和相邻功能仍需真机核对。
