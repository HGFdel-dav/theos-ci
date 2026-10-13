# HMSDiagnostic 0.1.0

**这是诊断插件，不是激活或修复包。未经过真机运行测试。**

目标为 iPhone 12、iOS 15.5、RootHide（arm64e）。仅对 `hellomemorystatusd` 注入，不覆盖原守护程序、原设置面板，不改变授权配置或返回值。

记录范围：`setpriority` 与 `memorystatus_control` 的标量参数、返回码、失败错误码及相对调用地址；`SecKeyCreateDecryptedData` 的输入是否为空、返回是否为空及调用地址。禁止转储许可证、密钥、解密数据、错误对象或内存缓冲区。系统接口原参数、返回值、errno 原样保留。

日志位于 `/.jbroot/var/mobile/zqbb/HMSdiag.log`（rootless 回退 `/var/jb/var/mobile/zqbb/HMSdiag.log`），同时输出 syslog。文件最多约 4 MiB，每个守护进程最多 10000 条。读取后应卸载诊断插件，避免长期开启。日志缺失可能是未注入、目录不存在、符号不可用或文件权限等原因，不能视为授权成功。

安装后需要重启目标守护服务才能注入，可使用原设置面板的“重启守护服务”。安装流程可能触发注销或锁屏，交由用户自行安装，不通过 MCP 自动安装。没有维护脚本，安装/卸载包本身不添加强制重启命令。

当前设备安装的 3.9.0-8 带有错误的解密修改。本诊断插件不会修复或撤销它，只观察当前行为；完整分析原版授权流程需用户自行决定恢复未修改原版。日志需结合原守护日志时间戳对照，不能从接口是否调用直接断定某个授权分支。

编译使用 GitHub Actions/macOS、RootHide Theos、iPhoneOS15.5.sdk；RootHide 架构 arm64e，rootless 架构 arm64。用 `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide` 或 `rootless`。未在 iSH 编译 iOS 二进制。
