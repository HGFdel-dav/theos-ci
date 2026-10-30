# ParticleX — 0.1.0dev1

作者：Niubiprass。目标 iPhone12/A14，iOS15.5，RootHide。只注入 SpringBoard。

## 已确认的需求
- 清除通知：对实际被移除的可见通知生成原色沙粒消散动画。
- 移除桌面小组件：对被移除的那个小组件生成原色沙粒消散动画。
- 控制中心：原生亮度、音量滑条内部出现随操作流动的细粒子。绝不增加悬浮条、放大镜或改变控制中心布局。
- 本地写源码，GitHub CI 编译；不在手机/iSH 编译，不自动安装、注销、重启。

## 设计约束
- 原系统删除、亮度与音量操作只交还原方法一次；不重放、不延迟通知语义，不替换系统数值控制器。
- 精确类/selector Hook，核对 iOS15.5 头文件，运行时按返回/参数编码预检，失败跳过并记录。禁止全局 UIView 移除 Hook。
- 消散只用视图局部快照，内存内 Metal 原色纹理，不写截图/通知内容到磁盘；GPU 单 draw 实例化网格，限制并发和存活时间。
- 控制中心用触摸透传、裁切在控件内部的点粒子层，不改动原滑条的响应链或值。
- Reduce Motion 时停用动画，后台/锁屏相关生命周期清理；无后台常驻循环。
- 真实 PSListController 面板，共用 RootHide jbroot 路径头，Darwin 通知更新开关。禁用开关运行时生效。
- 现有 shared/theos-ci 工程有用户脏改动，本工程隔离在 workspace/ParticleX。

## 前置证据
- 已只读 MCP 确认 iPhone13,2 / iOS15.5，RootHide manager1.4.0，ElleKit1.2-3。
- 本机无 Theos/15.5 SDK，不安装手机工具链；用户选择 GitHub CI。
- 已查阅 roothide/Developer、roothide/theos、opa334/Dopamine 2.x、tealbathingsuit/ellekit。
- 控件/通知/小组件精确接口调研产物单独保存到 reference/。

## 交付门槛
1. 纯 C 数学/限额测试、plist与工程源码守卫。
2. GitHub macOS 编译 SDK15.5：roothide + rootless。
3. 每包 dpkg-deb -e/-c，核对载荷/脚本/版本/架构，Mach-O 与签名哈希校验。
4. DEB + 完整干净 Source.zip + SHA256SUMS 下载链接。
5. 编译成功不代表手机效果验收；安装与实际手势测试需用户亲自进行或另外授权。
