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
单击打开 AI 聊天面板（面板使用独立、可成为 key window 的窗口），双击隐藏桌宠，长按按设置切换录屏。

## AI 多轮聊天面板

单击桌宠打开 `MiniSightChatPanel`：独立、可成为 key window 的浮层，支持输入、多轮、发送、取消、清空、键盘避让；点背景关闭，隐藏/重建桌宠时一并收起。
接口仍读 App 已写好的 `Documents/MiniSight/ai.json`（URL/Key/模型），不在插件里再存一份 Key，也不打印 Key。面板不可用时才回退旧的单句生成。2xx 但正文为空或无法解析按失败处理；响应上限 2 MB，请求超时 30 秒。

## 回前台

新版 App 在执行结束时会自己回到 Minis，并在活动快照里写 `nativeReturn: true`；
插件读到后不再另开前台任务。旧 App 没有该能力时插件才兜底：1.0 秒后查前台，
仍是别的 App 才用 `LSApplicationWorkspace` 打开。多次停止只保留一个待执行任务。

## 桌宠（可选）

设置 → 插件开发 → 操作指示器里可把胶囊换成桌宠，并导入 9 行动作图集。
桌宠只在自己的可见范围内走动：所有落点来自宿主算出的可行中心区，手动拖动同样夹紧；
浮动窗口永远整屏固定，只有子视图移动，所以不会再把「局部合法坐标」带出屏幕。

「重力感应」默认关闭。开启后倾斜手机左右摇摆（子层旋转，命中区域不变），
快速晃动会触发一次短促的失衡/摔倒回弹；关闭、低电量、息屏、窗口不可见时
都不保留传感器采样和额外时钟。

## 录屏

手动长按由共享录屏控制器管理；自动录屏只在 Minis 设备操作进入执行阶段时启用，审批等待不会启动录屏。控制器仅在 iOS 15.5 SpringBoard 且运行时 ABI 校验通过时使用系统后端；外部录屏不会被接管。停止后只有实际视频文件通过大小、时长及内容校验才提示保存成功。此构建仍需真机确认系统是否接受录制请求；`-5803` 不会被静态测试视为已解决。

## 0.3.5 插件修复范围

- 自动录屏只由 `minisight.record` 和有效 MCP 执行阶段共同允许；手动长按只由 `minisight.longPress` 允许。二者共享系统后端，但不能相互认领、停止；外部系统录屏仍不接管。
- 插件在 MCP 阶段变化和手动长按时轻量刷新 App 配置，先应用来源开关、准备目录，再读新执行快照；配置本身不凭旧快照开启录屏。不改 App/IPA。
- 普通停止不再当作取消：0.05–3 秒测试片段也进入保存流程；显式取消、超时、中断仍不得伪报成功。实际成功仍要求系统返回合法视频、大小至少 1 KB、时长大于 0 和可播放轨道。
- 停止后保存阶段不再每 250ms 在主线程轮询 ReplayKit；复制/校验是 utility 后台队列，保留一次性保存超时。不是已证明真机不卡，也没有改变系统的捕获机制。
- 文件仍保存在 `Documents/MiniSight/recordings/`；`recording-last.json` 索引包含最近成功保存的文件名、时长、大小。不自动导入照片，也不是新增 App 文件浏览 UI。
- 重力摇晃使用 0.75g/0.35g 滞回阈值，并在传感器流异常后重新启动；共享数学和传感器真机验收分开。
- AI 解析更多可见文本格式；错误/空内容回退预制句子。此处不是接入 Minis 主模型多 Key 池。
- “等待你确认”收起重复状态气泡；空白气泡收起。**没有移除 App 的权限确认弹窗，也没有跳过审批。**

本地测试与 CI 构建都不等于真机验收。录屏保存负载、系统是否接受启动、桌宠流畅度、重力和两套审批交互仍需装机后验收。

## 诊断日志

设置 → MCP 集成 → Minis 内置工具 → 操作指示器里有「记录诊断日志」，默认关闭。开启后只写本机 `Documents/MiniSight/diagnostic.log`，记录状态、错误码和计数；超过 200KB 轮转一份 `diagnostic.log.1`，不记录 Key、提示词、命令正文和响应正文，不自动上传。

## 0.4.0 本地变更（未发布）

- App 侧目录快照改后台完成；插件不再重复拉前台，见上文。
- 单击桌宠从“生成一句话”改为打开多轮聊天面板；旧单句函数仅作面板不可用回退。
- 手动长按录屏在目录已就绪且容器未变时，不再每次重建目录、读取活动状态；只刷新两个开关和执行 in-memory toggle。
- 本机 shell 被测试残留 `sleep` 拖死时尚未跑最终全量；交付前仍需补跑并核对。

## 构建

源码目录 `debs/MiniSight/`，由仓库专用 GitHub Actions（`.github/workflows/build-minisight.yml`）
使用 iPhoneOS 15.5 SDK 分别构建 roothide 与 rootless 包，并上传带 SHA256 的 CI artifacts。
本机不需要（也不应该）安装 Theos。
