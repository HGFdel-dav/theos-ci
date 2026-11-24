# Current: QQ lyrics scoped candidate / authorized push + CI (2026-11-24)

- User explicitly approved only App/plugin lyrics-only push, CI, static packaging verification.
- Native baseline and mutations remain mandatory; no new device, capture, install, respring or reboot authorization.
- MiniSight0.8.52; only core plugin payload, no audio capture service.
- Frozen authorized source: /var/minis/shared/openminis/local-reviews/lyrics-qq-local-20261124/FINAL-SCOPE.json.
- Scope: strict LRCLIB->QQ, stale-track fence, bounded diagnostic routes; preserve old pet gestures, atlas, bounds, composer.
- Stage: staged; new native execution/build/package not yet proven.

---
# Historical records (not current authorization)

# 当前：歌词与音乐真实走跳本地修复（2026-11-23，未推送）

- 本轮用户在现场只读结论后明确“可以”：仅修自动歌词和音乐期间真实换位置走/跳；不沿用11/21原地音乐限制，不触碰日间波浪暂停草稿。
- 实装插件已只读确认为0.8.50/arm64e。发布源码HEAD仍26bf301；候选版本0.8.51，尚未构建或安装。歌词已抓到18:41网易云有效曲目→取词→not_found；安装库也证实musicPlaying取消巡游，证据见`../openminis/local-reviews/pet-music-readonly-20261123/READONLY-FINDINGS.md`。
- 保留所有17项既有dirty，不回退旧补修；本轮快照、允许范围、实现和测试分别保存在`../openminis/local-reviews/pet-music-local-repair-20261123/`。已修好三项：重启整图、普通贴边范围、开启桌宠App崩溃，均关闭且受保护。
- **本地已完成（未推送）：** 两端19套最终回归零失败，双端58生产方法/片段走跳与手动接管闭环、各5个动作负例，以及歌词463断言/8个负例通过；16项SDK15.5仅语法检查通过。Foundation/NSURLSession/UIKit/Swift原生与真机均未运行；缺native门禁正确拒放，不等于手机已好。最终证据以`../openminis/local-reviews/pet-music-local-repair-20261123/RESULT.md`及FINAL-AUDIT.json为准。
- 本轮没有commit/push/CI/设备操作/真实歌曲查询/播放器控制/麦克风/安装/注销/重启授权；**停在推送前闸门**，下一步另问App同步共享修正及插件0.8.51的push/CI。

---
# 历史：三项修复续作，本地收齐（2026-11-22）

- 用户最新停止提问系统通知排查，明确续修波浪、桌宠摔倒/原地音乐、歌词获取到显示；本插件只涉及桌宠/歌词，不改通知/名字/重力源。仅本地，不含提交、推送、CI、设备操作、安装、注销、重启、真实音频/歌曲查询。
- 当前实际 HEAD `26bf3018eef7928d6f823949ddfec1eef862f3e3`，0.8.50为此前发布基线；不能沿用下文“未CI”旧状态或旧推送权限。
- 开始时15个已有dirty文件原件与diff冻结，范围和结果以 `../openminis/local-reviews/three-repairs-resume-20261122/STATUS.md` 为准。普通手势/素材/录屏/权限/设置路径保留；原生、安装加载和手机效果分开验收。

---
# 历史：插件 0.8.50 / App 1.15 双端修复候选（2026-11-21）

- 插件包版本已升为 `0.8.50`，目标分支 `minisight-0.8.50-20261121`；App 仍沿用 `ios15-160652-four-features` 与 build 160652 基线。
- 本地检查通过：插件宿主门禁 132 项；两端媒体/歌词/播放器合同、音乐位置与多阶段落地、动作素材、问答通知、整框底部波浪均通过；便携 C 实跑 6400 姿态采样和 5 个故意破坏均正确拒绝。
- 本批新增插件重力设置读回→Stop/Start 生命周期；OFF→ON 会清除失败代际并重新尝试，日志记录传感器来源、能力、active、回退、错误码、样本数与时延，并区分首帧未到和已有样本后中断。
- Apple Foundation/UIKit/CoreMotion 原生夹具、Theos 双架构构建、安装加载和真机功能仍未验证；本候选不包含设备操作、注销或重启。

