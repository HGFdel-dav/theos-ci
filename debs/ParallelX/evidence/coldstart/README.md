# 冷启动首帧恢复：原生时点与安全边界

## 只读证据（实装 clone0.104，iPhone12 / iOS15.5 / RootHide）
- 录屏 metadata `2026-11-24T09:27:16Z`；Inspector appHash `18075999571041492679`。
- 同一开窗 serial 35：`17:27:13.323 native_open_observed` → `.345 native_window_bound_with_memory`（+2ms，memoryLoaded=true）→ `restore_retry_scheduled` gate 3 → `.540 restore_initial_geometry_prepared`（+217ms；before 312×675.2，目标 284.006×614.617；`windowHidden=false`，source surface=true）→ +272ms 替换 → +1.126s 内容 layout。
- 结论：记忆记录存在且目标计算正确；至少一条路径在默认框已可见后才完成恢复。最早开窗事件已被 256 条环形缓冲覆盖，不能把这次 serial 35 冒充首次 serial 34 的完整首帧因果。

## alpha455 原生字节（只读样本 SHA 在 tests fixture）
- `PXSceneBridge layoutHost` imp `0x6aef8`；`0x6af48` 调 `sourceSize` 桩 `0x7f620`（选择器引用 `0x9f090`）；`hostedSourceSize` imp `0x6d4f0` 尾跳到同一桩；`sourceSize`/`setSourceSize:` 为 PXSceneBridge 实例方法：
  - `sourceSize`: `{CGSize=dd}16@0:8`，imp `0x752cc`
  - `setSourceSize:`: `v32@0:8{CGSize=dd}16`，imp `0x752d4`（仅把 d0/d1 写入 ivar `_sourceSize` offset 0xe0，直接返回）。
- 以上用于“源尺寸到达即准备”的事件钩子签名校验；未写死 IMP 调用，全部经原 IMP 转发。

## clone0.106 的恢复点
1. `PXHostCard setFrame:`：通过 `PXWMOpenTicketKey` + 当前 canvas + canvas→card 祖先关系精确匹配正在打开的 ticket；若 bridge 的新 bundle 尚未发布，仅对“当前 opening ticket”允许 canvas 匹配，其它情况仍要求 bundle 相等；用即将写入的 frame 作为 native 默认，读方向/参考/真实源尺寸/记忆记录；齐全时先恢复并让同一笔原生写入直接使用记忆框。
2. `PXSceneBridge setSourceSize:`：先原 IMP 转发；仅对当前 opening ticket、主线程、记忆已加载时尝试准备；其余只转发。
3. `PXHostViewController viewDidLayoutSubviews:`：先对 opening/未恢复 context 尝试准备，再执行原来的绑定恢复/重试。
4. 命中预检成功会记录 `first_frame_memory_ready`，默认 frame 被替换时记录 `restore_initial_frame_substituted`；
5. 以上任一条件不满足：不猜方向、不读默认 canvas 轴、不清记忆、不隐藏窗口；继续原版默认并记录有界脱敏原因。

## 明确未保证
- 不保证所有 App 的所有开窗路径都在首次可见前完成；如果原版在源尺寸建立前就显示窗口，本候选只能在真实源尺寸事件到达时尽早恢复，日志会显示 `first_frame_memory_waiting_for_native_source` 与 gate。
- 没有隐藏/延后窗口，没有改内容 transform，没有新增定时轮询。
- 未本机编译 iOS 机器码、未链接、未 CI、未 DEB、未安装/真机；本地 192 项（17 skip）与两种 validate 通过不等于手机验收。
