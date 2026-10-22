# ParallelX（内置分身菜单）

> 当前源码：clone0.18 本地修复候选；未云编译、未推送、未真机验证。
> 具体旧源码复用来源与实测日志证据见 [CLONE018-FIXES.md](CLONE018-FIXES.md)。

包名仍为 `com.moxuan.parallelx`，安装升级覆盖原版ParallelX，不新增独立插件。
原版引擎/vendor二进制原样保留；设置仍嵌入PX自己的面板，无设置首页独立分身入口。

## 菜单与容器

Crane应用有多个容器时自动生成默认/各容器菜单项，无需手动勾选加入。
设置页每个账号一开关；关闭只隐藏菜单项。菜单使用原版
`applications/customActions/applicationNames/shortcutSymbols/shortcutImages` schema；
条目前缀`px.custom.`、类型`clonex.open`，虚拟ID由应用/容器稳定生成。

菜单点击与URL弹窗选择统一走已实测过的clone0.8顺序：
`切容器 → 回读ID → reloadApplicationWithIdentifier: → 等0.5s → externalOpenApplication:`。
切换失败不打开错误账号。原版URL具体数据能否在重载后再投递仍需实测。

## ARC设置

设置→ParallelX→ARC角落唤醒：启用、左右角、扇形/矩形、半径/长高/内侧圆角、
水平/垂直偏移、调试触发区；默认值/命中/调试共用实际接线，不塞不能用的菜单外观开关。
系统手势通道与触发几何复用已有实现；菜单、图标和动画仍由PX驱动。
系统通道/真实PX对象不存在时明确日志和有限fallback，不创建吞触摸的透明覆盖窗口。

## 窗口记忆

按应用+容器保存分屏hostCard实际宽高；无分身的普通应用使用DEFAULT。
保存来自真正的缩放结束/关闭回调，恢复遵循原版card.frame+layoutHost顺序。
不把菜单panelWindow当分屏窗，不把原生Swift String/tuple按ObjC对象读取。
设置页保留记忆开关及重置，关闭后不记录不恢复。

日志：`/var/mobile/Library/Application Support/CloneX/runtime.log`。
关键事件：`[url] selected`、`[crane] reload requested`、`[arc] begin/end`、
`[remember] bind/store/apply`。只有看到设置保存/手势注册不能证明运行已通过。
