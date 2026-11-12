# LocalCleanStatusAnimations 本地移植验收

本次交付是独立动画源码实现和本地静态/便携测试结果。没有执行 iOS 编译、SDK 语法编译、CI、commit/push、设备注入、安装或注销；不得将以下通过项表述为 iOS 15.5 真机运行通过。

## 隔离与配置

引擎位于 `Animation/LocalCleanStatusAnimations.xm`；原 `Hooks/LocalCleanStatusAnimations.xm` 已移除，原目标 `Hooks/*.xm Sources/*.m` 不会吸入动画。独立构造器同时检查 bundle ID `com.apple.springboard` 和进程名 `SpringBoard`。新 dylib 的 Makefile、过滤 plist、偏好读写 `.m`、策略与能力 header 由主任务维护。本实现未编辑旧 Config、Paths、Preferences、Main 构造器或已有功能文件。

只调用独立契约 `local_cleanstatus_readAnimationPreferences()` / `local_cleanstatus_sanitizedAnimationPreferences()` / `local_cleanstatus_animationDefaults()`。初始快照使用默认值，总开关默认 OFF。Darwin `LCSAnimationPreferencesChanged` 只调度后台串行读取，结果 `copy` 后交主线程；generation 丢弃过时排队读取及应用。显示帧只读主线程不可变字典，没有 CFPreferences、磁盘读取或路径解析。引擎不回发配置变更通知，避免读写通知反馈环。

所有开关独立于旧插件总开关：`animationEnabled`、`animationApps`、`animationGenie`、`animationIcons`、`animationDroplet`、`animationGestureBounce`、`animationClearSheet`、`animationFlyBlur`。数值范围/默认值为 OpenResponse 0.12–0.50/0.24、CloseSpeed 0.5–2/1、GenieIntensity 0–2/1、FlyStrength 0–3/1、SlowFactor 1–10/1、GlobalSlow 1–5/1。

减少动态效果在主线程收到 `UIAccessibilityReduceMotionStatusDidChangeNotification` 后立即重新应用当前快照，并与动画总开关共同门控。GlobalSlow 通过原子标量供 C hook 跨线程读取；总开关 OFF、Reduce Motion 或倍率 1 时精确返回原函数结果。`UIAnimationDragCoefficient` 使用 `dlsym` 可选解析和 `float(void)` 原型；符号不存在则不安装 C hook，局部计算回退倍率 1。该可选 C 符号有单独的 GlobalSlow=32 能力位；符号缺失时中文设置页禁用该控件并说明原因。

## ABI 与能力

所有安装点在 `%init` 前验证类存在、实例/类方法区分、参数数量、每个参数编码及返回编码。`LCSATypeEncoding.h` 规范化 aggregate 名称和引号内字段名称，保留嵌套层次、数组长度、标量元素和 Block 标记；不以相同字节大小替代结构体布局证明。

- App：完整 zoom、transition、gesture interpolation、settings hooks；CGPoint、CGRect、四 double corner radii 分别验证。缺任一所需 ABI 时整组不安装。
- Genie：App 能力之外，再验证 mesh 工厂类方法、vertex/face 完整规范形状、subdivisionSteps getter/setter 均为 int、CALayer mesh getter/setter 和 item-container hook；不匹配时仅禁用 Genie，保留 App springs。
- Droplet：单独验证 timer 的 double / `@?` / object 参数、update 的 NSUInteger / NSInteger、response 拼接类方法和事件 reason getter。未通过时保持原 radii。`@?` 只能证明 Block 参数类别，不能证明其内部 BOOL(void) invoke 签名；该签名和 delay/options 的行为仍继承上游假设，需真机核验。
- Icons：独立于 App/Genie。验证 presentation / dismissal / commit 和四个 `Cleanup...Transition:`，均为 void(id)；不使用无 15.0 证据的 `coverSheetSlidingViewControllerDidEndTransition:`。同时验证 icon manager/root、前台应用判定的必要 ABI。
- ClearSheet：在 Icons 外单独验证父设置 getter/setDefaultValues 及已知基础 BOOL 属性。每个额外属性仍逐一验证 getter 和 setter，未知字段保持原值；相邻系统缺失的 scaleWallpaper 等字段不会通过 KVC 强写。

能力通过 `local_cleanstatus_publishAnimationCapabilities` 发布 App=1、Genie=2、Icons=4、Droplet=8、Sheet=16、GlobalSlow=32、Blur=64；它使用独立的内存 Darwin state，不写偏好。动态工厂结果、可选 getter/setter、Dock token、high-frame-rate reason、CAFilter 类工厂等在调用实际 receiver 前也核对编码。没有给 Apple 私有 selector 改名；所有自有类型、函数、键使用 LCSA 前缀。

