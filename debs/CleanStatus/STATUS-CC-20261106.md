# CleanStatus 控制中心扩展 — 本地候选

## 当前授权
- 用户要求实现三项：Wi-Fi 长按网络列表、蓝牙长按已配对设备列表、独立系统操作控制中心模块。
- 仅本地分析、修改和检查；未授权 commit、push、CI、安装、卸载、设备配置修改、注销或重启。
- 后补授权：只读查看手机已安装的 QuickCC2。已确认 2.0.1 / arm64e；EVO 未安装。

## 工作树与基线
- 候选：`/var/minis/shared/CleanStatus-cc-local-20261106/`。
- 原工程：`/var/minis/shared/CleanStatus/`，保留不动。
- 基线控制字段为 0.1.14；旧 STATUS 的历史版本/CI 数据被以前的全局替换污染，不作为本轮构建证据。
- 基线 38 文件哈希：`../CleanStatus-cc-research-20261106/baseline/SOURCE-SHA256.json`。
- 电池源码 SHA256：`b7b20c271905e0ce313bf9fdac47fad295dbe01c4de95a91ec02119f4478706b`；本轮必须保持逐字一致。
- 计划候选版本 0.2.0，不沿用已交付的 0.1.14。

## 已查事实
- QuickCC2 上传包 SHA256：`b081087d68a695d26483a2b5dc4eba80755212363e8fbd6cdf3d3694534ac3e9`。
- 已装版本 dpkg 显示 2.0.1；过滤器与上传包一致，274464 字节 dylib 哈希不同，原因待分区对比。
- 实装文件及只读比对：`../CleanStatus-cc-research-20261106/quickcc2/device/IDENTITY.json`。
- EVO 参考来自 `Niubiprass/Niubiprass.github.io/debs/com.jaysuen.evocenter_3.0.0-beta.2-ios15.2_iphoneos-arm64e.deb`；只作功能静态参考，不捆绑其二进制。
- 现有配置解析返回真实 `/var/mobile/Library/Preferences`，新三组件不能复制此缺陷；接入所需共用隐根解析正在本地修正，未执行手机迁移。

## 不改
- 电池颜色/绘制/填充、现有状态图标隐藏、未知部件实现。
- 普通 Wi-Fi/蓝牙点击和展开后的原生菜单。
- 不添加彻底关闭 Wi-Fi/蓝牙，不添加 Jade/EVO 控制中心整体皮肤。

## 验收合同
1. 两个长按列表只有已开启、SpringBoard 内、已解锁、折叠连接模块才可接管。
2. Wi-Fi 扫描/连接和蓝牙列举/连接必须有真实 API 调用与回调链；错误/超时可见，过期回调不能重开关闭的菜单。
3. 同类 QuickCC2 重复接管必须处理；本轮不自动停用或卸载原插件。
4. 新系统操作模块使用有效 PrincipalClass/注册信息，随同一 DEB 安装，通过现有模块支持机制添加。
5. 系统操作须再次确认；注销、用户空间重启、整机重启不可混用，后端缺失不可执行替代危险动作。
6. 三组件同域、同隐根、相同默认值；默认三个新开关均关闭。
7. 锁屏/禁用/缺类或 ABI 不符/加载较晚/重复安装 Hook/关闭后回调/多次点击均有负例。
8. 本地只能证明模型/静态契约；Swift/ObjC 类型、iOS 构建、DEB 加载和真机功能分别待验证。

## 当前阶段（本地实现完成，待推送授权）
- 新增 `Shared/LocalCleanStatusCCPolicy.h`（可移植门槛/代数/超时），`Shared/LocalCleanStatusCCDiagnostics.m`（隐根日志，无密钥内容）。
- 新增 `Sources/LocalCleanStatusCCBackend.{h,m}`：MobileWiFi 13 符号 dlsym + BluetoothManager 运行时探测。
- `Sources/LocalCleanStatusPaths.m` 增加 `local_cleanstatus_toolPath()`：由 Bundle 路径反推隐根、退 /var/jb、退 /usr/bin，只返回可执行文件。
- 新增 `Sources/LocalCleanStatusControlCenter.m`：两个 CC 控制器长按、锁/展开/前台门、代数防过期回调、加密网络跳设置。
- 新增 `LocalCleanStatusSystemActions/`：标准 CC bundle（NSPrincipalClass、1×1、CCSupport 扫描目录），五个动作：注销/安全模式/用户空间重启/重启/关机，缺后端不显示。
- 设置面板新增“控制中心”分组三项，默认全关；模块开关未开时模块显示“已关闭”。
- 依赖新增 `com.opa334.ccsupport`（设备已装 1.3.13）。版本 0.2.0。
- 主机检查：core 5,252,881 例、CC policy 658 例、源码不变量 223、路径模型 37、验证器自测 46 全过；shell 语法通过。
- 证据：`../CleanStatus-cc-research-20261106/IMPLEMENTATION-CC.md`、`quickcc2/API-EVIDENCE.md`、`evocenter/API-EVIDENCE.md`。
- **未编译 iOS、未推送、未出新 DEB、未安装、未注销/重启、未真机验收。**
- 已知未验证：CCUIRoundButton 类名定位、CCSupport/私有服务权限、与已装 QuickCC2 同时接管时的行为。
