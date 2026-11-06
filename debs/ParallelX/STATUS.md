# ParallelX clone0.9 本地修复状态
## 当前授权与基线
- 用户2026-11-07明确「现在继续修复吧」：授权历史对照、本地修正与检查。
- **未授权本轮 commit/push/CI、安装/卸载、设备配置修改、注销/重启**；clone0.8旧推送授权不延续。
- 从已发布提交 `9c9db4b764c67127995f018089f2ef801443892c:debs/ParallelX` 精确archive到 `/var/minis/shared/ParallelX-clone0.9-local-20261107`，隔离候选无.git。
- `/tmp/ci-work`保持上述commit且clean，不同步/commit/push本轮更改。
- 合并包`com.moxuan.parallelx`，只注入SpringBoard与原有Preferences面板；iPhone12/A14/iOS15.5/RootHide/arm64e，SDK15.5，iOS机器码仅获授权后的GitHub CI。

## 上版事实与已知回归
- clone0.8 CI #10/42254647548双scheme成功并已交付；用户自行安装。只读dpkg确认当前clone0.8，用户报告默认可开、非默认打不开。
- 默认能开不代表整条分屏或A→B→A验收通过。
- 真实libcrane arm64e `0x84d4`：无需生物认证分支在`0x86a4`先setActiveContainer(...reload:)，再于`0x86b8/0x86bc`回调NO；认证路径才YES。clone0.8 `ok && active==target`把正常NO误判失败且不回读。
- 旧clone0.9/clone1.11认证兜底已有同样`success && active==target`。主路径通常走无callback的接口，不能把旧版成功当认证分支验证通过。原始历史同故障是否已修仍按研究证据确认，不编造。
- 受保护目录list_dir和run_command均没找到launch-trace。旧record忽略解析/写入错误；不把日志缺失直接当成某一条路径错误已证实。

## 本轮最小修复目标
1. 保留Crane原认证、reload:NO；真实NO/YES只表示回调到达，两者都进有界active回读，只有target一致才允许原生分屏打开。
2. 回调未达、取消/超时、回读空/错账号、旧令牌/重复回调不得开窗或并发认证；保留旧进程退出、最新目标、A→B→A和新增C门禁。
3. 唯一隐根路径解析共用且缓存；补路径解析失败回退、日志原子写+读回与可见失败反馈，不写真实var，不覆写CXStore、不重新搬迁用户配置。
4. 将真实libcrane NO分支做成固定证据fixture和生产C测试，避免再让错误模型测试全绿。
5. 原版vendor、普通应用开窗、菜单UI、账号隐藏开关与既有偏好存储不重写。

## 当前阶段
`local_checks_complete_waiting_push_approval`：回调真因与诊断隐根修复已完成本地检查，详细结果/证据见`LOCAL-RESULT.md`。

- 不再用raw BOOL当成功；真实NO/YES都进Verifying，active回读、可见后才开。
- 新增Crane原字形成fixture+生产测试，root/containment也是C生产头，既不再测假模型。
- Path与Trace完整检已改；114 host与三套C全过。仍需CI与真机。

## 检查状态
- 114项host；85068条Flow；916条root；29条真实文件I/O，全部通过。
- baseline DEB精确hash、vendor16文件逐字节、plists、两scheme维护脚本/control、结构/unused/版本门禁过。
- 均为host，无ObjC编译、CI、DEB、真机；tree-sitter ObjC仍Segfault，不计语法检。
- 只读原设备libcrane/Preferences meta；未改设备文件、配置或安装。
- 潜在残余：SpringBoard真实jbroot/realpath未采样，父目录竞态非无锁全覆盖，Crane认证权限/取消待真机；最后分身删空仍不删行。

## 下一闸门
等用户当前阶段批准clone0.9 commit/push+GitHub CI。未获批准不commit/push；编译失败只修报错，不自动安装/注销。

## 回滚
clone0.7、clone0.8交付目录与设备现状保持不动；本候选可从9c9db4b回归。
