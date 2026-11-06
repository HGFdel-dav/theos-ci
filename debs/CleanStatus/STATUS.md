# CleanStatus 0.2.1 本地修复状态

## 当前授权
用户反馈 0.2.0 的三处失败并同意先本地修改：
1. Wi-Fi/蓝牙长按没有 QuickCC2 原版列表效果。
2. 缺图标指的是设置→控制中心模块列表，不是下拉控制中心图标。
3. 原系统菜单有五项，现版真机只显示三项。
仅本地修改、静态检查及必要只读取证。未授权 commit/push/CI/安装/卸载/修改设备设置/注销/安全模式/任何重启。

## 基线
精确复制已交付 0.2.0 源码，与 Source.zip 逐文件差异为 0。
- 候选 `/var/minis/shared/CleanStatus-0.2.1-local-20261106/`
- 旧版 `/var/minis/shared/CleanStatus-cc-local-20261106/` 不改。
- release: HGFdel-dav/theos-ci cleanstatus-0.2.0 @9b6f88b, CI109/42178907388。
- baseline files SHA256 / protected-file hashes 在 `../CleanStatus-0.2.1-research-20261106/`。
- 电池绘制 / 状态图标 / 未知部件 / 低电量逻辑 / 设置面板控制器源码本轮必须逐字保持。

## 发现（本次源码 + 只读设备证据）
- 当前设备实装 CleanStatus 0.2.0；CCSupport 1.3.13.1。
- dpkg 未返回 com.ichitaso.quickcc2 信息，不能沿用旧“两个都装着”的结论。
- 原模块只有 Info.plist 和可执行，没有任何设置图标资源。
- 原长按只是 UIAlertController action sheet；没有 table/refresher/dismiss/request state 的实际链路。
- scan 超时只清 bool/写日志，不投递失败；回调代数在 UI 无真正校验；bluetooth action 立即 success=YES。
- Hook 使用 method_setImplementation 对继承 Method 直接写，可能改到父类；buttons 按字符串精确类名寻找也缺子类与唯一性。
- 原工具路径用 NSBundle.mainBundle（SpringBoard.app）的 Library 分段反推；这不是模块自身 Bundle。
- SpringBoard 当前 UID501。已找到 launchctl/killall，权限0755 owner0；存在/可执行不证明 reboot 权限。
- 尚未确认是否还存在原生菜单高度导致只显示三行的另一个因素，修复应固定五项并允许滚动。

## 修复验收合同
- CC2 表格交互：居中模态列表、信号/锁/当前连接、已配对状态、下拉刷新、独立关闭、选择后的真实连接/错误反馈。
- 普通点击与展开后的系统连接模块不改；只有已开启并解锁、折叠、可见时接管长按。
- generation/token/cancellation/timeout 真正接入；过期/关闭/锁屏/多次点击不会重弹或误操作。
- 设置模块图标必须被元数据加载规则引用并随包安装。
- 五个动作固定显示；可用才执行，不可用给明确原因，不静默隐藏，不以请求成功代替运行成功。
- 所有危险动作第二次确认、重检开关/锁状态、单次执行；异步权限后端与进程退出状态可诊断。
- 若需特权 helper，只支持固定 probe / userspace reboot，不接任意命令或参数，执行前校验；不更改设备现有二进制权限。
- 原电池和其余既有功能不变。任何 RootHide 路径修复不得重新引入删除当前 plist 的迁移循环。

## 状态
本地修复进行中；未编译 iOS / 未出新 DEB / 未推送 / 未安装。
