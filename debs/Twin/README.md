# Twin

给 ParallelX（或其它基于 SpringBoard 的分屏方案）增加两项能力：

- **Arc 弧形唤醒**：从屏幕边缘按住并向内侧拖动，唤出弧形应用菜单（最近使用应用），松手选中即通过 ParallelX 分屏打开。可在设置中关闭，完全保留原有唤醒方式。
- **Crane 分身**：ParallelX 在打开列表中的应用前，自动调用 Crane（`CraneManager`）切换到指定分身容器，实现"同一个 App 以分身启动"。纯运行时动态调用，未安装 Crane 时自动禁用。

## 安装

- 包名：`com.niubiprass.twin`（Twin 0.1.0，作者 Niubiprass）
- 仅 arm64e（RootHide）与 arm64（rootless）双架构构建，iOS 15.x（SDK 15.5，minOS 15.0）
- 注入进程：`com.apple.springboard`
- 设置入口：设置 → Twin

## 设置说明

- **启用 Twin**：总开关。关闭后弧形手势与 Crane 均不生效（ParallelX 保持原样）。
- **Arc 弧形唤醒**：开启后屏幕边缘（避开顶部状态栏与底部 Home 条区域）画弧唤出菜单；关闭则沿用 ParallelX 原有唤醒。
- **唤醒边**：左 / 右。
- **触发区宽度 / 菜单图标数量 / 菜单半径 / 音效与震动**：弧形手势与菜单微调。
- **Crane 分身支持**：需要已安装 Crane。开启后按"分身应用列表"逐应用生效。
- **分身应用列表**：添加应用并填写该应用的 Crane 容器 ID（在 Crane 的设置中查看）。ParallelX 打开该应用时自动切换到该容器。

## 偏好存储

所有设置保存在越狱根目录私有路径（RootHide：`.jbroot-*` AppGroup 下；Dopamine/rootless：`/var/jb`），**不会写入真实 `/var/mobile/Library/Preferences`**，避免被越狱检测扫描或清理工具误删。多个进程共享同一份路径解析逻辑。

## 构建

Theos + iPhoneOS15.5.sdk，双架构：

```sh
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # arm64e
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # arm64
```

## 说明

- ParallelX 未安装时，Arc 菜单打开应用退回普通启动（不进入分屏）。
- ParallelX 若更新并重命名启动方法，运行时自动跳过，不影响 Twin 其它功能。
- 源码含逆向自 ScreenCore 的弧形菜单几何（触发区域 / 弧形排列），UI 为独立实现。