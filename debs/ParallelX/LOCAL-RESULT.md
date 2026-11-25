# ParallelX clone0.110 本地结果：建窗即套用记忆尺寸

本轮只做本地修改与检查。未推送、未 CI、未出 DEB、未安装、未注销、未重启。

## 思路变化
放弃继续追“第一帧写入”的时机，改在**卡片创建的那一刻**（`PXHostCard initWithFrame:`，参数即默认尺寸）直接套用记忆尺寸。已反汇编核实 `layoutHost` 不会重设卡片宽高，因此此后没有步骤会把它改回默认。这是与苏苏 ScreenCore 同等的“窗口一存在尺寸就对”的结构位置，只是通过创建入口实现。

## 改动
- `Common/PXWindowMemoryPolicy.h`：`PXWMInitialCardFrameUsable`（恰好一个待开窗、有记录、参考尺寸与当前屏幕一致 ±1pt）。
- `Common/PXWindowMemory.m`：
  - `PXWMPendingInitialCardContext`（多个待开窗一律不猜）；
  - `PXWMInitialCardSavedFrame`（读现有存储，参考尺寸校验，无效记录不用）；
  - `PXWMCardInit` hook：命中则把默认参数换成记忆尺寸，并设置与既有“事后替换”相同的字段（含 2 秒期限），作者若再写默认尺寸仍有兜底；
  - 钩子按签名匹配才安装，失败不影响其余功能；诊断新增 `first_frame_memory_applied_at_init` 与 `cardInitReady`。

保留 109 的首帧归属与诊断作为第二道兜底；记忆存储、保存规则、设置、分身/付款全部不动。

## 本地结果
- 198 项测试：181 实跑通过、17 项 Apple runtime 跳过。
- harness：首开资格 15+768 组、建窗条件 10+61 组全部通过；既有 3 种变异仍被拒绝。
- 普通与 pinned 校验：`ALL LOCAL CHECKS PASSED`。
- 新守卫钉住：钩子必转发原调用、不得隐藏窗口（无 `alpha=0`/`setHidden:YES`）。

## 未验证
未做完整 Apple 编译/链接/签名，未出 DEB，未安装，未真机验证“首次可见即记忆尺寸”。若存在 `initWithFrame:` 之外的卡片创建路径，或卡片创建早于开窗上下文，本钩子不命中（无副作用，走原路径/日志）。方向或设备变化导致参考尺寸不一致时建窗期不套用，属设计行为。普通布局、取消、方向、键盘、贴边、分身、付款未回归。