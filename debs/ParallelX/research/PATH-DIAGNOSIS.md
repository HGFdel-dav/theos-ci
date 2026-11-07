# PATH-DIAGNOSIS — 阶段摘要（只读调查，2026-11-07）

范围：`ParallelX-clone0.9-local-20261107` 的路径解析与诊断落盘；只允许写本报告，不修改源码、配置、设备或用户文件，不构建/CI/push/安装/注销/重启，不读取凭据或全量 defaults。

1. 已核验静态事实：`Common/PXClonePaths.m:60–68` 仅用 `PXCloneJBROOT(@"/")` → `realpath` → `PXCloneValidateRoot`；无候选扫描、无缓存、无失败回退。`PXRootHideCompat.h:10–19` 直接调用官方 NSString `jbroot/rootfs`，`jbrand()` 只返回环境判断。
2. `PXClonePaths.m:34–57` 要求目录 canonical，最后名有 `.jbroot-` 前缀；`/` 明确拒绝。因此 **若** official root 在对应进程解析成 `/`，现实现必然失败，但尚未获得 SpringBoard 内 actual `jbroot/realpath` 值，不能把条件缺陷写成已证实真机根因。
3. `PXCloneEnsureStorage:88–118` 先 mkdir，再验证 canonical Preferences 位于 root 前缀、W_OK、O_NOFOLLOW 创建锁。路径 alias/跨根 symlink 可能导致前缀验证失败；权限与 I/O 也可能导致失败，待进一步逐项核验。
4. 用户提供的既有 MCP 证据：`/var/mobile/Library/Preferences` 指向 `/rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-43DBE0287D183F0A/var/mobile/Library/Preferences`；Bundle/Application 同名 `.jbroot-*` 是指向 `//` 的 alias；AppGroup 实体目录存在。UUID 仅作当前证据，绝不作为修复常量。此前 glob/find 与 privileged list_dir 均未找到本插件诊断文件，不能宣称日志存在。
5. 下一阶段仅补充相关 metadata、symlink、官方头定义/调用链与静默错误路径；建议将唯一写域限定为动态选定的 AppGroup 隐根 Preferences，统一面板/tweak 解析接口，并将路径/errno 错误输出到独立非文件诊断通道。不在设备创建测试文件；不重做全量 plist 迁移。

本文件仍为阶段摘要；最终报告将补充可复核 metadata、源码行号、最小改动点和负例，并保持不超过八条结论。
