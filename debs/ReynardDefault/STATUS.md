# ReynardDefault 1.5.48 纯插件候选

**状态：CI verify 与双架构构建成功，DEB 静态验包通过；未安装、未注销/重启、未真机验收。**

## 范围

一个原生 DEB。无 XPI、无 Helper 注入、无脚本资源。保留 Safari→Reynard、设置面板、控制中心。

## 实现

- `GeckoView:OnPreNavigation` / `OnLoadRequest`：只处理顶层、前台、真实用户手势的 HTTP(S)，排除同文档锚点；先尝试系统 Universal Link，失败回答 false，让同一原导航继续。已有 1.5.44 实现。
- `ContentParent::RecvLoadURIExternal`：只处理顶层上下文、前台、`userGesture`、非外部触发、非内部 scheme 的自定义链接；按已确认入口指纹（XUL UUID + `RecvLoadURIExternal`/`GetParent` 指令）安装；成功后以系统 openURL 结果判断是否吞掉原外部请求，失败交给原处理器。
- 移除 Helper 注入、CFPreferences 单槽、Darwin 通知和 XUL `OnLinkClick`。`RDExternalLink.h` 只在主 App 安装外部协议钩子。
- `FINALPACKAGE=1`，arm64e（RootHide）与 arm64（rootless）双架构。

## 已通过

- CI run 43277426646：verify、arm64e、arm64 全部 success。
- 主机规则 20,686 项、O0/O2 策略、arm64e 非 PAC 汇编、保护文件、plist、图标、无扩展载荷：通过。
- 双包 control/版本/架构正确；16 个载荷；无维护脚本；过滤器仅 SpringBoard + Reynard。
- 三 Mach-O 架构正确；代码签名 22/22 页、双哈希槽全通过。
- SHA256：
  - arm64e `7f1da4fd5d44d553d60e6fe3e515adfbefb18592ef0314358c7c101d9776c994`
  - arm64 `ec1dbb4a9eccc770c5cf85bc871c9c2e4914492aeadba00d5e04c880e40f0089`

## 未验证 / 风险

- 尚无设备安装、加载和功能验收；静态/CI 不等于能用。
- 自定义链接只在主 App 外部协议入口打开；系统拒绝时原页面保留，但异步 IPC 无法把失败回传子进程，原链接不会自动再次导航。
- 自定义链接依赖 Reynard 0.21.0 / Firefox160 XUL 指纹；版本不符时该钩子整体拒绝，网页路由仍工作。
- 若外部协议流程本身弹出“允许打开 App”选择页，插件不会跳过该页；按原系统选择结果处理。
- 需重启 Reynard 进程加载新 dylib。

## 1.5.48 现场诊断

- 1.5.46 已实装且过滤器正确、进程装后重启，但用户报告无效果；发布包剥离日志导致无法取证。
- 1.5.48 保留 NSLog；启动即记录 boot/pid；先安装外部协议钩子，派发类最多延迟 10 秒重试，不再因类未加载直接退出。
