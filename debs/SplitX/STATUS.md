# SplitX 当前状态

dev6，**只到本地源码**：未编译、未推送、未安装、未真机验证。

## 这一版写了什么

- 菜单改成扇形：手柄处是圆心，图标沿半圆弧散开，底板也是扇形；悬停 1.16 + 外推、其余压暗 0.42；选中先弹再收；遮罩 0.22。
- 参数：图标 40–72、底板 52–88、扇形半径 70–170、张角 60–200°、不透明度 40–100%。
- 设置存储修正：原来读 `standardUserDefaults`（SpringBoard 自己的域），读不到设置页写入的值；改读 `com.niubiprass.splitx` suite。
- 菜单：同应用的容器相邻显示，默认号标「默」、分身标序号，第一项带应用名。
- 切换：防重入 + 8 秒看门狗；失败不留白，回到原目标并弹提示；成功才记录「该应用的目标容器」。
- 外部唤起 / 付款：先按记录的容器切，4 秒切不动按当前容器放行（不堵付款）。

## 没验证的东西

- 一次都没编译过（本地无 Xcode，CI 未跑）。`check.py` 全过只是静态文本检查。
- 弧线角度、弹簧参数、遮罩浓度都是按 PX 录屏估的，没比对过真机。
- `NSUserDefaults` suite 与设置页的写入域是否真的一致，要装上看设置是否生效。
- 付款预切换的命中率未知：只挂了 `handleOpenApplicationRequest`，App 内跳转（AppToApp transaction）可能不经过它。
- 失败恢复会重新 open 窗口，可能有一次闪烁。

## 诊断日志（dev6 加入）

- 位置 `/var/mobile/Documents/SplitX/runtime.log`，每行带毫秒时间、序号、级别、线程、模块。
- 单文件 2MB，滚动保留 3 份；ObjC 异常把内存尾部 200 行 + 调用栈写 `crash.log`；SIGSEGV/SIGBUS/SIGABRT 等信号崩溃写 `crash.signal.log`（含崩溃前 64KB 日志），下次启动 [boot] 会提示。
- 启动写一次环境快照（机型、系统、越狱类型、Crane 路径、全部面板设置）；之后每 30 秒一条心跳（前台应用、可用内存、load、面板状态）。
- 覆盖：手柄手势、面板构建/悬停/选择、开窗关窗、容器枚举与切换每一步、scene 发布、托管失败、外部请求（bundle/URL）、设置变更 diff、钩子安装结果。
- 设置页「诊断日志」可直接查看尾部 400 行、一键清空。
- 级别：默认 Info；`PXLogD` 默认不写，排查时可调 `PXLogSetLevel(PXLogLevelDebug)`。

## 下一步（M2 前置）

1. 编译。
2. 先只测面板外观与参数是否生效，不看功能。
3. 再测同应用两容器切换 A→B→A。
4. 最后测付款。

## 已踩过的坑（禁止复现）

1. 设置包引用了某个类，就必须把那个 .m 一起编进 SplitXPreferences，否则 dlopen 报 `symbol not found`、设置页空白。目前需要一起编的：POCraneBridge、POSplitTarget、POSplitXLog、POSplitXSettings。
2. pbxproj 新文件要四处齐全：PBXFileReference、PBXBuildFile、所在 group、Sources phase；ID 必须 24 位十六进制（我曾写过带 G 的）。
3. 子页不能 `setValue:forKey:@"bundle"`，会抛 NSUnknownKeyException 闪退；用 POSubPageController 在 viewDidLoad 里 loadSpecifiers。
4. 分身枚举必须用 `containerIdentifiersOfApplicationWithIdentifier:` + `displayNameForContainer...`，不要去猜 settings 的 Containers 键。
5. `processState` 的 pid 编码要同时接受 int / long long；读不到进程时不要直接失败。
6. 面板 present 一定别忘了 `self.hidden = NO`。
7. 扇形半径以设置为准，不能被环数或可用空间覆盖；环距固定为图标 1.15 倍，放不下就少显示几环，宁少勿叠。
8. 手柄常态 alpha 0，滑动时出现，关窗归 0；pan 的上下方向必须留给移动手柄。
9. 窗口宽度按屏幕宽乘百分比，默认 62；不要用「可用宽度」二次相乘。
10. 关闭用缩小淡出，不是平移出屏。
11. 滑杆的 min/max/default 必须和 POSplitXSettings 的 clamp 完全一致，check.py 已有守卫。

## 操作探针（本地，未推送）

日志现在覆盖：

- 手柄：长按（状态/坐标/时长/允许位移）、点击（坐标/面板状态）、拖动开始（起点/速度/面板状态/偏移）、上下移动分流、菜单阈值与成功失败、拖动结束（终点/速度/总位移/最终意图）。
- 菜单：列表来源（style/收藏数/请求数/槽位/截断结果）、布局（环数/单位/内径/半径/跨度/容量/锚点）、每个图标的环/角度/半径/坐标/缩放/目标、命中（点/距离/角度/得分/候选/目标中心）、悬停、选中、落空。
- 窗口：缩放开始/过程/结束（起始缩放/位移/目标/实际）。
- 设置：滑杆旧值→新值、范围、synchronize 结果、写入失败。
- 子页：init、load（plist/bundle）、异常、push 与导航栈深度。
- 分身：原始容器列表、前置状态、已在目标、不受支持、进程状态每一步失败点、终止、轮询、回读、耗时、失败恢复。
- 日志目录统一到 /var/mobile/Documents/SplitX，Preferences 与 SpringBoard 写同一份。
