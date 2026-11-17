# STATUS — 闪连自动续期

状态：`built_static_verified`（已推送、CI 两架构构建成功、产物已静态核验；未安装）

## 目标
- 到期前自动完成「重置 → 新号 → 填 88888888 → 确认 +3 天」。
- 全程后台，不弹 App、不让用户操作；失败才通知。
- 用户亮屏在用手机时不动，等锁屏；到点前 60 秒兜底必须动。

## 已证实（静态，来自用户提供的包与抓包）
- 包名 `com.shanlian.pro` v4.5.4，Flutter，含 `tunnel.appex`。
- 到期时间：`GET /app/customer/slgetUserInfogo` → `data.isoDeadline` / `deadline` / `expired`。
- 填码：`POST /app/customer/slfillInviteCodefe`，体 `{"inviteCode":"88888888"}` → `code 200`，到期时间变为「现在 + 3 天」。
- 一个号只能填一次，因此每轮必须重置换新号。
- 重置插件：换 IDFA/IDFV 为新 UUID、写入 `kShanLianDeviceIdKey`、清偏好与文件、弹框、重启 App；App 重开后自动注册新号（00:00:00 已过期），随后由用户手动填码。
- `lightningx` 签名只与 `peach`（毫秒时间戳）相关，同一时间戳下与路径/方法/体无关；密钥为钥匙串 `lightningxvpnsymkey`（随机 32 字节，WhenUnlockedThisDeviceOnly）。
- `data` 字段为 208 字节密文（AES-GCM，明文 180 字节），由 App 内 AES-GCM 生成，尚未解出结构。

## 实现
- SpringBoard 端：每 15 秒检查状态；到点判断锁屏；拉起 App 并投递 Darwin 通知。
- App 端：reset（快照偏好 → 换 UUID → 按关键字清理账号键 → exit）→ 轮询新令牌 → 填码 → 复查到期 → 成功重排下一次。
- 失败：本轮内重试；达上限则回滚偏好快照并通知。
- 签名：读钥匙串密钥，6 个候选算法首次校准，命中即固定。
- 无设置面板：码固定 88888888，参数（提前 10/3 分、失败才通知、每轮 2 次）内置。

## 本地静态检查
- `check.sh`：文件齐备、plist 可解析、括号配平、关键接口/密钥账户/状态机/锁屏判断/SpringBoard 过滤/面板真 PSListController + 缓存，全部通过（exit 0）。
- 令牌来源做了双保险：先钥匙串 JWT，再应用组偏好里的 JWT 值。

## 日志
- 写 `com.minis.shanlianrenew.log`（隐根偏好目录），256KB 轮转，含 init/fire/reset/fill/verify/fail/rollback 等阶段标记。
- 查看方法见 `LOGS.md`。
- 首次安装（或版本号变化）后第一次打开闪连，会立刻完整跑一轮：换号 → 重开 → 填码 → 复查。跑完首页时间应变 3 天。
- 失败则回滚旧号并发通知。
- 重装即可重复验证（版本号变化会再次触发测试轮）。
- 未编译（iSH 不编 iOS）。
- 令牌实际存哪里未在真机确认（已双路兼容）。
- 新号注册时序、`data` 密文是否必需、`slcheckInviteCodece` 是否需单独调用，均未真机验证。
- 锁屏拉起成功率、被系统挂起概率未验。
- 签名 6 个候选中哪个正确未知，需真机首次校准。

## 授权
- 已获：本地写码、推送、CI。
- 未获：安装、注销、重启。

## 构建
- 提交 9fefce3 / 分支 shanlian-renew-1.0.0-20261118，CI run 44163296059 两架构均成功出包。
- 整体 run 红只因既有 ReynardDefault 失败，与本项目无关。
- 交付与核验见 releases/1.0.0/VERIFIED.md 与 attachments/ShanLianRenew-1.0.0。

## 1.0.1 真机故障与修复（2026-11-18）
真机实测（MCP 直连）：装插件后 App 0.6s 即消失，卸载后正常 → 确认是插件。
实测证据：
- 应用组真实为 `group.com.shanlianv.pro`，原写 `SZY6Z8FST5.com.lightningxvpn.shared`（错）。
- 隐根真实在 `/var/containers/Bundle/Application/.jbroot-XXXX`，原只在 AppGroup 下扫（错）。
- 无日志/状态文件生成 → 构造期未完成。
修复：
- 应用组改真实名，旧名兜底，永不为 nil。
- 隐根优先 `dlsym("jbroot")`，否则扫两个真实位置。
- 状态先落盘再退出，主队列 0.8s + 全局队列 2.5s 双兜底退出。
- 拉起改为一律 `LSApplicationWorkspace`，去掉 `SBApplicationController`。
- 构造体整体 @try/@catch，异常不再杀进程。
- 日志目录多路径兜底（jbroot 偏好 → 真实偏好 → 临时目录）。
