# ParallelX alpha455 + clone0.107｜接入作者新版（本地候选）

## 本批授权与阶段
- 用户本轮明确批准 clone0.107 推送、监控 GitHub CI 到结束及 DEB/源码独立验包；不包含安装、设备操作、注销或重启。
- 阶段：`push_and_ci_authorized`。clone0.107 本地检查已完成，当前正按授权发布；最终 CI 与验包结果以发布目录 release/STATUS.md 为准。未安装、未注销/重启、未操作设备。
- 新原版：`0.1.0~alpha455` RootHide `iphoneos-arm64e`，原包 371280 B，SHA256 `56a7777e73c07632d6c00d521a7c09251bb87c850b23c181071745a5febacde0`。
- 直接来源：已验包的 clone0.106（提交 `338503ec3bca8807a5df47bba5eb96855078bca4`）107 文件源码；其沿用 clone0.105 功能，本轮仅作上述首帧最小改动。
- 版本：`0.1.0~alpha455+clone0.107`。沿用原账号、设置、窗口记忆路径/格式/schema，不新增迁移或清空；分身、付款、设置和作者新功能原样保留。

## 原版变化（只读）
- 16 个作者载荷路径与 alpha451 相同；13 个文件逐字未变。
- `ParallelX.dylib` 754112→754208 B，SHA256 `324e10caca12770671e2c4b35e25c6dc7033939ebdcaf6c439993e9deb2d7389`，有实际代码变化。
- `ParallelXCameraSupport.dylib`、`ParallelXPrefs` 大小不变，所有非签名段逐字节相同，仅 UUID/签名差异。
- Root/Window/System/External/Keyboard/Info/SettingsHelp、PreferenceLoader 配置及三张图标与 alpha451 逐字节相同，自有两条设置入口的叠加仍成立。
- 本轮关注的 7 个宿主/停靠类共 197 个方法，selector 和参数编码未变；开窗、layoutHost、sourceSize、贴边入口未换类或签名。静态证据见 `evidence/native-layout/README.md`。

## 本地候选改动
- `Common/PXWindowMemory.m`：只在 generation 0、未解决/未交互/未保存、当前 native serial 有效且旧场景清理完成的首开 frame 上启用 `PXWMInitialFrameMayPrepare`；不影响普通 resize/layout。
- 当前 opening ticket 已确认 incoming canvas→PXHostCard 祖先关系时，允许 bridge 的 canvas 字段尚未完成交接；bridge bundle 只能是目标 bundle 或尚未发布的 nil，旧 bundle 仍拒绝。
- `PXWMReadGeometry` 与 `PXWMPrepareInitialLayoutWithNativeFrame` 使用同一交接匹配，避免入口判断不一致。
- `Common/PXWindowMemoryStore.m`、`Common/PXCloneLaunch.m` 的脱敏诊断构建标记升到 `clone0.107`；`control`/`control.in` 升到 `0.1.0~alpha455+clone0.107`。
- 作者 vendor、设置、路径、记忆格式、保存规则、方向/分身/付款/停靠行为未改。

## 本地检查
- `python3 -m unittest discover -s tests -p 'test_*.py'`：192 项，175 实跑通过、17 项 Apple runtime 专用跳过。
- `python3 tools/validate.py` 与 `python3 tools/validate.py --pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`；alpha455 基线、作者载荷、control、维护脚本、结构和版本检查通过。
- 本地仅做主机/C 检查；无 Apple SDK/arm64e 编译器，未生成 iOS 机器码、未链接、未签名、未 CI、未 DEB、未安装加载或真机验收。

## 仍需验证
- clone0.107 尚未安装，首帧是否真正做到首次可见即恢复仍未知。
- 如果首次 frame 发生在 source geometry 仍未知的阶段，候选仍等待真实 source geometry，不猜尺寸；需看新的 `first_frame_memory_ready` 或等待 gate。
- 设备需分别验证：普通打开、杀后台后分屏冷启动、无记忆默认、方向变化、取消、键盘、停靠/贴边、分身、付款和作者新返回手势。
- 本轮已批准推送、CI/DEB 验包；安装加载、注销和重启仍须分别另行批准。

## 证据
- 基线冻结：`evidence/BASELINE-0105.json`（clone0.105 107 文件哈希）。
- 新原包：`evidence/alpha455-original.deb`。
- 静态证据：`evidence/native-layout/README.md`、`evidence/coldstart/README.md`。
- 上一版回滚：已交付 clone0.105 和 clone0.104 DEB 均可重装；本候选未安装。
