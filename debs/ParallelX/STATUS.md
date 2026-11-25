# ParallelX alpha455 + clone0.110｜建窗即记忆尺寸（本地候选）

## 本轮授权
用户本轮明确批准推送、监控CI至结束及DEB/源码独立验包；编译失败时修复后继续推送再监控。不包含设备操作、安装、注销或重启。

阶段：`push_and_ci_authorized`。本地检查已完成；最终CI与验包结果以项目上层`release/STATUS.md`为准。

## 方案依据（本轮只读核实）
- 苏苏 ScreenCore 的“记住大小与位置”之所以开窗即正确，是因为窗口由它自己创建，尺寸在窗口存在前已定。
- ParallelX 的窗口卡片 `PXHostCard` 只有一个创建入口 `initWithFrame:`，参数就是默认尺寸；本轮已反汇编核实 `layoutHost` 只按内容比例缩放卡片内部，不重设卡片本身宽高。
- 因此在 `initWithFrame:` 把默认参数换成记忆尺寸，是最早、且此后无人覆盖的设定点。

## 生产改动（2 个文件）
`Common/PXWindowMemoryPolicy.h`
- 新增 `PXWMInitialCardFrameUsable`：仅当“恰好一个待开窗 + 有记录 + 记录参考尺寸与当前屏幕一致（±1pt）”时才允许在建窗时套用；否则交回原有事后路径，不猜。

`Common/PXWindowMemory.m`
- 新增 `PXWMPendingInitialCardContext`：只在恰好一个未领卡片的首开上下文时返回它，多个待开窗一律放弃（不猜归属）。
- 新增 `PXWMInitialCardSavedFrame`：从现有存储读取该 App 的记忆框，要求参考尺寸与当前屏幕一致（±1pt）；记录本身无效（`PXWMValidRect`）则不用。
- 新增 hook `PXWMCardInit(initWithFrame:)`：命中条件时把默认参数换成记忆尺寸，并记录 `initialNativeFrame`（原默认）、`initialTarget`、`resolved=YES`、`initialTargetActive=YES`、2 秒期限——与原有“事后替换”共用同一套字段；之后若作者代码再写回默认尺寸，现有 `PXWMCardSetFrame` 替换逻辑仍会兜底。
- 安装处：`initWithFrame:` 钩子按“存在且签名匹配”才安装，属可选项；失败不影响其余功能（回退原路径）。
- 诊断：新增 `first_frame_memory_applied_at_init`（含默认/目标宽高、方向键、revision）；`hook_status` 增加 `cardInitReady`。

未改：记忆格式/路径/schema、保存规则、方向隔离、分身/付款、停靠/贴边、作者 vendor 与设置面板。不隐藏窗口、不延时、不猜尺寸。

## 本地检查
- `python3 -m unittest discover -s tests -p 'test_*.py'`：**198 项，181 实跑通过、17 项 Apple runtime 跳过**。
- 真值表 harness 扩充：`PXWMInitialCardFrameUsable` 10 条定向 + 61 组边界穷举（±1pt 容差逐 0.1 扫描）；原有首开资格 15+768 组仍全过。
- 新增源码守卫 `test_card_creation_receives_remembered_frame`：钉住钩子安装、恰好一个待开窗、参考尺寸校验、原调用必被转发、**不得隐藏窗口**（断言无 `alpha=0`/`setHidden:YES`）。
- `tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`。

## 风险与未验证
- 未做完整 Apple SDK 编译/链接/签名、未出 DEB、未安装、未真机；**“首次可见即记忆尺寸”仍未证明**。
- 若作者在 `initWithFrame:` 之外还有别的卡片创建路径（如复用池预热），本轮钩子不覆盖，届时走原事后路径并留日志。
- 方向/设备变化导致参考尺寸不一致时，建窗期不套用（按设计交回事后路径）。
- 若卡片创建早于开窗上下文建立（池预热），首开上下文为空 → 不套用，无副作用。

## 证据
`evidence/01-VALIDATE.log`、`evidence/02-VALIDATE-PINNED.log`、`evidence/03-UNIT.log`；109 及更早证据保留。