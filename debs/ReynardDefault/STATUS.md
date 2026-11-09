# ReynardDefault 1.5.34

阶段：本地修复和主机测试通过；用户于本轮明确授权继续修复并推送编译。未授权安装、注销、重启或修改设备配置。

## 目标

- 不重编 Reynard App；不改控制中心图标/文字或 Safari→Reynard 旧行为。
- 只有用户点击后外跳，完整保留目标地址及参数；普通网页失败时继续原请求。
- 桌面网页已由用户确认点击能进入 moonup 群；移动网页仍是链接界面。两者分别返回 `tg://resolve` 与 `tg:resolve`；本候选补兼容已知 tg action 并保留后续字节，不对 mailto/tel 等通用补斜杠。

## 已确认缺陷与修复

- 基线 31ba57f3fe5bc3015f881b8072a611c788c9d7ab / 1.5.33 的桥构造 `#h=...#a=...` 与宿主 `&` 拆分不符，已用真实脚本重现参数丢失。
- 移动站点及日志实际为 `tg:resolve?domain=moonup_chat`，原 host==resolve 分支不匹配。已按具体协议动作归一化；其他协议不改写。
- 原 OnVisited、OnLoadError、任意扩展消息会外跳，已取消；仅请求事件和真实手势准入。程序生成点击、后台、加载/刷新不触发。
- 原脚本把任意 http(s) 点击替换为当前页 meta App 链接。已去掉：HTTP(S)沿原导航仅试系统通用链接，失败回 false；自定义链接只携带真实点击 href。
- 移除伪造扩展数据库、关闭签名检查、广播安装、自动刷新、RD标题探针等试验逻辑，保留正式签名安装接口。安装确认由 Reynard 本身处理。
- 签名后扩展 event page 只在更新/安装后向现有网页装监听，不主动导航；是否覆盖实际标签页仍待真机。

## 已完成的验证

- 41 个真实脚本夹具，10 个后台脚本断言。
- C 生产解析和门禁 92 断言（-O0/-O2）；259 编码/解码往返每配置通过。
- 20 个旧功能保护文件哈希不变，6 个 plist 可读，图标原测试通过。
- AMO 1.9（file 5228634）正式签名，0错误/0警告/0notice；XPI SHA256 `0f1d7e4beb4e22ab93b16c611d3af819fc4b8de478edc9e078adb11952a1f131`。源码、签名包和内嵌字节一致；旧签名包混入会被构建门禁拒绝。

## 未验证／限制

- 尚无本版 iOS 编译、验包或真机验收。主机测试不证明手机运行。
- 系统已经接收的 UIApplication 打开请求不能主动撤销；超时只保证插件不再重复响应/追加外跳。
- Android intent、延时脚本自造跳转、系统限制页面和具体第三方 App 的内容路由不能承诺全部支持。不会声称与 Safari 所有行为完全相同。
- 本版不回写修复旧版曾伪造的其他扩展数据库字段；正式安装会让引擎更新本扩展记录。没有执行设备清理。
- 升级必须重新启动 Reynard 进程以加载新 dylib；不强制双次冷启动，不自动操作设备。

## 研究依据

上游 Reynard 源码 8ded3486821e6c922b5f2985274aefdc86752344：EventDispatcher.swift、NavigationDelegate.swift、LoadURIDelegateChild.sys.mjs.patch、AddonRuntimeCommands.swift、AddonRuntimeEvents.swift、AddonCoordinator.swift。
已存实装 0.20.1 的 ObjC 方法核验：dispatchToSwift v40@0:8@16@24@32；attach v24@0:8@16。
MDN tabs.executeScript/runtime.onInstalled：只在升级后向已打开文档补监听，不导航。
