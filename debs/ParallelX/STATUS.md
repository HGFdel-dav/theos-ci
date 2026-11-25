# ParallelX alpha455 + clone0.112｜保存规则三条修正（本地候选）

## 本轮授权
用户本轮明确批准推送、监控CI至结束及DEB/源码独立验包；不包含设备操作、安装、注销或重启。

阶段：`push_and_ci_authorized`。最终结果以项目上层`release/STATUS.md`为准。

## 依据（111 真机日志）
- 有记录的 App 套用 100%：CHiQ 6/6、QQ 4/4、Quantumult X 2/2（+1~6ms，绑定前）。
- 淘宝：`startingSizeKnown:false` → `resize_unchanged_or_unknown_no_save`，记录没建 → 下次默认。
- 默认尺寸窗口只移动：`position_no_size_no_save`，记录没建 → 位置不记。
- QQ：套用成功，但约 1.8s 后窗口回到 312×675；旧路径有 0.9s 定帧收尾，新绑定路径漏调。

## 改动
1. `Common/PXWindowMemory.m` 绑定套用后调用 `PXWMScheduleInitialSettle(ticket)`：0.9 秒时若窗口被带回默认尺寸/位置，就无动画再定一次（只做一次，用户已开始操作则跳过）。
2. `Common/PXWindowMemory.m` 保存：起始尺寸读不到时不再丢弃，记录 `resize_unknown_start_saved` 并按结束时的正常几何保存；只有“起始尺寸已知且没变”才跳过（`resize_unchanged_no_save`）。
3. `Common/PXWindowMemoryStore.m`：位置保存不再要求已有记录——没有记录时用观察到的正常几何建立记录（`position_only_created`）；已有记录仍只改位置、保留原尺寸。

未改：记忆格式/路径/schema、方向隔离、分身/付款、作者 vendor、设置面板；不隐藏窗口、不延时。

## 本地检查
- 200 项测试：183 实跑通过、17 项 Apple runtime 跳过。
- 新增守卫 `test_save_rules_cover_move_and_unknown_start`：钉住三条规则与绑定收尾调用；更新两处旧断言。
- `tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`。

## 风险与未验证
- 未做完整 Apple 编译/链接/签名、未出 DEB、未安装、未真机。
- “起始尺寸未知也保存”在异常布局下可能记下非默认尺寸；已有 `PXWMMaySave`（正常布局/非动画/epoch）+ `PXWMMayWaitForGestureGeometry` 兜底，异常会先被跳过。
- 无记录时移动建记录只发生在“正常、已稳定、用户完成”的手势后；贴边/放大/取消仍不写。
- 方向、键盘、分身、付款未回归。

## 证据
`evidence/01-VALIDATE.log`、`02-VALIDATE-PINNED.log`、`03-UNIT.log`；111 真机证据见 `ParallelX-alpha455-clone0110-20261125/research/readonly-success-check-3/`。
