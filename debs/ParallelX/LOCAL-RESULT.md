# ParallelX clone0.107 本地修复结果

## 结论边界

本轮只建立本地候选并完成主机静态检查；未提交、未推送、未 CI、未生成 iOS 机器码、未构建 DEB、未安装、未注销、未重启、未操作设备。

## 真机证据基线

clone0.106 在 Inspector（appHash `18075999571041492679`）的 openSerial 44/45 均出现：记忆已加载、`gate=3`，随后在 `windowHidden=false`、`nativeEntering=false`、默认 312×675.2 已存在时才准备并替换到 284.0055×614.6171。该时序直接证明首个默认 frame 没有在首次可见前被记忆尺寸接管。

## 本轮最小改动

候选目录：`/var/minis/shared/ParallelX-alpha455-clone0107-first-frame-20261125/source`

基线：clone0.106 commit `338503ec3bca8807a5df47bba5eb96855078bca4`，alpha455 vendor 与 16 个作者载荷保持原样。

生产改动集中在 `Common/PXWindowMemory.m`：

1. 新增 `PXWMInitialFrameMayPrepare`：只允许 generation 0、未解决、未交互、未保存、未取消且已有 native serial 的首开 frame 进入预检；不影响普通 resize/layout。
2. 当前 opening ticket 能确认 incoming canvas→PXHostCard 祖先关系时，允许 bridge 的 canvas 字段尚未完成交接；普通运行期仍要求 bridge canvas 与 bundle 匹配。
3. bundle 安全边界保留：目标 bundle 或尚未发布的 nil 可以继续；旧 bundle 一律拒绝。
4. `PXWMPrepareInitialLayoutWithNativeFrame` 使用同一安全匹配，避免三个入口的判断不一致。
5. 诊断与存储构建标记升到 `clone0.107`；包版本升到 `0.1.0~alpha455+clone0.107`。

未改：记忆格式/路径、保存规则、方向隔离、分身/付款、停靠/贴边、原生 layout/动画、取消路径、作者载荷与设置面板。

## 本地检查

- `python3 -m unittest discover -s tests -p 'test_*.py'`：192 项，175 实跑通过，17 项 Apple runtime 专用跳过。
- `python3 tools/validate.py`：`ALL LOCAL CHECKS PASSED`。
- alpha455 原包基线、16 个作者载荷、control、维护脚本、结构和未使用符号检查均通过。
- 生产 C 循环策略与负例仍通过；没有在 iSH 生成 iOS arm64e 机器码。

## 风险与未验证

- 尚未在手机安装 clone0.107，因此不能称首帧已经修好。
- 候选放宽的是当前首开票据的 canvas 交接，不放宽旧 bundle；仍需真实设备验证普通打开、无记录默认、方向变化、取消、键盘、停靠/贴边、分身和付款路径。
- 如果作者首次 frame 发生在源尺寸仍未知的阶段，候选仍会等待真实 source geometry，不猜尺寸；需看新的 `first_frame_memory_ready` 或细化后的等待日志。
- 推送与 CI、DEB 验包、安装加载、真机验收均未授权执行。

## 证据

- `03-ENTRY-REVIEW.md`：入口核查。
- `/var/minis/workspace/px-coldstart-log-20261125/02-INSPECTOR-SEQUENCE.md`：Inspector 真机序列。
- `/var/minis/workspace/px-coldstart-log-20261125/05-LOCAL-TESTS.log`：本地测试日志。
- `/var/minis/workspace/px-coldstart-log-20261125/05-VALIDATE.log`：校验日志。
