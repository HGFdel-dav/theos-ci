# CloneX 0.1.0

给 **ParallelX** 的分屏菜单加分身（Crane 容器）支持。不修改 ParallelX 本体。

## 做法（全部有二进制证据）

ParallelX alpha342（com.moxuan.parallelx，arm64e，只注入 SpringBoard）是闭源
Swift。经静态分析，它的“菜单点应用图标 → 开分屏窗口”链路存在以下 ObjC 漏斗：

| 选择器 | 类型编码 | 用途 |
|---|---|---|
| `-[PXSceneBridge prepareWindowForBundleID:wasFullscreen:completion:]` | `v36@0:8@16B24@?28` | 为某 bundleID 准备窗口（主钩子） |
| `+[PXPanelEntry applicationActivated:]` | `v24@0:8@16` | 外部唤起/前台激活入口（兜底） |
| `+[PXPanelEntry externalOpenApplication:]` | `v24@0:8@16` | 外部全屏打开入口（兜底） |

CloneX 在 SpringBoard 内 hook 上述方法。命中配置过的应用时：

1. 用 CraneManager 官方接口切容器
   `setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:`
   （老版本 Crane 自动退回带认证接口），并回读 `activeContainerIdentifier`
   核验；切换成功后等 0.5s 让重载落定；
2. 再调用原实现，让 ParallelX 按原样开窗（动画/停靠/记忆全不变）。

所有 hook 安装前做运行时签名核验，签名不符只写日志、不安装。

## 设置

Settings → CloneX：列出 Crane 中所有存在分身的应用；点应用选容器
（默认容器 / 各分身）。偏好存 `com.niubiprass.clonex`（CFPreferences）。
运行日志：`/var/mobile/Library/Application Support/CloneX/runtime.log`。

## 依赖

- 已安装 ParallelX（任意近期 alpha；缺失时插件静默无操作）
- 已安装 Crane（缺失时应用按默认容器打开）

## 验证状态

仅静态分析 + 云编译。**未真机验证。** 已知风险：
- 若该版本 PX 的菜单点击不经上述漏斗，日志里不会有 `[hook]` 行，需要按日志再定位；
- 容器切换会强制重载目标应用（机制固有）；
- 切换失败时仍会按原容器开窗（避免 PX 窗口准备卡在中间态）。
