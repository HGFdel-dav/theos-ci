# INPUT-ADAPTER-HANDOFF

## 结论与边界

2026-11-27 15:47（Asia/Shanghai）：当前生产整模块和六个行为用例的 **iOS 15.5 严格全夹具语法检查通过**。Linux 原生行为测试明确 SKIP；**没有运行任何 macOS 行为用例，不能写成“事件不吞/原调用一次已行为通过”**。

仅新增：
- `tests/test_window_input_adapter.py`
- `tests/window_input_adapter/fake.h`
- `tests/window_input_adapter/cases.m`
- `evidence/INPUT-ADAPTER-HANDOFF.md`

没有修改生产源码、Makefile、旧测试、version；没有设备操作、CI、push、安装、工具安装。另一个代理的切换事务测试未触碰。该 source 目录没有 Git 元数据，不能提供 git diff 证明；本专项写操作仅指向上述文件。

## 测试实现

每次构建重新读当前 `Common/PXWindowInputDiagnostics.m`，仅删除 `#import` 行，将**整个生产模块**（含上下文类、全部静态函数、Bind/Close/Observe/Install）与 fake.h、cases.m 放进同一编译单元。没有复制生产观察逻辑，也没有用源码字符串检查冒充行为。真实 `PXWindowInputPolicy.h` 和 `PXWindowMemoryPolicy.h` 直接包含；不重复运行父负责的 hostC Policy 专项。

边界 shim：Foundation 实际对象/集合/异常/关联对象；伪 UIKit 树及触摸；可控时钟；只排队的 dispatch_after；内存诊断收集器；ObjC runtime 实际方法签名比对和记录型 hook。Install 用例只调用 mock hook，不改运行时 IMP。所有伪类运行名均为 `PXIFake*`，UIKit 名称通过宏别名替换，没有定义/复用 CALayer。

每次构建打印生产模块、两个 policy 头和夹具的 SHA-256；每条编译/执行命令打印 `RETURNCODE`。临时编译目录位于专属 fixture 下，结束清理，不产生安装包。

## 六个用例（已编译，均未原生执行）

| 用例 | 可执行断言覆盖 |
|---|---|
| scope | 未注册微信窗口零日志/不读 touches；其他 app 注册被拒、窗口照常原调用且零日志；已注册微信/QQ分别仅记对应 serial。 |
| forward_exceptions | 每次调用校验 self/cmd/event 指针相同、orig 正好一次；正常 dispatchReturned=true；orig 抛出的同一个异常对象传出并可记 false；event.allTouches、touch.view、视图读取抛异常不阻止 orig；观察与原函数同时抛异常、日志收集器抛异常也不替换原异常。 |
| phases_privacy | moved/cancelled、混合 began+moved+cancelled phaseMask；host/keyboard receiverMask；stationary、非触摸、其他窗口 touches 不记 dispatch；9触摸截断到8；没有交互/隐藏/透明度写入，没有二次 hitTest/正文/坐标读取；日志字段白名单且全部数值。 |
| disabled | 已注册窗口关诊断后不读 event/bridge/window、零日志且 orig 一次；Observe、五个定时回调、Close、关诊断再 Bind 同样零日志；重新开启后正确观察新 serial。 |
| close_generation | 验证五个延迟为0.25/1/3/8/15；只入队，人工 drain，不等待、不推进时钟、不调用原应用动作；Close后旧回调零读取零日志；新开窗替代旧代次后，旧回调不读旧/新 window、canvas、bridge；旧窗口事件仍原调用但零日志；新回调只观察新 serial。旧上下文 precise-lifetime 强持有，不能靠弱引用变 nil 蒙混通过。 |
| rate_unknown_abi | 十次事件均 orig 一次，仅前八次记录；下一10秒窗口记录 suppressed=2、eventsObserved=11，随后清零；缺失 BOOL/PID getter 明确 -1、已知 true/false 仍1/0；闭合 host gate 可记 incident 但不声称远端处理；Install ABI拒绝不调用hook、不写original，放行4个mock hook且重复安装不重挂。 |

日志验证要求 `remoteReceiptKnown == false`、`appResponsivenessKnown == false`。没有远端 receipt、真实 UIKit 分发或应用响应性的证明。

## 实际执行与返回码

工作目录：`/var/minis/shared/ParallelX-alpha455-clone0117-input-diagnostics-20261127/source`

