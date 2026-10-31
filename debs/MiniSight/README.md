# MiniSight

在 SpringBoard 顶部显示一枚小胶囊，用来提示「Minis 正在操作这台手机」。

## 触发

Darwin 通知（`CFNotificationCenterGetDarwinNotifyCenter()`）：

| 通知 | 行为 |
| --- | --- |
| `com.openminis.agent.started` | 淡入显示浮窗 |
| `com.openminis.agent.stopped` | 淡出隐藏浮窗 |

在手机上发通知：

```sh
# 有 rootless 环境时
/var/jb/usr/bin/notifyutil -p com.openminis.agent.started
/var/jb/usr/bin/notifyutil -p com.openminis.agent.stopped
```

## 外观

- 胶囊：132 × 36 pt，圆角 18，背景 `#141414 @ 88%`，0.5pt 白色 10% 描边，
  黑色阴影 offset (0,6) radius 22 opacity 0.34
- 圆点：7pt，暖米色 `#E8DCC8`，自身发光；背后同色脉动圈 1.0 → 2.6 放大并淡出，
  1.6s 一轮无限循环
- 文字：「Minis 操作中」12.5pt Medium 白色，字距 0.2
- 位置：默认顶部居中，距安全区 8pt；可拖动，松手后写入 `NSUserDefaults`
  （`MiniSightCenterX` / `MiniSightCenterY`），下次显示恢复并 clamp 在屏幕内
- 旋转：监听 `UIDeviceOrientationDidChangeNotification` 重新布局

## 交互

浮窗是一枚全屏透明 `UIWindow`（`UIWindowLevelAlert + 1`），但只有胶囊本身接收触摸，
其余区域的 `hitTest` 返回 `nil`，触摸会穿透到桌面 / 前台 App；窗口也不允许成为 key window。

## 桌宠（可选）

设置 → 插件开发 → 操作指示器里可把胶囊换成桌宠，并导入 9 行动作图集。
桌宠只在自己的可见范围内走动：所有落点来自宿主算出的可行中心区，手动拖动同样夹紧；
浮动窗口永远整屏固定，只有子视图移动，所以不会再把「局部合法坐标」带出屏幕。

「重力感应」默认关闭。开启后倾斜手机左右摇摆（子层旋转，命中区域不变），
快速晃动会触发一次短促的失衡/摔倒回弹；关闭、低电量、息屏、窗口不可见时
都不保留传感器采样和额外时钟。

## 录屏

手动长按由共享录屏控制器管理；自动录屏只在 Minis 设备操作进入执行阶段时启用，审批等待不会启动录屏。控制器仅在 iOS 15.5 SpringBoard 且运行时 ABI 校验通过时使用系统后端；外部录屏不会被接管。停止后只有实际视频文件通过大小、时长及内容校验才提示保存成功。此构建仍需真机确认系统是否接受录制请求；`-5803` 不会被静态测试视为已解决。

## 构建

源码目录 `debs/MiniSight/`，由仓库专用 GitHub Actions（`.github/workflows/build-minisight.yml`）
使用 iPhoneOS 15.5 SDK 分别构建 roothide 与 rootless 包，并上传带 SHA256 的 CI artifacts。
本机不需要（也不应该）安装 Theos。
