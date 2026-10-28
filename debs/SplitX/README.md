# SplitX

分屏多任务与分身（Crane）支持。基座是 PullOver X（GPL-3.0），交互形态参照 ParallelX，
容器切换时序参照 ScreenCore 2.0.5 的已验证链路。

- 包名 `com.niubiprass.splitx`，仅注入 SpringBoard。
- iOS 15.0–15.x，SDK 固定 iPhoneOS15.5。
- Crane 是可选依赖：未安装时自动降级为单容器，不崩。

## 三方来源

| 来源 | 取用 |
|---|---|
| [PullOver X](https://github.com/mlgm66/PullOver-X)（GPL-3.0） | 工程骨架、SpringBoard 注入、FBScene 托管、窗口与内容布局、偏好面板、外部激活协调 |
| ScreenCore 2.0.5（闭源，逆向） | 容器切换顺序：关旧 scene → 终止旧进程 → 等真实 PID 退出 → Crane 认证切换 → 回读确认；失败不落全屏 |
| ParallelX alpha377（闭源，逆向） | 面板形态、悬停放大、遮罩强度、弹簧手感、参数范围 |

闭源包只抄行为与数值，代码自行实现；所有跨版本不稳定 selector 都走
`respondsToSelector` + `method_getTypeEncoding` 校验，签名不符即降级。

## 当前进度（dev6，未真机验证）

- 面板：玻璃面板按弧线散开、悬停放大其余压暗、选中先弹再收；图标/大小/间距/列数/圆角/不透明度全部可在设置里调。
- 选择：同应用的容器成组，默认号标「默」、分身标序号；切换防重入，失败回原状并弹提示。
- 路由：外部唤起与付款按“用户上次为该应用选的容器”预先切换，4 秒切不动就按当前容器放行。

## License

GPL-3.0，见 [LICENSE](LICENSE)。