1. 初次 `PYTHONDONTWRITEBYTECODE=1 python3 tests/test_window_input_adapter.py`：**return 1**，native SKIP；严格编译报 fake.h 没有 CGFloat 声明（9项派生错误）。仅修正本夹具 alpha 为 arm64 对应的 double；同时清除异常用例建树写计数，并强化旧上下文生命周期。没有改生产文件。

2. 修正后重复同一命令：**return 0**；`Ran 2 tests in 9.187s; OK (skipped=1)`。实际严格编译命令（return **0**）：

```sh
/usr/bin/clang -target arm64-apple-ios15.5 -isysroot /opt/theos/sdks/iPhoneOS15.5.sdk -fobjc-arc -fblocks -fsyntax-only -Wall -Wextra -Werror -I/var/minis/shared/ParallelX-alpha455-clone0117-input-diagnostics-20261127/source/Common -I/var/minis/shared/ParallelX-alpha455-clone0117-input-diagnostics-20261127/source/tests/window_input_adapter /var/minis/shared/ParallelX-alpha455-clone0117-input-diagnostics-20261127/source/tests/window_input_adapter/.build-1_zrpb_9/adapter.m
```

3. 强制原生检查：

```sh
PYTHONDONTWRITEBYTECODE=1 PXWM_REQUIRE_NATIVE=1 python3 tests/test_window_input_adapter.py WindowInputAdapter.test_native_foundation_behavior
```

**return 1，预期拒绝**：`AssertionError: native behavior SKIP: macOS Foundation + xcrun required; syntax is not behavior`。没有把环境缺失跳过误记为通过。

4. 模拟 Darwin 且找不到 xcrun 的 Python 闸门测试（仅测试拒绝分支，不是 macOS/行为运行）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import runpy,unittest; from unittest.mock import patch; n=runpy.run_path("tests/test_window_input_adapter.py"); t=n["WindowInputAdapter"]("test_native_foundation_behavior"); r=unittest.TestResult(); p=t.test_native_foundation_behavior.__globals__; ctx=patch.object(p["sys"],"platform","darwin"); ctx.start(); hook=patch.object(p["shutil"],"which",return_value=None); hook.start(); t.run(r); hook.stop(); ctx.stop(); assert len(r.failures)==1 and not r.skipped and not r.errors, r.__dict__; print("SIMULATED_DARWIN_NO_XCRUN rejected; behavior not executed")'
```

**return 0**：断言目标测试产生1个 failure、0 skip、0 error，输出 `SIMULATED_DARWIN_NO_XCRUN rejected; behavior not executed`。

5. `git status --short -- tests/test_window_input_adapter.py tests/window_input_adapter evidence/INPUT-ADAPTER-HANDOFF.md`：失败，`fatal: not a git repository`（git exit 128；工具包装显示32768）。不作为文件未变更证据。

## 通过语法检查的输入指纹

- PXWindowInputDiagnostics.m：`495efb6ed92f90e7190b79734ed675688192d7e8b3064c0879072ea10b1fc006`
- PXWindowInputPolicy.h：`41f1478ba4bd07b4ab5c8305d5e24914bf74683c1e6b6d22fb20de39f363cdc6`
- PXWindowMemoryPolicy.h：`f6e8fbd1f6562cd19cb6ed9a896ad02b50a513a1ff8dd9f9ccb412a29935ba30`
- fake.h：`3d2f91546662139469d8edf684b695c7f28bff4feea0bf7f5259b90dd537f93c`
- cases.m：`93c7b07bb6fcb3d9ddca7f3f10be8a99cbe0f23b3c50a3e63ed856d39330bf8d`

## 下一步/阻断

唯一验收阻断是尚无 macOS Foundation 原生执行证据。父继续优化模块后，必须对最终实际源码重新运行，不能沿用本次指纹的语法结果。在 macOS 本地直接：

```sh
PYTHONDONTWRITEBYTECODE=1 PXWM_REQUIRE_NATIVE=1 python3 tests/test_window_input_adapter.py
```

入口内部使用 `xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation`，不链接 UIKit，逐进程运行6个 case。应取得每条编译/执行 return 0 和6行 `PASS <case> checks=N` 才能声称夹具行为通过；本次没有这些输出。此结果仍不等于设备/CI/安装验收。
