# ParallelX alpha451 + clone0.105｜冷启动首帧恢复时序候选

## 本批授权与阶段
- 用户只批准本地修改和检查，目标是冷启动时**首次可见前**应用已保存的窗口框，而不是先默认再缩小。
- 阶段：`local_checks_complete_waiting_push_approval`。未提交、未推送、未 CI、未构建 DEB、未安装、未注销或重启；手机仍为已交付的 clone0.104。
- 基线：已发布 clone0.104（commit `57a2b8cc373e3029b3a43ecd6ec94a32626d2fc9`）的 106 文件源码，已与发布 Source.zip 逐字核对；作者 alpha451 16 个原版文件不变。
- 版本：`0.1.0~alpha451+clone0.105`。账号、设置、记忆文件路径/格式/schema、分身、付款与作者新功能均未改。

## 已证症状（只读，来自实装 0.104）
- 用户录屏 `video_23322F7F.mp4` 显示冷启动 Inspector 先出现默认大框，随后变小。
- 设备日志实例：`native_window_bound_with_memory`（+2ms，记忆已加载）→ `restore_initial_geometry_prepared`（+217ms，此时 `windowHidden=false`，默认 312×675 已存在）→ 替换（+272ms）→ 内容重排（约 +1.13s）。
- 因此至少一条开窗路径在默认框可见后才完成恢复；不能把 0.103/0.104 的本地/CI 通过当作手机已修好。
- 最早那次开窗事件已被 256 条诊断环形缓冲挤掉，不能伪造首帧逐调用栈；本次候选需要装后新日志确认命中点。

## 本次唯一生产改动
文件 `Common/PXWindowMemory.m`：
1. `setFrame:` 钩子不再只认已发布的绑定 context；通过当前 canvas 与 `PXWMOpenTicketKey` 精确匹配正在打开的 ticket，并识别它的 PXHostCard，从而在**原版第一笔默认外框写入之前**读取方向、参考尺寸、真实 `hostedSourceSize` 和记忆记录。
2. 只有所有证据齐全、记忆已加载、功能开启、没有手势/待保存时才预计算并替换；真实内容方向未知时拒绝猜测，继续原版默认，并留下脱敏 `first_frame_memory_waiting_*` / `no_record` / `disabled` 诊断（每个方向仅一次）。
3. 新增 `PXSceneBridge setSourceSize:` 钩子：转发原调用后，若该 bridge 有正在打开的 ticket，立即用新源尺寸准备记忆框；非当前 ticket、已绑定窗口或非主线程一律只转发。
4. `viewDidLayoutSubviews` 钩子对正在打开、尚未恢复的 context 先尝试准备，再执行原有恢复/重试。
5. 保留贴边放大 `PXWMExpansionTarget` 的原帧目录替换调用；保留原版 `layoutHost` 内容布局与 900ms 单次 settle，不隐藏窗口、不改内容 transform、不延时强压、不按 App 特判。
6. 异常/取消/关闭仍清除初始终态；无记录、关闭开关、方向不匹配、源尺寸仍不可用则退回原版默认，不创建或清空记忆。

## 本地检查
- `python3 -m unittest discover -s tests -p 'test_*.py' -v`：192 项，175 实跑通过、17 项 Apple runtime 专用跳过。
- `python3 tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`，含上传原包 SHA 与 16 个 vendor 载荷。
- 新增/更新的源码契约测试覆盖：票据匹配、第一笔默认 frame 前读取、`window` 可见性不参与初始恢复、源尺寸事件先转发后准备、宿主布局先准备后恢复、贴边放大调用仍存在、失败日志不猜方向。
- `test_window_memory_cycles.py` 8 项通过，含生产 C 循环 4067 断言、策略 6692、4 个变异拒绝、alpha451 方法表字节。
- **未做**：本机无 Apple SDK/arm64e 编译，未生成 iOS 机器码、未链接、未签名、未 CI、未 DEB、未安装加载/真机。静态检查与 CI 通过都不能代替手机首帧验收。

## 仍需真机验证
1. 有记忆的冷启动：第一帧是否直接是记忆框（不是先默认再缩），日志是否出现 `first_frame_memory_ready` 且 `substituted` 在首次可见前；若仍出现 `waiting_for_native_source`，记录 gate 与时间。
2. 无记忆 App、关闭记忆、记忆损坏：是否保持原版默认，不产生空白/卡死。
3. 正常 resize/move 分型保存、关闭/取消、缩小贴边→放大、横竖屏、键盘/付款/分身、作者新返回手势是否无回归。
4. 安装、注销、重启各自另行授权；本候选不以本地或 CI 成功声称手机已修复。

## 证据与回滚
- 基线冻结：`evidence/BASELINE-0104.json`（106 文件哈希、Source.zip SHA）。
- 用户录屏与设备日志：`../research/coldstart-readonly-20261124/`（只读取证，另目录，不随候选源码打包之外的旧证据）。
- 本候选回滚：重新安装已交付 `ParallelX-alpha451-clone0.104-20261124` 的 DEB 即可；旧 0.103 包也保留。
- 推送/CI/验包须单独批准；批准前不提交、不触发 CI。
