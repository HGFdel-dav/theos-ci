# CloneX 0.2.0

给 **ParallelX 的分屏菜单**加分身图标：每个勾选的「应用 + 容器」都作为
独立条目出现在菜单里（应用图标 + 「分」角标 + 「应用名 · 分身名」标题）。
点击条目 → 先切 Crane 容器 → 再让 PX 用真实 bundleID 开分屏窗口。
不修改 ParallelX 本体。

## PX 菜单的真实条目模型（取自真机 com.moxuan.parallelx.plist）

| 键 | 类型 | 含义 |
|---|---|---|
| `applications` | `[String]` | 菜单条目 id：bundleID / `px.action.*` / `px.custom.*` / `px.url.*` |
| `customActions` | `[[String:Any]]` | `px.custom.*` 记录（`id`/`title`/`app`/`kind`/`type`） |
| `applicationNames` | `[String:String]` | 条目 id → 显示名 |
| `shortcutSymbols` | `[String:String]` | 条目 id → SF Symbol（图标兜底） |
| `shortcutImages` | `[String:Any]` | 条目 id → 自定义图标数据（应用图标 + 角标 PNG） |

CloneX 按同一模型注入：`px.custom.<FNV64>`，`type = clonex.open`（用于识别
和清理），只增删自己的条目，不碰用户原有条目。

## 点击链路

PX 菜单点击自定义条目会走 `-[PXSceneBridge performConfiguredAction:]`
（`B24@0:8@16`，alpha342 已验证）。CloneX 在此拦截 `clonex.open`：

1. `CraneManager setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:`
   （旧 Crane 退回带认证接口），回读 `activeContainerIdentifier` 核验；
2. 成功后调用 `+[PXPanelEntry applicationActivated:]` 让 PX 用真实 bundleID
   打开分屏窗口（动画/停靠/记忆全部是 PX 原生）。

兜底钩子：`prepareWindowForBundleID:wasFullscreen:completion:`（v36@0:8@16B24@?28）
与 `externalOpenApplication:`（v24@0:8@16）——都只对 `px.custom.*` 虚拟条目生效。
所有 hook 安装前做运行时签名核验，不符只记日志不安装。

## 设置

Settings → CloneX：列出有分身的应用 → 勾选要放进菜单的容器（多选）。
偏好域 `com.niubiprass.clonex`（`CXMenuItems`）。改动会实时同步进 PX 偏好；
若 PX 菜单已打开过，重新打开菜单或重启一次桌面刷新。

日志：`/var/mobile/Library/Application Support/CloneX/runtime.log`

## 依赖

- 已安装 ParallelX（缺失时插件静默无操作）
- 已安装 Crane（缺失时点击条目只做普通打开）

## 验证状态

静态分析 + 云编译。**未真机验证**。已知不确定点：
- PX 是否用 `shortcutImages` 的 PNG 直接当条目图标（若否，回落到 `shortcutSymbols` 的符号图标）；
- PX 菜单读取偏好的时机（改动后可能需要重开菜单/重启桌面）。
日志里 `[menu] synced ...` 与 `[hit] ...` 两行可确认注入与点击是否命中。
