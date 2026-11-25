# ParallelX alpha455 + clone0.113｜尺寸保持 + 内容探针（本地候选）

## 本轮授权
用户本轮明确批准推送、监控CI至结束及DEB/源码独立验包；不包含设备操作、安装、注销或重启。

阶段：`push_and_ci_authorized`。最终结果以项目上层`release/STATUS.md`为准。

## 依据（112 真机 + 录屏）
- 录屏 10.4s：QQ 启动画面窗口宽约 235pt（记忆 238，正确）；11.6s 内容加载完成后窗口变成约 305~312pt（默认）。
- 日志：s18 在 +0.016s 套用 238.15 后，再无任何替换/定帧记录——因为强制窗口只有 0.9~2s，而 QQ 在约 4~5 秒后才改回默认。
- 内容错位（0.9s 内）此前已确认是内容重排晚于外框；用户要求不改内容逻辑。

## 改动（仅 `Common/PXWindowMemory.m`）
1. 绑定套用的目标改为“持续保持”：`holding = initialTargetAppliedAtBind || 未超时`；只要窗口还开着、用户没拖、没有全屏/贴边变换，作者后续写回默认尺寸都会被改回。
2. 结束条件：用户手势（`interacting`）、保存待处理、`close`、卡片有非单位 transform（贴边/放大）、`fullscreenHandoff`。
3. 0.9s 收尾不再清除 `initialTargetActive`（仅非绑定路径清除），并保留一次 `layoutHost` 重排。
4. 新增只读探针 `content_geometry_probe`：每个开窗在 +0s / 0.9s / +2.5s 各记一条，字段只有尺寸与是否不匹配（cardW/H、canvasW/H、sourceW/H、mismatch），不含任何内容或名称。用于下次偶发时定位“内容没跟上”。

未改：内容排版逻辑、记忆格式/路径/schema、保存规则、方向隔离、分身/付款、作者 vendor、设置面板。

## 本地检查
- 201 项测试：184 实跑通过、17 项 Apple runtime 跳过。
- 新增守卫 `test_bind_target_is_held_and_content_is_probed`：钉住保持条件、结束条件、探针字段与调用点，并断言探针不得改内容尺寸/transform。
- `tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`。

## 风险与未验证
- 未做完整 Apple SDK 编译/链接/签名、未出 DEB、未安装、未真机。
- “一直保持”意味着作者若因自身逻辑改变窗口尺寸（非用户操作、非全屏/贴边），会被改回；已用 transform/fullscreen 门放行常见情形，但边界未真机验证。
- 探针只记录尺寸，不解释原因；若下次仍出现内容不跟随，日志会给出卡片/画布/源尺寸三者关系。

## 证据
`evidence/01-VALIDATE.log`、`02-VALIDATE-PINNED.log`、`03-UNIT.log`；112 录屏与诊断见 `ParallelX-alpha455-clone0112-20261125/research/readonly-qq-video/`。
