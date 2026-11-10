# ReynardDefault 1.5.37

阶段：用户已明确要求只用一个插件，并允许本地修复与日志；当前版本加入 GeckoView 与原生点击入口诊断，完成本地门禁后等待本轮推送批准。未安装、未注销、未重启。

## 本轮候选事实

- 已移除旧 XUL/未验证 PAC 路径、扩展安装代码、扩展 payload 和相关过期测试。
- 新增路由入口诊断：仅记录事件类型、scheme、hasUserGesture、topLevel、flags、准入结果；不记录完整 URL、query 或 token。
- 设备旧日志有真实用户点击 `OnPreNavigation` 样本 `hasUserGesture=1, flags=8388608`；历史门禁曾把 `0x800000` 当 redirect 拒绝，已移除该猜测判定。
- 仍保留已核实的 GeckoView 请求路由；同时加入基线 UUID/prologue 防护的 `nsDocShell::OnLinkClick` native hook，专门覆盖 GeckoView 未转发的自定义协议点击。
- 本地门禁：O0/O2 native policy 20 assertions、C++ policy 编译、20 个保护文件、6 个 plist、图标及无扩展残留均通过。
- **CI 编译、DEB 静态验包、真机加载/功能仍未验证。**

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

- 本版 iOS 双架构编译与静态验包已完成；仍未安装、未真机验收。主机测试不证明手机运行。
- 最终 commit `27cc0e99a7b428f181e823f6035d094d267df9a0`，独立分支 `reynarddefault-1.5.34-click-fix`，CI `42623663356` 的 verify 与双 build 全 success；原生 Foundation 路由集成测试50项通过。
- 首轮 `42622580510` 在原生测试编译发现 memchr 需显式指针转换，已修并补 C++ 预检；该轮没有包，不计功能通过。
- 交付 `attachments/ReynardDefault-1.5.34`，长期 `shared/ReynardDefault-releases/1.5.34`，双DEB/Source.zip/报告/哈希；CI精确源码包保留推送时STATUS，不伪造未来状态。
- RootHide DEB 102980B SHA256 `f7db7f291a0f9e539e43202266915ec1c1b24adaa59502c67ff969cb206773b5`；rootless 102740B `2cf1433acd3bf80875985f5ba6f5c1f77acdb63f255e73c47a4ee84819a5430e`；Source.zip `6da06d2e17dacf1447261b15115783cf1a5ad71b2368705cd26b20717d75817b`。
- 每包20文件、3 Mach-O；SDK15.5/minOS14.0；两包全部 CodeDirectory SHA1/SHA256 页校验通过；无维护脚本。dSYM/完整CI日志已存长期交付目录。
- 未安装/注销/重启、未改设备配置。临时OCR提取的签名凭据文件已删除，没有把凭据加入源码或交付目录。
- 系统已经接收的 UIApplication 打开请求不能主动撤销；超时只保证插件不再重复响应/追加外跳。
- Android intent、延时脚本自造跳转、系统限制页面和具体第三方 App 的内容路由不能承诺全部支持。不会声称与 Safari 所有行为完全相同。
- 本版不回写修复旧版曾伪造的其他扩展数据库字段；正式安装会让引擎更新本扩展记录。没有执行设备清理。
- 升级必须重新启动 Reynard 进程以加载新 dylib；不强制双次冷启动，不自动操作设备。

## 研究依据

上游 Reynard 源码 8ded3486821e6c922b5f2985274aefdc86752344：EventDispatcher.swift、NavigationDelegate.swift、LoadURIDelegateChild.sys.mjs.patch、AddonRuntimeCommands.swift、AddonRuntimeEvents.swift、AddonCoordinator.swift。
已存实装 0.20.1 的 ObjC 方法核验：dispatchToSwift v40@0:8@16@24@32；attach v24@0:8@16。
MDN tabs.executeScript/runtime.onInstalled：只在升级后向已打开文档补监听，不导航。
