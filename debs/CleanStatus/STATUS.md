# CleanStatus 0.3.0 动画集成本地状态

## 授权与阶段
用户同意中文动画方案，并强调独立开关、开即应用、关闭恢复正常，以及「原来的功能不要动」。用户本轮明确说「推送」，已授权本候选 commit/push 并运行 GitHub CI、下载验包。首次 CI run 158/42599014312 已失败：`LCSAAnimationSupport.h:141` 使用了 iOS 15.5 SDK 不声明的 `+[NSHashTable strongObjectsHashTable]`；已改为 `hashTableWithOptions:NSPointerFunctionsStrongMemory`，本地检查重新通过。未授权安装、注销、重启或修改设备配置。

## 精确基线
- 原功能：HGFdel-dav/theos-ci cleanstatus-0.2.5，4301746eba66244b1a869e7f53650184e6fca10b。
- 新动画：ba31k/ios26-27-anims v1.5.2，8c3159717f8cb692dc017556a99bde3fa8cabaf0；保留原作者署名。
- 工作目录：/var/minis/shared/CleanStatus-animation-0.3.0/source。
- 原始基线解出在 ../research/baseline-0.2.5；保护哈希和原设置行见 docs/BASELINE-0.2.5-PROTECTED.json。
- 31 个原有 .h/.m/.xm 全部逐字节一致；原设置24项内容及顺序一致，末尾仅新增动画分组/链接。

## 已实现
- 同包第二个独立 dylib LocalCleanStatusAnimations，仅注入 SpringBoard；原 LocalCleanStatus 源列表及旧功能实现保持。
- 动画独立配置 com.local.cleanstatus.animations.plist，隐根按插件/框架标记排名、mtime 选择一次并缓存；只迁移同名动画文件。
- 独立动画总开关默认关闭；原插件总开关不影响动画开关。中文基础/高级页面共8开关、6实数滑条，150ms合并自动保存；跨子页保留待写值；保存失败可重试。
- 应用开合/神灯/通知中心图标可分别选；透明通知中心、水滴、回弹、模糊、速度及慢放在高级页。
- 关闭、减弱动态效果、取消路径恢复本模块记录的弹簧/滤镜/图层原值，清理网格和Dock自身令牌；代数丢弃旧完成回调。
- 私有方法逐组核对参数/返回类型后安装；能力缺失时对应控件禁用并说明。显示帧只读内存快照，不读取配置文件。

## 本地检查结果
- 旧核心：5,252,881；控制中心策略：658；源不变量：354。
- 旧路径模型37例、Mach-O核验器46个正反例通过。
- 新动画开关/减弱动态效果真值表、数值边界、结构体类型正反例、神灯连续反向及收敛数学测试通过。
- 46个源码文件字符串注释外括号检查通过。
- Logos预处理成功且无stderr。仅是源码转换，不是Objective-C++编译或链接。
- 原31份源码/24项设置保护检查通过。Git推送工作树未动。

## 仍未验证
- 无精确15.5私有框架样本；15.0/15.6公开声明只作接口证据，不能当真机保证。
- 未执行iOS编译/CI、DEB验包、安装加载、视觉效果或开关保存到最终画面的真机验证。
- Timer Block内部调用签名、phase/direction含义、通知中心反向/取消时序、神灯网格、第三方动画/图标插件共存、原功能回归均需真机验收。
- 原Wi-Fi/蓝牙/电池等此前未验项目保留原状态，本轮不宣称修复。个人热点灰色问题也未做设备对照诊断。

下一步：提交具体候选请用户单独确认推送，获准后才触发GitHub CI。安装、注销、重启分别另问。
