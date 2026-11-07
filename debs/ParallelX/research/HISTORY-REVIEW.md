# ParallelX 历史语义核查

状态：取证中（2026-11-07）。本文件先落盘，随后仅更新本研究报告；不修改产品源码、设备、配置，不执行推送、CI、安装、注销或重启。

## 判定基准

主会话已确认当前设备 libcrane 的 `setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:usingBiometricsIfNeededWithSuccessHandler:`：无需生物认证分支在执行真正的 `setActive(...reload:)` 后仍回调 `NO`；认证分支回调 `YES`。clone0.8 的 `ok && active == target` 因而把实际切换成功的 `NO` 判为失败。本报告只核对此前是否已遇到或修过**这一返回值语义/成功判据问题**。当前二进制结论为主会话提供，非本报告独立复验。

## 当前阶段结论

已找到旧源码可直接对照：旧 `reference/clone0.9/pxclone/CXCraneBridge.m:262–268` 与旧 `reference/clone1.11/pxclone/CXCraneBridge.m:266–272` 的认证兜底**仍使用 `success && active == target`**，且调用的是不带 `reloadApplication:` 的另一个认证 selector。两版首选无认证 `void` selector 并只看回读（0.9:222–244；1.11:224–252）。因此旧版普通路径可避开 raw BOOL，但不能据此声称当时已修当前认证 `NO` 语义。

`CLONE018-FIXES.md:9,19,22–24` 明确描述的是 `reload:NO` 后配置容器已变、运行进程仍同账号的旧问题；`CLONE111-FIXES.md:3–17` 是选择器/异步 completion 生命周期与旧 PID 退出问题，均不是当前 raw BOOL 判错的直接证据。正在核对原始会话日期与旧 commit 来源，特别追查 2026-10-30“回读即成功”的记录是否涉及认证 callback，尚不下同根因结论。

## 取证范围

只读检查 `/tmp/ci-work` 现存 Git 对象、`/var/minis/shared` 的 ParallelX 历史工程/文档及 2026-10—11 月历史会话。记忆未自动注入且记忆工具禁用；如读取用户指定的日记文件，将仅按本问题关键词定位片段，不读全量或凭据。会话仅用查询子命令。报告将给出日期、路径/行号、commit/session 和引文范围，并区分已确认/证据不足。
