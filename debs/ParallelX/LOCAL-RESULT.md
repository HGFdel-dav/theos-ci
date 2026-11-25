# ParallelX clone0.111 本地结果：绑定时即套用记忆尺寸

本轮只做本地修改与检查。未推送、未 CI、未出 DEB、未安装、未注销、未重启。

## 为什么改
110 的“建窗时套尺寸”从未命中：真机日志里 `cardInitReady=1` 但 0 条套用记录，说明卡片不是每次开窗新建。日志同时显示窗口在 +270ms 前已可见，而作者约 +400ms 才写默认尺寸。

## 改了什么
- 绑定成功那一刻（canvas/bundle 仍精确匹配、窗口尚未显示）：按 canvas 找卡片，找不到用 bridge 的 hostView 向上找；命中记忆记录就无动画设好 frame，并置 `initialTargetActive`/`resolved`/`initialTargetAppliedAtBind`（2 秒期限）。
- 作者随后写回默认尺寸时，替换条件 `!same && (sameNative || initialTargetAppliedAtBind)` 在同一帧改回记忆尺寸；用户一按即停止。
- 新增诊断：`first_frame_memory_applied_at_bind`、`first_frame_bind_no_card`（每开窗一次）。

## 本地结果
- 199 项测试：182 实跑通过、17 项 Apple runtime 跳过；新增守卫钉住查找顺序、restoring 保护、无动画设置与替换条件。
- 普通与 pinned 校验：`ALL LOCAL CHECKS PASSED`。

## 未验证
未做完整 Apple 编译/链接/签名，未出 DEB，未安装；真机“首次可见即记忆尺寸”仍未证明。若绑定时找不到卡片则只记录诊断并走原路径；普通布局、取消、方向、键盘、贴边、分身、付款未回归。
