# 出问题怎么看日志

日志写在「隐根偏好目录」，文件名 `com.minis.shanlianrenew.log`，上限 256KB 后自动轮转为 `.log.1`，不会无限涨。

## 拿日志（在终端 App 里跑，比如 NewTerm）

```sh
D=$(ls -dt /var/mobile/Containers/Shared/AppGroup/.jbroot-*/var/mobile/Library/Preferences 2>/dev/null | head -1)
tail -n 200 "$D/com.minis.shanlianrenew.log"
```

## 各阶段标记

| 标记 | 含义 |
|---|---|
| `init …` | 插件加载，带 bundle 与版本 |
| `fresh install … -> test run` | 首次安装/升级触发的验证轮 |
| `keychain key len=` | 钥匙串密钥读到没有 |
| `calib try N` / `calib all failed` | 签名算法校准至第 N 个 / 全失败 |
| `due but unlocked, wait` | 到点了但你在用手机，正在等锁屏 |
| `fire locked=1 …` | 真正开火，`locked=1` 表示锁屏触发 |
| `reset done id=… snap=… cleared=…` | 换号完成，清了几个键 |
| `relaunch(reset)` | 桌面端在重新拉起 App |
| `waiting token Ns` / `new token after Ns` | 等新号凭证的进度 |
| `fill resp http=… api=…` | 填码返回 |
| `verify old=… new=…` | 复查到期前后对比 |
| `renew ok -> …` | 成功 |
| `fail: …` | 失败原因 |
| `rolled back, phase=failed` | 已回滚旧号并发通知 |
| `notify: …` | 发出的通知内容 |

## 交给我的时候

贴 `tail -n 200` 的输出就行，够定位。