---
---
# 历史：MiniSight0.8.47 本地整合通过，待授权推送执行（2026-11-18）

- 本轮问答卡 `local_repair: 可以`；修歌词链路、名字唤醒具体缺陷、注销/重启后素材整图重现、恢复可贴边但身体不出屏。`storage_scan: 暂时不用`；余额和数据占用暂停。用户后续另行“这几个问题修复了，就推送”，批准本批本地全部检查后的提交/推送/CI；没有设备/MCP/开麦/真实歌曲请求/安装/注销/重启/整IPA下载授权。
- 当前HEAD `9fbc15d8669d91997c059c1ecedc6cf3e5a16070`，0.8.46此前双CI/DEB已验，准确证据 `../MiniSight-releases/MiniSight-0.8.46-20261117/VERIFIED.md`。下文0.8.45不是当前源码基线；当前实装插件仍未本轮读取，不假定旧版本。
- 插件候选升为0.8.47；两端共享Atlas恢复与MediaRemote符号__TEXT滑移定位已本地修，保所有旧素材/动作与锁屏/显隐/取消/匹配准则；根因条件不等于手机已经解决。
- 普通pet中心边界与气泡空间分开；胶囊/审批仍旧safe/headroom。新增视觉四角边界只修正屏边变形，不缩小活动范围。App与P Pet/Panel/Resources的旧分支差异不覆盖。
- R1/R2/R3补修真实FINAL已收并核SHA：A权限正常inactive/真正后台区分、两阶段协作取消；P普通文字保逻辑尺寸/无center-only缓存/重建清缓存，审批安全代码逐字保持。最终独立整合审查已确认LOCAL_READY_NATIVE_PENDING/blockers=[]，父核42个审查快照SHA均匹配；未宣布原生或手机通过。
- 最终本地58入口全部符合预期：47普通退出0（36含native SKIP）、9严格缺Apple退出1并拒放、2diffcheck通过；原布局1600029、边界C449462+3行为负例及7相邻便携入口过。核心镜像和旧功能源码保护全过，新strict已登记未触发CI。
- 证据目录 `../openminis/local-reviews/pet-four-repairs-20261118/`；最终独立整合审查闭合后冻结精确源码，再按已获批准分别推送。安装加载/真机功能与CI各分开报告。

---
# 历史：MiniSight0.8.45 真实CI／双DEB静态核验PASS（2026-11-17，未安装）

