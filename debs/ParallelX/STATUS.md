# ParallelX alpha455 + clone0.111｜绑定时即套用记忆尺寸（本地候选）

## 本轮授权
用户本轮明确批准推送、监控CI至结束及DEB/源码独立验包；编译失败时修复后继续推送再监控。不包含设备操作、安装、注销或重启。

阶段：`push_and_ci_authorized`。最终CI与验包结果以项目上层`release/STATUS.md`为准。

## 依据（上一轮真机只读）
- 实装 110：`cardInitReady=1`，但 **0 条**“建窗时套用”记录（15 次开窗）→ 卡片不是每次开窗新建，`initWithFrame:` 不是每次开窗的事件。110 的前提不成立。
- 同一份日志的真实时序：绑定后 1–3 ms 就到 `gate=3`；+215–315 ms 才准备；+270–372 ms 才替换，且 `windowHidden=false`；作者自己写默认尺寸约在 +400 ms。
- 因此改为：**在绑定成功时**（canvas/bundle 仍精确匹配、窗口尚未显示）直接给卡片套记忆尺寸。

## 生产改动（1 个文件）
`Common/PXWindowMemory.m`
- 绑定成功分支：先按 canvas 找卡片，找不到再用 bridge 的 `hostView` 向上找；两者都没有时记一条 `first_frame_bind_no_card`（每开窗一次）。
- 命中记忆记录（现有 `PXWMInitialCardSavedFrame`：参考尺寸与当前屏幕一致 ±1pt）时：`restoring=YES` 保护下 `performWithoutAnimation` 设卡片 frame、`setNeedsLayout`/`layoutIfNeeded`，再置 `initialTargetActive`、`resolved`、`initialTargetAppliedAtBind`、2 秒期限；记录 `first_frame_memory_applied_at_bind`。
- `PXWMCardSetFrame` 的替换条件改为 `!same && (sameNative || initialTargetAppliedAtBind)`：作者随后写回默认尺寸时，在同一帧改回记忆尺寸；用户拖动/缩放（`interacting`）或取消则不再插手。
- 新增属性 `initialTargetAppliedAtBind`，仅本路径置位，其它路径行为不变。

未改：记忆格式/路径/schema、保存规则、方向隔离、分身/付款、作者 vendor、设置面板。不隐藏窗口、不延时、不猜尺寸。

## 本地检查
- `python3 -m unittest discover -s tests -p 'test_*.py'`：**199 项，182 实跑通过、17 项 Apple runtime 跳过**。
- 新增守卫 `test_bind_applies_remembered_frame`：钉住绑定路径的查找顺序（canvas→hostView）、`restoring` 保护、无动画设置、`first_frame_bind_no_card` 每开窗一次、替换条件含 `initialTargetAppliedAtBind`，并断言不得隐藏窗口。
- `tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`。

## 风险与未验证
- 未做完整 Apple SDK 编译/链接/签名、未出 DEB、未安装、未真机；**“首次可见即记忆尺寸”仍未证明**。
- 若绑定时 canvas 与 hostView 都找不到卡片，则不套用（只记 `first_frame_bind_no_card`），走原有事后路径。
- 若作者在窗口显示后才第一次写尺寸，本改动的效果取决于绑定时卡片是否已在位；日志会给出答案。
- 强制替换窗口为 2 秒；用户一按（`interacting`）即停止干预。
- 普通布局、取消、方向、键盘、贴边、分身、付款仍未回归。

## 证据
`evidence/01-VALIDATE.log`、`evidence/02-VALIDATE-PINNED.log`、`evidence/03-UNIT.log`；110 真机只读证据见 `ParallelX-alpha455-clone0110-20261125/research/readonly-failure-2/`。