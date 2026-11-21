# alpha437 原版布局证据（只读静态分析）

样本：`vendor/alpha437/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib`
SHA256：`85b0c603906bfea86e4ca007cd43fcbb5d386722dd57ff156a924a8a595856b2`
架构：arm64e。详细指令来自 `../layoutHost.txt`；文件偏移/selector 引用使用既有验证器和 `NATIVE-LAYOUT-CALLS.json` 交叉核对。

`PXSceneBridge.layoutHost` 入口 `0x63788`：

1. 读取宿主视图与画布的尺寸，并读取 `sourceSize`（调用点 `0x637d8`）。
2. 以内容源尺寸与可用窗口边界算出等比缩放，取横纵两个比例中较小的一个（`0x6381c`–`0x6382c`）。
3. 配置宿主视图的 bounds，标记并执行布局（`0x63974`、`0x6397c`、`0x63984`），再设置中心和重新计算出的 transform（`0x6399c`、`0x639c8`）。这一步是浮窗里面内容跟随外框的原版机制。

0.97 将 `PXWMTryRestore` 中 `layoutHost` 移到保存的 `card.frame` 之前，同时新增 `PXWMReapplyInitialGeometry` 在稍后只写 `card.frame`，不再走原版内容尺寸计算。因而源码路径允许“外框变化、内容仍维持旧尺寸”，与用户录屏现象吻合。原版指令是静态证据；它不等于当前手机执行分支的动态追踪。

本地修复只回到已发布0.96顺序：先恢复记忆外框，再调用原版布局更新内容；移除0.97的重复外框强制回压。还需运行静态测试、SDK语法检查；真机内容跟随仍要在新包安装后验证。
