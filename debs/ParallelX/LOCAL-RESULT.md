# clone0.9 历史对照与回归修复结果

## 结论边界
本地纯静态/主机检查，不是 iOS 编译，更不是真机。未推送、未安装、未注销、未重启。

## 已确认的回调误判

## 根因
- 当前设备`/usr/lib/libcrane.dylib`（FAT 93bf47df…，arm64e薄片）`-setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:usingBiometricsIfNeededWithSuccessHandler:`@0x84d4。
- 0x8580读取requireBiometricAuthentication（0xf680 boolValue），为0由0x8584跳到0x8694；0x86a4调用setActiveContainer...reload:（resolver 0x105c0），随后0x86b8 `mov w1,#0`，0x86bc调用callback。认证路径0x8728也调用setActive，0x873c `mov w1,#1`。
- 因此该回调的BOOL只是**认证标志**，不是统一成功标记。clone0.8与旧版认证兜底都用`success && active==target`，把无需认证的正常切换误判失败，甚至没有active回读。
- 旧版本大多先走不带callback的直接接口，所以旧故障不一定暴露；clone0.8把它变成主路径。

## 本轮改动
- Crane接口改名`requestSwitchToContainer:reply:error:`；reply只转原始BOOL；`PXCloneFlowAcceptCraneReply`把NO、YES都转Verifying；只有active==target并可见才Open。保留Crane原认证、reload:NO、旧进程退出、A→B→A最新目标、超时隔离。真实回调未达仍Quarantined，不会轮询active偷开。
- 新增`tests/fixtures/crane-reply-arm64e.json`固化真实0x8584/0x86a4/0x86b8/0x86bc/0x8728/0x873c/0x8758字和分支偏移。测试反汇编BL偏移，核对setActive stub，不只按名字。
- 根因修复后，旧“raw NO=失败”模型全部更新。

## 诊断缺失
- 旧`PXCloneActiveRoot`只jbroot→realpath→必须canonical `.jbroot-*`，不扫描、不缓存、失败无回退；record又忽略EnsureStorage/路径/写盘错误。因此记录可能从未落盘而仍只弹账号错误。
- 新`PXCloneRootPolicy.h`生产C规则：仅AppGroup `.jbroot-*`；明确排除Bundle/Application（常指向//）和真实var；rootless才接受非/的canonical /var/jb。
- Paths先官方jbroot，失败再对AppGroup（rootfs与物理路径两入口，最多256项）按含本插件dylib、MobileSubstrate、usr/lib评分取高，同分mtime新，dev/ino去重；成功后进程缓存。UUID不硬编码。
- EnsureStorage在包括一切mkdir前核对Library/Prefs父目录和既有目录canonical都在选中根内；锁保留O_NOFOLLOW并做额外检查。
- 诊断走`PXCloneTrace`：固定Preferences目录fd，openat O_EXCL临时、fchmod0600、fsync、renameat、按字节读回，读写前后都复核根/父目录dev/ino及canonical containment；父目录被改例或文件又是symlink即失败，不跟随写其他位置。
- 失败不是默默return：Darwin notify state + 账号页顶部状态行；Launch首次出现具体状态时toast，同一状态不连续刷屏，不阻止账号操作。
- 迁移兼容：读CFPreferences已存的CXStore包装、不双重包裹；仅过核验的源去清理；清理前再比内容和指纹；按dev/ino 排除当前域的rootfs/alias别名。旧源全部未过核验时保留文件不删。

## 本地检查
- `tools/validate.py`全过：114项host、vendor 16文件逐字节、baseline DEB hash、plists、两scheme维护脚本/control、结构/unused/版本守卫。- 生产C直接主机编译执行：85068条Flow；916条root alias/rank/containment；29条真实目录atomic写/0600/读回/symlink/父目录改名。C编過-Wall -Wextra -Werror。
- 均为host，不执行ObjC私有服务；无iOS compiler、无真机。tree-sitter ObjC解析器仍Segfault，未计语法检。

## 未验证与风险
- 全新root discovery的SpringBoard真实jbroot/realpath尚未采样；新选择器未在设备执行。不能声称路径本因已定。
- 父目录dev/ino是防常见替换，不是无锁的全openat O_PATH链；极端并发在核验与renameat间改父目录仍未完全排除，会在写后复核报未确认。
- 新认证请求仍依赖真实Crane回调；用户取消/无回调是quarantine等待，不会自动成功。权限与运行时ABI待CI/真机。
- 删最后一个分身仍保留现有空目录不删行保护。
- CI / DEB构验 / 安装 / 注销重启 / 真机A-B-A和新增C均未做。

## 文件不动的边界
vendor alpha391、普通应用打开、菜单视觉和排序、CXStore偏好主接口、账号开关面板结构均未改。`Common/PXClonePrefs.m`只改了旧迁移读/清理路径，不改每次开关的CFPreferences读写。
