# MiniSight 分阶段运行诊断

有效 container 下，基础结构化事件始终记录；详细诊断开关只控制旧 `MSDiag` / `MSDiagMessage`。两类事件都只能记录状态和计数，没有正文。未配置 container 时不创建文件。调用可来自任意线程，串行队列异步写入；不用主队列。

```objc
// 保持原 ABI：enabled 现在只控制详细旧诊断。
void MSDiagConfigure(BOOL enabled, NSString * _Nullable container);
void MSDiag(NSString *format, ...);
void MSDiagMessage(NSString *message);
// 基础记录，不受 enabled=false 影响。
void MSDiagEvent(NSString *feature, NSString *stage, NSString *result,
                 NSDictionary<NSString *, id> * _Nullable fields);
```

合法 feature：`chat/settings/runtime/voice/ai/ai_test/assets/recording/gravity/drag/activity/screen/ownership/gesture/bubble/approval`。

合法 stage：`save/receive/apply/show/layout/send/reply/display/close/skip/build/entry/editor/keyboard/composer/state/visibility/hide/begin/end/readback/publish/request/cancel/config/network/callback/parse/finish/ready/error/sample/stop/start/load/click/response/change/configure/deliver/interruption/rotate/reload/identity`。result 固定为 `ok/failed/skipped/cancelled/pending/unsupported`。pending 只证明进入阶段；configure 只证明对象被配置，不证明屏幕效果。

字段白名单：`setting/source/reason/request/revision/generation/issue/count/chars/duration_ms/renderer/visible/sending/keyboard/below/x/y/w/h/enabled/mode/style/field/code/domain/saved/readback/sequence/value/present/roll/samples/http/bytes/reasoning/finish/valid/executing/active/version`。value 只接受有限数字，用于固定设置的数值/开关；颜色转为整数，不记用户字符串。未知键、数组、字典和非有限数直接丢弃。数字绝对值不超过 2^53-1。

字符串最多 80 个 ASCII 标识符字符，只可传固定状态、setting key、错误域和版本。request 只允许 UUID 或 UUID/数字代次；revision 为 UUID 或数字。严禁传 Key、URL、提示词、用户称呼、命令/聊天/响应正文和音频。拒绝凭证形态并不能替代调用端保证静态字符串来源。

`MSDiagSettingsSnapshot(stage, source, preferences)` 只摘取 12 个固定设置、数字值、颜色整数和 revision；绝不复制整个用户 defaults。设置接收事件标 pending，不冒充执行。

```objc
MSDiagConfigure(NO, container); // 基础事件仍写入，旧详细诊断关闭。
MSDiagEvent(@"settings", @"save", @"ok", @{
    @"setting": @"minisight.style", @"revision": @7,
    @"saved": @YES, @"readback": @YES
});
MSDiagEvent(@"chat", @"reply", @"failed", @{
    @"request": requestID, @"generation": @2, @"issue": @4,
    @"reason": @"http_error", @"duration_ms": @1200
});
```

App：`<container>/Documents/MiniSight/diagnostic-app.log`、`diagnostic-app.log.1`。
插件（SpringBoard）：`<container>/Documents/MiniSight/diagnostic-plugin.log`、`diagnostic-plugin.log.1`。
每种角色保留两份，每份不超过约 200 KiB，0600。每行 UTC 时间、pid、process、进程首次初始化时生成且本进程不变的 runId、单调 seq、`event={...}` JSON。单个 JSON 上限 6144 字节，等待队列最多 256 条，过载丢弃。进程重启 runId 改变；seq 只在同一 runId 内有序。App 与插件不再争用文件，同角色多进程还用持久 `.log.lock`（0600）的 flock 保护整个轮转/追加，锁文件不得在运行中手工删除。

关闭详细诊断会使已排队旧诊断失效，基础事件保留；container 改变使旧 container 队列失效；已开始的一次写入允许完成。磁盘写入不持有生产者配置锁，避免文件锁阻塞主线程。原 `diagnostic.log`、`diagnostic.log.1` 保持不动，读取工具兼容它们。旧自由格式入口不再保存原文，只抽取已知阶段和白名单字段，并保留明确的 success/kind/issue 结果；不支持的旧自由文本会丢弃。

## 读取已经取得的本地文件

工具不拉设备日志、不联网、不扫描目录，不自动包含轮转文件。显式传入所有需要合并的文件（含存在的 `.1`）；不要传不存在的通配字面量。

```sh
python3 tools/diagnostics/read_events.py /tmp/fake/diagnostic-app.log /tmp/fake/diagnostic-app.log.1 /tmp/fake/diagnostic-plugin.log --feature settings --since 30m --tail 100
python3 tools/diagnostics/read_events.py /tmp/fake/diagnostic-plugin.log --feature chat --since 2026-11-05T08:00:00Z --json
python3 tools/diagnostics/read_events.py /tmp/fake/diagnostic-plugin.log --feature voice
python3 -B -m unittest discover -s tests/diagnostics -p 'test_*.py' -v
```

每文件最多读末尾 256 KiB，超过时丢掉首个可能截断行；最多 32 文件。先解析/白名单脱敏，按时间合并和去重，再筛选 `--feature/--since`、取 `--tail`（默认 200，上限 5000）。坏行、截断行、超长行跳过；读取失败只显示数量，退出码 2，不回显路径或原文。`--since` 支持 ISO-8601 或 `30m/2h/1d`；无时区按本机时区。旧 `MM-dd HH:mm:ss.SSS` 无年份/时区，按本机时区及最近年份估计。

可读摘要和 `--json` 都有 settings `save→readback→publish→receive→configure→apply`、chat `send→reply→display`、具体失败/取消/跳过和可见事件。settings 用 setting+revision 合并 App 与插件，chat 用 request 关联，缺 request 时只在同 runId/pid/generation 内汇总。缺少 revision 不可认定是同一次设置修改。`unobserved` 仅表示当前读取/过滤窗口未见，不代表未执行；没有 display 不能推断没发送。历史重复阶段取最近结果，完整事件列表仍保留可见历史。设备时钟跳变和旧记录年份估计会影响跨进程排序。

宿主测试只构造临时假日志，不读取实际设备/真实日志。Objective-C 写入器需由主代理在有 SDK 的构建环境验证，本工具测试不等同于 iOS 编译或装机验证。