- 本轮用户明确覆盖旧“仅重试一次后停”的限制，授权当前版本继续编译／真实CI错误窄修／普通push与双架构验包。已在预算内达到真实编译与验包终态；不包含安装、设备配置、开麦、真实歌词请求、注销或重启。
- 最终本地／远端HEAD `fd321d3a374cfce99aafb652830b9d63ad998f6d`；HGFdel-dav/theos-ci，minisight-0.8.45-20261116，run124／43923925319 attempt1；RootHide与rootless全部步骤逐项completed/success。固定macos-15-intel、Xcode16.4、iPhoneOS15.5.sdk、FINALPACKAGE=1，不换runner／SDK／门槛，不在iSH编iOS。
- 原run123 attempt1/2 hosted runner未领取、steps0，父新授权attempt3获runner后实际执行。两架构Theos成功，但原生baseline夹具runtime.m:66推断int block与BOOL签名不符，native_checks=1／theos_build=0，artifact0；全失败日志与官方注解保留。
- 仅将共享夹具 `scripts/fixtures/minisight_presentation_readback_20261116/runtime.m` 一行改显式 `Wait(^BOOL(void) { return !gMiniSightShownWritePending; });` 后普通push；未改生产Tweak／Resources／UI、literal inc／manifest、原生guard或App。共享窄修先记录通知父，父已局部同步；原5共用模块＋9夹具／测试镜像只读14/14一致，本地待同步为空，App新提交／CI仍由父独立处理。
- 新run的固定15.5 arm64/arm64e生产.m、ObjC/ObjC++策略、MusicMonitor／Lyrics／ImageIO-ASan／PetEffects及5真实Tweak函数（含UserHide）＋3资源writer原生门槛通过。新presentation baseline先真实编译运行，两个unsafe变异编译成功后运行拒绝；不是compilefail冒充负例，macOS依赖替身测试也不当真机UIKit结果。
- RootHide DEB SHA256：`2a242a51a84d5c3fc5a390ef7ee1db761a997f8046cb2ba5b0d0dcb6eaaaec6b`；rootless：`53e8311b04d4e812ded0696728baf3d6099b07ee93f4c19e000a6e97257e1130`。包身份／版本／架构、CI manifest、官方artifact ZIP SHA／CRC、当前attempt上传ID均核实；仅dylib0755＋SpringBoard filter0644，无维护脚本或额外载荷。
- Mach-O SDK15.5、minOS15.0；arm64e subtype0x80000002、PAC1820条，rootless普通arm64。CodeDirectory SHA-1/SHA-256：RootHide各159页、rootless各155页及特殊槽2哈希全部通过；两架构代码页1篡改负例均被拒，原文件未改。静态签名完整性不代表签名信任／安装加载。
- 最终准确源码ZIP：108文件逐字对照git blob、提交注释／CRC通过，排除.git/.theos/packages/out/logs/凭据，SHA256 `2ac7bdd115b25130946773359d05c8af13496da7b01e33298b8ed58acbd52b57`。双包／源码／SHA256SUMS／完整报告与全CI证据存attachments/MiniSight-0.8.45-20261117及shared/MiniSight-releases同名目录；旧真实失败交付18文件保存在两目录previous-blocked-attempt2，不拿旧包冒充成功。
- 本终态STATUS仍只本地dirty，未再次提交／push。原后台、锁屏／OFF、draft／手动、录屏／素材、ChatPanel／Key及署名义务未删改；未安装／加载／开麦／真实歌词查询／改设备／注销重启；19:28真机原因仍未知，不称原功能已好。旧AE086F89未恢复／重派；插件无仍运行CI。

---
# 历史：0.8.45 初次推送停在attempt2的原始记录（已被上方新授权续跑覆盖）

- 用户本批明确“推送”，分别发布App与MiniSight0.8.45；插件获准本批提交、普通推送、GitHub CI、按真实构建错误窄修重推及双架构静态验包，**不包含安装、设备操作、开麦、注销、重启或真实歌词查询**。基线HEAD为8d433c122f5735b4acf44fd66bc98e5f3f14b842，本地分支minisight-0.8.40-20261110；唯一目标HGFdel-dav/theos-ci的refs/heads/minisight-0.8.45-20261116，不force、不覆盖旧版本。
- 插件已使用GITHUB_TOKEN_QQ普通推送；本地与远端HEAD均为9a3d38427aa1fd6dce1ebb41aebb67208703c5fb。App由父代理独立处理，本代理没有修改App树/PBX/余额/名字Swift/音频。基线、diff、新文件来源、原STATUS、本批STATE和共享变更记录保存在shared/MiniSight-releases/MiniSight-0.8.45-20261117/work/。
- GitHub run123/43914589598的attempt1与同提交唯一一次attempt2均已终结failure；每次RootHide、rootless job都cancelled、steps0。两次官方注解均为“The job was not acquired by Runner of type hosted even after multiple attempts”。完整日志各为22字节空ZIP（CRC通过、0日志文件），artifact0；**从未开始编译或执行原生检查，不是源码/native已失败或通过**。
- 无0.8.45 DEB、包hash、Mach-O/PAC/签名/载荷验包结果；不使用0.8.44旧包冒充。实装仍为已确认0.8.44/App304，本代理未安装/操作设备。按父当批纠正，只收完attempt2，未再rerun/push、未换runner/SDK、未猜测修源码/放宽门槛；本最终STATUS仅本地回写，未再次提交推送。
- 固定GitHub CI iPhoneOS15.5.sdk，RootHide arm64e/rootless arm64，FINALPACKAGE=1。iSH仅本地源码/便携检查与静态验包，不能编iOS。原生strict、baseline和unsafe负例不得绕过；每次真实失败日志和修法分别归档。任何共享模块/头或测试夹具窄修立即写SHARED-CHANGES.json，供父局部同步。
- 生产名字状态组包共用MiniSightNameWakeState.h，BOOL明确序列化；App真实reader严格兼容旧整数0/1，未知状态不假锁。SB不录音、不TTS、不拉App。正常语音结束保草稿、锁屏/OFF保护与原手动流程不删。
- 音乐准入/保存链：真实shown文件有界1字节读回与事务身份、异步写成功反馈及通知，旧runtimeON不复活显式hide；过期settings重读、resource尾重判renderer/style保queuedcallbacks、淡入淡出有代次。App已选前台快照通路保留而非伪造SB可见，未知锁屏仍关。
- 两端MusicMonitor.m/.h及策略/ShownReadback共用头一致，v1+additive证据与BOOL一致；播放与歌词样本分离，不因无词随便停律动；MediaRemote判型与CF借用复制未改。真实19:28失败根因仍未知，没有强制常驻/真实歌曲请求。
- 本地源码/便携C、原129宿主、录屏/聊天/素材等守卫；新5个Tweak生产函数及3个资源writer摘录Foundation行为与负例已接严格native门槛，但iSH没有AppleSDK，原生/设备仍SKIP。细节见App docs/minisight-304-regression-local-20261116.md和workspace/minisight-304-local-20261116/。
- 本批推送前仅插件重跑20入口均exit0（含原129宿主、录屏/聊天/素材/音乐策略等），2项插件strict缺Apple SDK明确非零拒放；此前两树44入口exit0、7项strict拒放、36项字节完整性无失败证据已独立归档，不假称本代理重跑App。原生仍待GitHub runner执行。
- 本批已获上方推送许可，插件只用GITHUB_TOKEN_QQ；CI/验包/安装加载/功能验收分别记录，不能只编译成功就称名字歌词已好。

