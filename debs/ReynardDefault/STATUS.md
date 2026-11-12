# ReynardDefault 1.5.54 纯插件候选

**状态：1.5.54 本地门禁通过；未推送、未 CI 构建、未安装、未真机验收。**

## 范围

一个原生 DEB。无 XPI、无 Helper 注入、无脚本资源。保留 Safari→Reynard、设置面板、控制中心。

## 实现

- Reynard 主进程只处理非网页 scheme：`http(s)` 导航一律留在浏览器，GitHub 等普通网页不再被 App 接管。
- 自定义 scheme（`tg:`、`mailto:`、`weixin:` 等）由主进程 Firefox160 `ContentParent::RecvLoadURIExternal` 钩子接管；参数按 `{id, context*}` 解包、拒绝空/已丢弃对象，再判断是否顶层。
- 仅 Reynard 主进程注入；不注入 Helper、不含扩展、XPI、共享偏好中继或内容脚本。
- 诊断记录写入应用自己的 `NSHomeDirectory()/tmp/rdboot-1.5.54.txt`。
- `FINALPACKAGE=1`，RootHide arm64e 与 rootless arm64。

## 本地验证（1.5.54）

- `tests/run_checks.py` 通过：策略 O0/O2、31 项点击/上下文断言、协议逻辑 20,686 项、保护哈希、plist、图标、纯插件断言。
- 1.5.48 的 CI 曾通过，但其上下文指针解包错误，不能作为可用版。
- 1.5.54 尚未推送、CI 编译、DEB 验包或设备安装。

## 未验证 / 风险

- 未验证 1.5.54 运行行为；不把本地静态检查等同功能成功。
- 外部协议失败时回交 Firefox 原协议处理器；该 iOS handler 可能不支持。未真机验证失败页/原页面表现。
- 依赖 Reynard 0.21.0 / Firefox160 XUL UUID 与函数指纹，版本变动时钩子应拒绝安装。
- 需要安装后重启 Reynard 进程，尚未操作设备。
