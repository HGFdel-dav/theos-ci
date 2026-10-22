# clone0.18：对照历史记录的三项修复（本地待推）

## 约束
- 本轮用户提供截图和两份runtime.log反馈，并强调必须先读旧记忆/源码。
- 只改ParallelX工程；没有MCP/手机读写、安装、截图、构建或push。本地修改无需再等授权，push仍需用户当轮明确「推」。
- 用户看到的菜单、图标、动画和分屏宿主继续使用原版PX，不搬旧Twin自绘菜单、不新增独立插件/设置首页入口。

## 已查历史与来源
1. `ab80bf1`（clone0.8）：`CXHook.m`菜单切容器由`reload:NO`改回`YES`；随后0.9用户确认不同图标分别打开不同账号。源码桥使用官方`reloadApplicationWithIdentifier:`并等待0.5秒。
2. `debs/Twin/Twin/TWRemember.m`：按应用/容器存、缩放/关闭捕获、主队列generation去抖、有限延迟恢复；历史getter/KVC方案只是静态修复，不等于本版Swift字段可安全当对象读。
3. `debs/Twin/Twin/TWSystemGesture.m` 与 `TWArcGeometry.m`：已实现系统手势通道、原版扇形/单侧圆角矩形路径、偏移、调试穿透与即时刷新。
4. `debs/Twin/Prefs/TWOrigArcController.m`、vendor TriggerSettings.plist：侧别0右/1左/2两侧；区域0扇形/1矩形；半径1–300、长高1–150、圆角0–150、XY0–100。仅移植可实际接通的触发部分，不搬旧菜单外观参数。
5. 原版PX vendor SHA256 `4fba6185dd390e9c4ad2723602ad53c0e844ef636d80665c0112b0d9863bd94e`；静态元数据脚本/JSON在workspace/px-clone018-review。

## 当前用户日志（不是旧日志混用）
- 日志`shared-954DF658`是`shared-2FE7F7EA`的完整前缀+21行追加。
- 04:35:31新的clone0.17初始化；04:36:25.879–27.103有75条`resizeHost called`，0条`store/apply`。
- 04:37:38.770 与48.356 Crane回读两个不同container，均`ok=1`，之后约0.04秒就open，无重载记录，配合源码`reload:NO`和用户同账号实测，吻合clone0.7旧根因。
- 04:35:31仅`arc 手势已安装到9个窗口`，新周期0条`arc begin`；旧01:46`找不到PXPanelEntry`不能冒充新版本当前手势日志。

## 修复一：URL账号
- 按clone0.8已通过顺序切容器→重载→开窗；先设内部打开guard避免重载触发第二张sheet。
- `reload:YES`时即使配置activeID已相同也不能跳过（旧NO曾让启动配置与运行账号分离）；异常/切换失败不打开错误账号。
- 仍未验证URL数据重新投递；本版不宣称微信支付跳转交易完整成功、不操作支付。

## 修复二：记忆
- 原版`PXPanelEntry`metadata：`hostedBundleID`裸名存在，但type为空、size16，是原生Swift String?；`panelWindow`是菜单窗，实际缩放`hostWindow`中的`hostCard`。所以“因为mangled导致裸名找不到”不是本次精确根因：现代码还把空type直接拒绝，从未到store。
- 取`activeBridge`、`hostCard`等7个已核证8字节ObjC对象字段；offset来自runtime、白名单+字段槽宽+边界+class校验，不硬编码偏移、不读取16字节String或25字节tuple。
- bundle改用`PXSceneBridge.bundleID`的真实ObjC getter；开窗绑定实际bridge/canvas/bundle/container，普通应用无Crane容器也用DEFAULT，不再跳过记忆。
- 原版`resizeHost:`实质3e440，结束路径3eff0–3f0c0与3f2e8–3f420：card.transform=identity→setFrame→layoutIfNeeded→activeBridge.layoutHost。恢复改为这个顺序；原`layoutHost`5a598按canvas.bounds/sourceSize算scale，不能只改菜单window.frame。
- generation防旧应用写入新窗、用户开始拖动取消延迟恢复、关闭取消任务；维持已有`CXRememberSizes`和开关/reset键。

## 修复三：ARC设置和唤醒
- 在PX Root.plist原面板加`detail=CXArcListController`、`isController=true`且不带bundle键；同CloneXPrefsUI注入，保留分身页位置。
- UI实际接通启用/左右角/形状/半径/矩形长高圆角/XY偏移/调试；共用CXArcSettings默认表，写CX域并走已有Darwin刷新，不改旧SC/Twin配置。
- 捕获真实PX实例：既有init、resizeHost与dragHandle钩子；晚加载有限扫描原版手柄真实gesture target getter，不调用不存在的shared入口，不新建假的PX对象。
- 原参考`SCArcGestureCoordinator sc_registerSystemGestureRecognizer:`0x24ffc–0x25178：`_UISystemGestureManager.sharedInstance`+`UIScreen.mainScreen.displayIdentity`+add/remove；失败返回NO，身份不能nil。此处复用相同链，接口和签名缺失只记桌面fallback。
- ARC手势的命中和debug均复用旧geometry扇形/矩形路径；debug hitTest/pointInside为nil/NO，不造UIWindow覆盖角落点击。
- 合成手势仍是实际UIPan子类，挂到PX可见手柄、遵守view坐标转换、用同一个对象转发began/changed/ended/cancelled；关闭正确取消并注销。该桥本身仍需真机，不能把系统注册日志当菜单唤醒成功。

## 验证边界
- 本机仅语法树/源码链/行为模型检查，不在iSH编译iOS插件，不擅自push。
- 待授权新提交云构建；CI成功后再给新包，并请用户测URL账号/ARC设置与拖动/窗口比例恢复，不声称已有真机通过。
