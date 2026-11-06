# ParallelX clone0.8 本地修复状态

## 范围与当前授权
- 2026-11-06 用户明确「参考 ScreenCore，然后修复一下」，授权本地参考分析、改码与静态检查。
- 用户在本轮后续消息已明确批准本候选的 commit/push 与 GitHub CI；安装、卸载、设备配置修改、注销/重启仍未授权。
- 项目仍为合并的 `com.moxuan.parallelx`，不另加独立插件，不硬依赖 ScreenCore 或 Crane。
- iPhone 12/A14/iOS15.5/RootHide/arm64e，SDK 固定15.5，iOS 编译仅在获推送批准后的 GitHub macOS CI。

## 基线
- 基线仓库 `/tmp/ci-work`，HEAD `2ddd311a9edd5616498a26829bb2bc12948ee262`（已交付 clone0.7）。
- 本地隔离候选 `/var/minis/shared/ParallelX-clone0.8-local-20261106`，从上述 commit `debs/ParallelX` 精确 archive，无 .git。
- 原版 alpha391 dylib SHA256 `b1f4bd28bb6c6936be2b059140f1af38f4da25bb2eeb5c2380b9d0bf2a3c2ce6`，禁止修改 vendor。
- `/root/parallelx-safe-mode-20261104` 为断链 worktree；不用它 commit/push。旧 SAFE-MODE-STATUS 只作历史，不当本轮状态。
- workflow CLI `/var/minis/workspace/bin/tweak` 当前不存在，依据已加载 tweak-workflow 技能手动守阶段与授权闸门，不启动本机 Theos。

## 验收要求
1. 打开账号A必须分屏。
2. A窗口仍在时点B，无需用户划掉A，自动切到B并分屏。
3. 再点A自动返回A，仍分屏。
4. 多次 A→B→A，及新增账号C均同规则；不全屏、不静默吞点击、不要求手动清窗。
5. 新增容器应自动发现，无需重启 SpringBoard；不清掉用户隐藏设置或非本插件动作。
6. 普通应用、原版窗口引擎、偏好路径与既有菜单排序不被本修复改写。

## 已确认的基线缺陷（非本轮真机根因穷举）
- 自定义账号点击截获后调用 `+externalOpenApplication:`，尚需对照原生菜单分屏路线。
- 切容器后直接 `reloadApplicationWithIdentifier:`，没有显式释放旧PX窗口/场景和确认旧PID退出。
- PXClonePolicy 的 settling 分支在3秒截止时仍成功，旧测试还强制接受它。
- 同容器分支在取消旧事务之前就直接打开，快速 A→B→A 有迟到事务覆盖风险。
- 目录同步目前只有 bootstrap/偏好通知，新增容器未获单独触发。

## 阶段
`local_checks_complete_waiting_push_approval`：隔离候选已升 `0.1.0~alpha391+clone0.8`。详细更改、证据地址、纠错和未验证项见 `LOCAL-RESULT.md`。

- ScreenCore 2.0.5参考包关闭→终止/真实退出→切容器→分屏的顺序已用调用点复核，未搬入其窗口引擎。
- alpha391 +externalOpenApplication是完整原生分屏builder，已追到0x35ed4传真实view/overlay/BOOL completion，前面把该接口直接说成全屏入口的判断已纠正。
- 切换逻辑改为统一串行控制器、正常认证reload:NO、自动清目标bundle当前/停靠旧窗、旧进程退出核验、active回读、原生completion与实际可见host联合确认。
- 快速点击latest-target、迟到/重复completion、认证超时隔离、错误提示、有限隐根诊断和新增容器/菜单展开后台刷新已实现。
- 旧宽限成功分支与0.8s全局去重已去掉；旧直接切容器+reload接口已删除。

## 检查状态
- `tools/validate.py` 全过：103项host测试；85,040条生产C阶段门禁断言；原版DEB哈希与vendor16文件逐字节；plists；两scheme维护脚本/control；结构和unused守卫。
- 所有测试是本地主机策略/模型/源码约束，未执行ObjC私有服务。
- 本机tree-sitter ObjC纯语法解析器崩溃，不能列为语法/类型检查通过。未做本机iOS编译。
- CI/机器码构建/DEB核验：未执行。
- 安装加载/真机 A→B→A：未执行。
- 只读设备读取当前libcrane做签名核验；未改设备文件/偏好/安装状态，未自动操作应用。
- 真实系统服务权限/ABI、异步清场/冷启动、可见画面与账号正确性仍待CI+真机分阶段验收。

## 当前阶段
已获用户在当前阶段批准 clone0.8 commit/push + GitHub CI。推送前再次核对远端并发改动，采用快进，不强推。构建失败只修报错位置；CI结束停在安装前，未获当前单独授权不安装/注销/重启。

## 回滚
clone0.7 交付目录 `/var/minis/shared/ParallelX-clone0.7-20261106/` 保留未修改。本轮隔离源码未触碰已交付包和设备。
