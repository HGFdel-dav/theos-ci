# alpha440 原版布局证据（只读静态分析）

样本：`vendor/alpha440/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib`
SHA256：`8fae4085b131ff577173584d4bb4bc53530764d4df441d519e2ae64bdbfae9dd`

重新复核日期：2026-11-22（作者 alpha440 包）。以下地址来自本机静态解析（Mach-O 段表、相对方法表、选择器桩），不是运行时追踪。

`PXSceneBridge.layoutHost` 入口 `0x639b4`（pacibsp 开头）：

1. `0x639dc` 调用 `hostView`，`0x639f0` 调用 `canvas`；
2. `0x63a04` 通过桩 `0x76900` 读取 `sourceSize`（选择器引用 `0x96fa0`，字符串 `sourceSize`），随后读 `bounds`；
3. `0x63ac4` 起进入 `performWithoutAnimation:` 更新键盘层与布局。

`hostedSourceSize` 实现 `0x647e4` 是尾跳转到同一 `sourceSize` 桩（`b 0x76900`），说明窗口记忆读取的源尺寸与原生布局使用的是同一份数据。

## 开窗顺序（`PXSceneBridge openApplication:inView:keyboardOverlay:completion:`，入口 `0x6b05c`）

| 地址 | 目标桩 | 选择器 |
|---|---|---|
| `0x6b0d8` | `0x75080` | `close` |
| `0x6b138` | `0x762c0` | `setCanvas:` |
| `0x6b144` | `0x76540` | `setKeyboardOverlay:` |
| `0x6b150` | `0x762a0` | `setBundleID:` |
| `0x6b15c` | `0x75f40` | `publishHostedCamera:` |

与 alpha437 的顺序一致：先同步关闭旧场景，再设置新画布、键盘覆盖层与应用标识。开窗票据、初次清理识别和恢复时机所依赖的这条顺序没有变化。

## 与 alpha437 的差异

- 所有地址整体后移（主库 702,704 → 719,600 字节），但上述顺序、`layoutHost` 读取源尺寸、`hostedSourceSize` 尾跳转都保持。
- 原版设置项新增「右边缘滑动返回」的即时生效通知；该设置由作者二进制自行处理，我们的叠加层不涉及。
- 旧版 alpha437 的对应地址与证据保留在 `evidence/local-099/FINAL-LOCAL-AUDIT.json` 与历史交付中，只作对照，不能当作当前版本结论。

静态证据不等于真机行为；首帧尺寸、内容跟随、关闭与缩小手势仍需装机验收。
