# clone0.9 独立审查（初步风险，待 host 检查后更新）

范围：`/var/minis/shared/ParallelX-clone0.9-local-20261107` 当前完整源码；基线为发布 `9c9db4b` clone0.8。仅审读源码/audit，报告以外不改项目文件；不读密钥，不执行 iOS compiler/Theos、push/CI、安装、注销、重启或设备命令。

## 已确认的优先风险

1. **high — 缓存后的 Trace 父目录失去 containment 保护。** `Common/PXCloneTrace.m:63–80` 仅第一次初始化 `tracePath` 时调用 `PXCloneEnsureStorage`，此后 `:85–118` 只 lstat 文件本身，原子写/chmod/读回仍使用字符串路径。触发：首次成功后，所选 root、Library 或 Preferences 被改为指向另一个隐根或真实 var 的 symlink。目标可以缺失或为普通文件，叶子 lstat 不能检测父目录重定向，因此后续写入可能越过所选根。最小修正：缓存 discovery 结果而非永久信任路径；每次 I/O 检查 root canonical + dev/ino、parent containment，失效时 fail closed，不重扫/自动切根。若需防校验与写入之间的竞争，固定安全目录 fd，使用 openat/fstatat/renameat，chmod 在新文件 fd 上完成后才提交。

2. **high（条件风险）— 新 root discovery 与旧 CFPreferences 迁移删除可能误删当前域文件。** `Common/PXClonePrefs.m:339–343,382–388` 把 `PXCloneCurrentPrefsPath` 当成唯一 ownPath，删除仅按字符串排除；`Common/PXClonePaths.m:213–249` 还把 rootfs 真实域与其他 AppGroup/Bundle alias 的域文件加入 sources。触发：fallback 选中 A（例如 marker 排名较高的旧根），而当前 `/var/mobile/Library/Preferences`/cfprefsd 使用 B，且 CXStore 暂无、进入 migration；B 被枚举为 legacy。文件写入后只有 mtime/size 比较；若同一大小/时间粒度、或 B 的指纹取不到而后续文件出现，B 仍可能被删除。CFPreferences 回读是域缓存，不是落盘文件确认。本轮 prefs source 未改，但其 path 调用语义已变化。最小稳妥防护：本轮禁用 legacy 源删除，保持 copy-only import；如以后保留 cleanup，至少按真实 domain destination 的 canonical/dev/ino 排除、要求完整稳定指纹和源格式/内容验证，并确保 unlink 目标仍为所审核 inode。

## 暂时未见回调开放回归

`PXCloneCrane.m:202–211` 主线程 once 转发真实 BOOL；`PXCloneFlow.h:49–52` NO/YES 均只进入 Verifying；`PXCloneLaunch.m:400–452` active 匹配后才开窗，无回调则 Authenticating → Quarantined，没有轮询 active 直接开放。重复/旧令牌与原 native completion 的进一步检查、SDK/ARC 静态审查和 host 测试尚待完成。

本初步报告不是 ObjC 编译或真机验证结论。
