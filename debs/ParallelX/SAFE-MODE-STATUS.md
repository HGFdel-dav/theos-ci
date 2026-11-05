# ParallelX clone0.4 安全模式修复状态

## 已确认
- 真机报告：`evidence/safe-mode-20261104/SpringBoard-224814.ips`
- CI clone0.4 arm64e UUID `e53a1dc3-2963-3ade-8da2-f141c52137f5` 与真机崩溃映像一致。
- SpringBoard 在加载 `ParallelXClone.dylib` 的 dyld initializer 中崩溃。
- 异常是 `KERN_INVALID_ADDRESS`，报告明确标注 `possible pointer authentication failure`。
- CI 映像 PAC 静态扫描：112 处 double-sign、116 处 double-authenticate；检查器会失败退出。

## 已本地修正
- 移除通用 `-mbranch-protection`、`-fptrauth-calls`、Linux linker/header workaround；只允许 GitHub macOS/Apple clang 构建。
- 改用官方 `<roothide.h>` NSString overload，不再用错误的 dlsym C/ObjC 函数指针转换。
- 构造函数不再同步初始化 Crane；主线程首轮后才安装 Hook、初始化偏好、枚举 Crane。
- 新增 `tools/check_pac.py`，并新增安全模式回归测试；75 项 host tests 全通过。
- 安装后脚本不再自动重启 SpringBoard。
- 版本升到 `0.1.0~alpha391+clone0.5`。
- 新增独立 CI 工作流 `.github/workflows/build-parallelx.yml`，只针对安全修复分支，保留 dSYM、日志和验证 JSON。

## 当前授权状态
- 仅本地修改与静态检查。
- 未 commit、未 push、未触发新 CI、未安装、未注销、未重启。
- 下一闸门：用户明确批准 push + GitHub CI 后再推送修复分支。
