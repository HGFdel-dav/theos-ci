# 当前：MiniSight 0.8.44 跨 App 名字唤醒插件（2026-11-16，已获推送/CI授权）

- 用户明确要求 App 和插件分开推送、分开监控；编译失败可在本批范围内修复重推，不包含安装/注销/重启。本插件使用 `GITHUB_TOKEN_QQ`；实际远端是 `HGFdel-dav/theos-ci`（旧配置 `Niubiprass/theos-ci` 当前API404），目标新分支 `minisight-0.8.44-20261116`，不覆盖旧基线。
- 已接通 SpringBoard 安全心跳、同 host/revision/token 的 hit→accepted→ready→voice_requested，以及关闭/锁定/新资源取消。插件不采音、不拉 App 前台；真实后台音频由 App 用户授权后持有。两端需配套更新。
- 自然语音 final 和结束按钮不再并发取消转写，录音结束后保留未发送草稿面板；显示持有与音频请求独立，真实关闭才释放。聊天/审批/原素材、歌词只当前行、平滑动作均保留。
- 本地源/wire62点、生产C14497点+面板4100点/2变异负例通过；UIKit/链接/设备仍未验。旧129宿主守卫按明确名字交互扩展而不开放任意空闲显示。
- 版本0.8.44；RootHide arm64e、rootless arm64、SDK固定15.5。推送前 HEAD仍1e816aa，两端原有dirty保留。待本次CI实际结果，不把静态或源码记录当已运行。未安装、未开麦、未注销重启。

---
以下为历史状态，不延续旧授权/完成结论。

# 历史：MiniSight 0.8.43＋App前台名字唤醒接口（2026-11-16，仅本地）

- App树新增直接名字唤醒接入稿，默认关闭、明确权限、仅App内前台；不是Siri修改，也不在SpringBoard启动常驻录音。HEAD仍 `1e816aa`，未commit/push/CI/安装/开麦/注销/重启。动作/歌词候选与原STATUS dirty保留。
- 插件只同步面板明确回应、单次代次、关闭/重开/新增名字语音的编辑发送取消接口与C门槛；没有增加KWS/ORT或麦克风Hook。旧语音手势保留。
- 本地27定向入口通过，新原生仍SKIP；共享面板头/名字C门槛一致，原9共享动作/歌词文件保留。4100真实C规则＋2负例不是UIKit/真机证明。
- App新原生库发布许可义务尚有缺口，App打包上传已加阻断；两端没有触发CI。真机名字识别、音乐/蓝牙/录屏/通话，及原动作/歌词实际效果仍未验。App文档 `docs/minisight-name-wake-20261116.md` 和工作目录 `workspace/pet-three-features/wake/checks-final/` 记录当前状态。

---
以下为名字接入前历史状态，不延续旧授权。

# 历史：MiniSight 0.8.43 通用动作与在线歌词（2026-11-16，仅本地）

- 授权：通用素材自带动作+平滑补充动作，以及自动LRCLIB歌名/歌手/时长匹配。未 commit / push / CI / 安装 / 注销 / 重启 / 开麦 / 真实歌曲查询；本轮完成到本地候选，不能用以前推送许可继续。
- 基线：HEAD仍 `1e816aa`，此前实装只读确认0.8.41；原STATUS已有未提交修改，本段保留其历史记录。control/诊断候选版本升0.8.43，当前未生成DEB。
- 已接：动作原生加载/有界解码与原件保护、独立连续视觉驱动、明确动作角色/失败回退、首帧/取消围栏；拖动取消不甩不写，只有正常放手估速；碰边/落地轻重受力，文字和命中区不旋转。
- 歌词：私有播放接口存在/ABI判型检查、同源信息→状态→信息复核，锁屏/隐藏关闭、每曲退避、限流、单在途与写盘邮箱；LRCLIB只精确匹配同步歌词，默认两个开关关闭。快照无歌名/歌手，仅当前行/播放与脱敏原因，保存读回后通知。App模式只桥接当前行。
- 音乐动效是播放联动而非精准跟拍。名字唤醒没有接入；现有语音、录屏、审批代码保持。
- 检查：共享新库/驱动逐字一致，24项跨两树定向入口通过；生产便携C40498+旧状态27433/重力40015/抛飞187850/布局1600001/聊天110336/跟随5732/录屏224246通过。原生UIKit/ImageIO/媒体回调与手机表现尚未执行。新Foundation/动作夹具和固定SDK15.5类型检查已登记CI入口，未触发。
- 未验：各App最新版真实播放/歌词/暂停/切歌/锁屏恢复，动作平滑度、内存和耗电，真实素材透明边缘。安装/加载与功能验收分开做。结果记录在App文档 `docs/minisight-liveliness-media-20261116.md` 与工作目录 `workspace/pet-liveliness-local/checks/final`。

---
以下历史状态仅作基线，不延续当时授权。

# MiniSight 插件 0.8.42 CI 与验包状态（2026-11-11，未安装）

- 基线来源：插件代码从 `minisight-0.8.40-20261110` 已验证源分支继续；当前 CI 目标分支 `minisight-0.8.42-20261111`，本地 checkout 目录名仍为旧分支名，但提交/远端分支已核对一致。
- 设备已安装基线：MiniSight 0.8.41 arm64e；未对此设备安装或改配置。
- 用户授权范围：审批中文摘要、回复面板/桌宠动作、待发送视频/区域拖动及后台保活相关项目保留行为；本轮只推送和构建，没有设备安装授权。
- 插件最终提交：`1e816aa16e972b63718ed01e798ac3bba78b7c3f`，GitHub Actions run 113 / `42908385259`；RootHide、rootless 两个构建均成功。
- RootHide DEB：`com.niubiprass.minisight_0.8.42_iphoneos-arm64e.deb`，SHA256 `b1824f156137e5d3ae042a929bac6fe4d8b5fe79aa9ac9cb1ca8a6bc0b55e60c`。
- rootless DEB：`com.niubiprass.minisight_0.8.42_iphoneos-arm64.deb`，SHA256 `e73677e32865225123e6be4bbe1c30302bc7bd0e9c87b904c2cb85612a3031ff`。
- 两包元数据均为 `com.niubiprass.minisight` 版本 0.8.42，架构字段正确；Roothide 在 `Library/MobileSubstrate/DynamicLibraries`，rootless 在 `var/jb/Library/MobileSubstrate/DynamicLibraries`；载荷只有 dylib 和注入过滤 plist，无维护脚本/额外文件。arm64e/PAC 与 arm64 Mach-O 的 SDK 15.5、minOS 15.0；SHA256SUMS 与 CodeDirectory SHA-1/SHA-256 代码页校验通过。
- 本机 host 回归：宠物状态 27433、面板 110336、跟随 5732、屏幕几何 1600001、重力 40015、聊天核心 233；ApprovalSummary 13 项、诊断 11 项及 strict C/C++ 检查通过。App/插件 macOS CI 也成功。
- 验证与交付文件位于 `/var/minis/attachments/MiniSight-0.8.42-20261111/`，包括双架构 DEB、App IPA、准确提交源码 ZIP、SHA256SUMS、VERIFY-REPORT.md。
- 未安装/加载、未真机验证宠物动作/键盘跟随/面板和视频流程；未注销、未重启、未改设备配置。CI/DEB 核验不能代替真机结果。