CAFilter 唯一保留的输入写入是新建自有 gaussianBlur 实例的 `inputRadius`；仅当工厂、setter、`CAMLTypeForKey:` 返回接口 ABI 匹配，且该键 schema 明确报告 `double` 时使用，异常即跳过 blur。没有任意对象或未知属性的通用 KVC fallback。新 filter 名为 lcsaGaussianBlur，原有 filters 数组保留。若该系统不提供此 schema，图标飞入照常，blur 不生效。

## 关闭、取消与恢复

收到新配置或减少动态效果通知后，在主线程立即结束 Genie、作废旧 fly generation、移除所有触达 layer 的自有 animation key、恢复 per-instance spring/setting 属性、已有 sublayerTransform/filters/opacity，并释放自身 Dock reason token。Fly-in 即使 hidden 标志已经为 NO 也走相同清理。

弹簧和 CoverSheet 用关联对象保存每个实例、每个字段的 before/written 值；恢复仅在当前值仍等于本模块写入值时执行，尽量保留其他 writer 后续修改。系统自身调用 setDefaultValues 时只处理该实例的已保存字段，不主动调用共享 setDefaultValues，不从一个全局 stock 字典覆盖所有实例。返回的 spring copy 也保存原值，OFF 时存活 copy 同步恢复。

Fly 保存原 transform、filters、透明度，合成自己的 perspective 和 filter，不用 identity/nil/1 代替原值。删除仅限本模块 animation key；若 filters 被外部重新组合，清理尽量仅移除自己添加的 filter。Dock 通过独立 reason token 修改，关闭 invalidate 自身 token，不能把全局 fraction 重设猜测的零。原 brightness 和 corner spring 对象不做持久覆盖。

Genie 保存实际设置后的 mesh model 对象以处理 CALayer copy 语义；只在仍持有自身 mesh 时恢复。发现已有非空 mesh 时跳过，图标 overlay 始终保留未网格化以兼容图标缩放和 badge。grabber 仅临时加自有 opacity animation，结束直接移除，原 model opacity 不动。badge copy 在结束时移除。

Genie 硬上限 15 秒；fly/hide 有 generation 保护和不超过约 15 秒的回收兜底；四种 CoverSheet cleanup 立即复位。有限 fly 结束后恢复所有 model 状态，避免长期隐藏图标。系统 `iconsFlyIn` 不覆盖，保留系统解锁及取消路径；因而与系统自身 fly-in 同时发生的视觉叠加仍需验收。可选 wallpaper 动画没有可恢复契约，未主动调用。

CADisplayLink 请求与复制的 spring frameRateRange 均受 `UIScreen.maximumFramesPerSecond` 限制；iPhone 12 不请求高于 60 Hz。预测网格内部较密采样不代表申请 120 Hz 显示。

## 已完成验证

1. `/opt/theos/bin/logos.pl -c generator=MobileSubstrate Animation/LocalCleanStatusAnimations.xm` 成功；各组只有条件 `%init`，没有隐式无条件 `%init`。
2. `cc -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Werror Animation/portable_validation.c -lm -o /tmp/lcsa_portable_validation && /tmp/lcsa_portable_validation` 通过，输出 `PASS: ABI shape positive/negative checks and finite genie retarget/settle`。仅编译 Linux 便携数学/编码比较测试，没有编译任何 iOS 源码。
3. 编码正反例覆盖 aggregate 改名、CGRect 嵌套、四 double radii、mesh vertex/face 数组、三 float frame range、对象类名、Block/object 区分、int/64-bit 区分、字段类型/数组长度/嵌套错误、截断及超长输入；Genie 覆盖三种 damping、两个方向、运行中 retarget、每帧有限网格值及最终收敛。
4. 静态扫描确认生产引擎没有 CFPreferences、周期性 prefs cache、TEST_HOOKS、Frida exports、recorder、shooter、日志调用或重复前缀 LCSACLCSAG27；日志宏仍从既有 Runtime header 引入，遵循 CLEANSTATUS_STRIP_LOGS。
5. host 测试文件为独立 `.c`，未包含在任一 dylib 的显式源文件列表中。引擎及 support header 使用 C++ 原子/initializer_list，独立目标需要 `LocalCleanStatusAnimations_CCFLAGS += -std=c++14`。

## 仍需真实构建及设备验证

独立证据见 `../../research/compatibility/REPORT.md` 和相邻 15.0/15.6 转储；没有精确 iOS 15.5 私有框架样本，运行时 guard 是失败关闭策略，不是 15.5 全功能保证。Logos 预处理不做 Objective-C++ 类型检查或链接；后续授权构建必须检查编译和符号。必须实测 phase/direction 时序、Block invoke、timer 回调、genie mesh、透明 sheet 可选字段、不同图标/滤镜插件共存、锁屏/解锁到 App、Today/App Library、反向/取消手势、Fly-in/Genie 期间 OFF 和 Reduce Motion 切换、60 Hz/低电量表现。当前未知 API 会导致对应分组或效果安全跳过，UI 应据能力位显示基础支持情况，不能声称效果均已在目标机确认。
