# ParallelX alpha455 + clone0.106｜接入作者新版（本地候选）

## 本批授权与阶段
- 用户要求：先检查新版原版，再把现有功能并入。仅批准本地接入与检查。
- 阶段：`local_checks_complete_waiting_push_approval`。**未提交、未推送、未 CI、未构建 DEB、未安装、未注销/重启、未操作设备。**
- 新原版：`0.1.0~alpha455` RootHide `iphoneos-arm64e`，原包 371280 B，SHA256 `56a7777e73c07632d6c00d521a7c09251bb87c850b23c181071745a5febacde0`。
- 自有功能基线：已验包的 clone0.105（提交 `7c12d63e32495add2f0268333e5f4dd4c8dff1db`；本轮未安装）107 文件源码，逐字冻结。
- 版本：`0.1.0~alpha455+clone0.106`。沿用原账号、设置、窗口记忆路径/格式/schema，不新增迁移或清空；分身、付款、设置和作者新功能原样保留。

## 原版变化（只读）
- 16 个作者载荷路径与 alpha451 相同；13 个文件逐字未变。
- `ParallelX.dylib` 754112→754208 B，SHA256 `324e10caca12770671e2c4b35e25c6dc7033939ebdcaf6c439993e9deb2d7389`，有实际代码变化。
- `ParallelXCameraSupport.dylib`、`ParallelXPrefs` 大小不变，所有非签名段逐字节相同，仅 UUID/签名差异。
- Root/Window/System/External/Keyboard/Info/SettingsHelp、PreferenceLoader 配置及三张图标与 alpha451 逐字节相同，自有两条设置入口的叠加仍成立。
- 本轮关注的 7 个宿主/停靠类共 197 个方法，selector 和参数编码未变；开窗、layoutHost、sourceSize、贴边入口未换类或签名。静态证据见 `evidence/native-layout/README.md`。

## 接入内容
- `vendor/alpha451` 整体替换为 `vendor/alpha455`，16 个作者文件逐字来自新包，权限按原包保留。
- `tools/baseline-alpha455.json` 记录新版本、DEB SHA 与 16 个载荷哈希；Makefile/打包校验/设置叠加/本地 validate 路径同步。
- 新增 `tests/fixtures/window-memory-alpha455-abi.json`：15 个方法行、5 个贴边方法行、4 个开窗调用；方法表、开窗顺序、sourceSize 桩与贴边动画地址重新按 alpha455 核对。
- `Common/PXWindowMemory.m` 的 clone0.105 冷启动代码原样保留，只更新注释里的版本名；没有新增窗口行为改动。
- 测试中的 alpha455 地址更新：`sourceSize` 桩 `0x7f620`、选择器引用 `0x9f090`、开窗 `0x73d68`、贴边动画选择器引用与 `objc_msgSend` 桩按新二进制更新；贴边分支的既有目标地址仍有效。
- `control`/`control.in`、两个构建标记和测试版本断言升到 `0.1.0~alpha455+clone0.106` / `clone0.106`。

## 本地检查
- `python3 -m unittest discover -s tests -p 'test_*.py'`：192 项，175 实跑通过、17 项 Apple runtime 专用跳过。
- `test_window_memory_cycles.py` 8 项通过，含生产 C 循环 4067 断言、策略 6692 断言、4 个变异拒绝、alpha455 方法表/开窗/贴边字节。
- `python3 tools/validate.py` 与 `--pinned-vendor`：均 `ALL LOCAL CHECKS PASSED`；原包 SHA 与 16 个 vendor 载荷逐项匹配。
- **未做**：本机无 Apple SDK/arm64e 编译器，未生成 iOS 机器码、未链接、未签名、未 CI、未 DEB、未安装加载或真机验收。静态/本地测试通过不等于手机可用。

## 仍需验证
- 新版原版的真实开窗路径、首帧、内容布局和贴边放大是否与静态核对一致。
- clone0.105 冷启动修复在新版上是否生效；若出现 `first_frame_memory_waiting_for_native_source`，记录 gate。
- 无记忆默认、方向变化、键盘、付款、分身、作者新返回手势和设置面板的回归。
- 安装、注销、重启和推送/CI 均需另行批准；本候选不自动执行。

## 证据
- 基线冻结：`evidence/BASELINE-0105.json`（clone0.105 107 文件哈希）。
- 新原包：`evidence/alpha455-original.deb`。
- 静态证据：`evidence/native-layout/README.md`、`evidence/coldstart/README.md`。
- 上一版回滚：已交付 clone0.105 和 clone0.104 DEB 均可重装；本候选未安装。
