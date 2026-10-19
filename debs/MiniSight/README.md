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

## 构建

源码目录 `debs/MiniSight/`，由仓库的 GitHub Actions（`.github/workflows/build-theos.yml`）
自动编译 rootless（arm64）与 roothide（arm64e）两种包，产物落在仓库根目录 `packages/`。
本机不需要（也不应该）安装 Theos。
