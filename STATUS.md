# MiniSight 0.8.2 repair status

- 阶段：本地修复与静态/可移植检查完成；等待推送 CI。未安装、未注销、未重启。
- 基线：`HGFdel-dav/theos-ci` / `minisight-0.8.1-20261106` / `413da95`。
- 本轮：0.8.2。长按动作按配置分派；运行快照/偏好合并读取；独立日志字段；语音启动确认/最终结果/取消/去重；审批确认时序与回退；通用抛飞-落地-回弹物理；跟随面板 30fps、键盘恢复；图集单帧渲染；素材专用重载通知。

## 证据

- `tools/check_host.py` 122 项
- `tools/check_repairs_20261107.py` 通过
- `tests/physics_fling_20261107.c` 187850 项
- `tests/chat/layout_follow_20261107.c` 5732 项
- `tests/chat/chat_layout_test.c` 110336 项
- `tests/gravity_test.c` 40015 项
- `tests/chat/chat_test.c` 233 项
- `git diff --check`、ObjC 括号检查通过

## 未验证

- 未做 arm64e 编译；未安装；未真机验收。
- SpringBoard 真机手势分派、语音权限/识别、审批气泡、物理手感、键盘收起、素材下载都需装机验证。
- 设备安装 234 时 13:10 卡死栈已确证为 `read_image → resizedImageData → UIImageJPEGRepresentation → ImageIO` 主线程；本地已改后台 ImageIO。系统 CPU 报告另有 iSH 模拟 CPU 占用，非同一栈。

## 授权

- 用户 2026-11-07：“继续修吧，修完了再推送” = 完成本地修复后允许推送 CI。安装/注销/重启仍需单独授权。
