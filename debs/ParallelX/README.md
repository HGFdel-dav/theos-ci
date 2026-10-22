# ParallelX（内置分身菜单）

> clone0.2：设置入口改回独立「分身」行（跨 bundle 链接在本机 Preferences 加载失败）。

> 包名 `com.moxuan.parallelx`，装它 = 替换原版 ParallelX。原版引擎二进制
> 原样随包（vendor/PX），分身功能以独立注入层实现，不改原版 Swift 二进制。

## 菜单模型（取自真机 com.moxuan.parallelx.plist）

| 键 | 类型 | 含义 |
|---|---|---|
| `applications` | `[String]` | 菜单条目 id：bundleID / `px.action.*` / `px.custom.*` / `px.url.*` |
| `customActions` | `[[String:Any]]` | `px.custom.*` 记录（`id`/`title`/`app`/`kind`/`type`） |
| `applicationNames` | `[String:String]` | 条目 id → 显示名 |
| `shortcutSymbols` | `[String:String]` | 条目 id → SF Symbol |
| `shortcutImages` | `[String:Any]` | 条目 id → 自定义图标数据 |

每个勾选的「应用 + 容器」注入一条 `px.custom.<FNV64>`（`type=clonex.open`
作标记），标题「应用 · 分身名」，图标为应用图标 + 「分」角标 PNG。

## 点击链路

`-[PXSceneBridge performConfiguredAction:]`（`B24@0:8@16`）拦截
`clonex.open` → Crane 切容器（回读核验）→ `+[PXPanelEntry applicationActivated:]`
用真实 bundleID 开分屏窗口。兜底：`prepareWindowForBundleID:wasFullscreen:completion:`
（`v36@0:8@16B24@?28`）与 `externalOpenApplication:`（`v24@0:8@16`）。

## 设置

设置 → 分身：勾选哪些容器进入分屏菜单。偏好域 `com.niubiprass.clonex`。
检测不到分身组件时，页内会列出所有尝试过的 libcrane 路径，便于排查。

日志：`/var/mobile/Library/Application Support/CloneX/runtime.log`

## 状态

静态分析 + 云编译，未真机验证。