---
以下当批授权已经用于发布0.8.44（CI43800730733两scheme成功）且用户自行安装，不延续到新候选。

# 历史：MiniSight 0.8.44 跨 App 名字唤醒插件（2026-11-16，当批已获推送/CI授权）

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

## 2026-11-17 MiniSight 0.8.46 最终本地候选与独立推送授权

- 本批基线fd321d3a374cfce99aafb652830b9d63ad998f6d（0.8.45上一批CI双包通过但build308 App真机余额回归已另定位）。用户新“推送”覆盖本批两端提交/CI，不沿用旧许可，不含安装/注销/重启/开麦或任何设备操作。
- Resources仅局部新增严格shownEvidence/saveShown，成熟单字节/原子写入/精确读回实现共用；保存验证后才交付，App无关设置退出不写cachedON。原P资源分支/刷新/Pet/Panel/Music差异保留，不整覆盖App。
- NameWakeHost沿可信deviceIsUnlockedWithKnown读取锁事实，schema2新增BOOL lockKnown/screenKnown/screenOff；trusted lock及screenOff硬停，unknown安全关闭但不伪报locked。request/result仍schema1；token/revision/busy/聊天审批/已有后台实现保留。
- 本人版本control和Tweak诊断升0.8.46；实际Tweak/Pet源码除版本外逐字同基线，Panel/Music零diff。完整NameWakeState、20新测试fixture及2App音频测试源码镜像同SHA。音频镜像不含App src，不能从插件树执行，只由App CI运行；没有新Plugin音频生产。
- 本地新shown入口4source PASS/2native SKIP，required2缺工具FAIL非零拒绝；host129、repairs、name60、guards3、approval13通过。两端diffcheck通过，无Swift/AppleFoundation，尚未新CI/DEB。新版tools保留全部旧门槛并新增shown/name --require-native。
- App最终34普通入口exit0(21含nativeSKIP)、6required缺工具硬拒，不当native通过。4真实final已冻结，旧test适配与全部来源、相邻保护报告保留；准备按授权提交新分支minisight-0.8.46-20261117，用GITHUB_TOKEN_QQ，与App token隔离。
- 交付前仍需双scheme完整CI/native、DEB载荷/维护脚本/Mach-O代码页/CRC/SHA检查；安装加载、SpringBoard真实显示/锁屏/音乐/后台音频均未验证。证据shared/openminis/local-reviews/model-picker-watchdog-20261117及shared/openminis/releases/Minis-0.8.46-20261117。
