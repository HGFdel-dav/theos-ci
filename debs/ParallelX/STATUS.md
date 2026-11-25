# ParallelX alpha455 + clone0.108｜编译修正发布

## 当前授权与阶段
用户本轮明确“可以”批准：仅将已验的107属性最小修正升为clone0.108（版本/诊断标记及对应断言），复核本地门禁、推送、监控CI至结束、独立验包。两项边界策略不改；不包含设备操作、安装、注销或重启。

当前是发布准备阶段，最终CI与DEB结果以项目上层`release/STATUS.md`和`release/RELEASE-RESULT.json`为准。本轮候选108文件，唯一逻辑改动仍是`context.generation`，新四项编译守卫保留，workflow不改。包版本`0.1.0~alpha455+clone0.108`，RootHide arm64e / SDK15.5。

两项已记录边界（generation0未resolved的程序化frame可能预检、普通几何读取局部接受nil bundle）未调整、真机未知；不能称已解决或所有普通路径安全。完整编译/验包不等于首帧真机验收。

## 历史快照：107的本地修正记录
以下记录对应上一阶段，旧“未授权重推”等字样不是当前授权；保留以追溯CI #132失败，不覆盖旧记录。

### ParallelX clone0.107｜CI #132 编译错误的本地最小修正

## 本批授权与阶段
- 用户本轮“继续”批准：只修属性读取、补检查、只读复核两项边界；不包含策略调整、重新提交/推送、CI、安装、设备操作、注销或重启。
- 阶段：`local_compilefix_checked_waiting_push_approval`。新候选在独立目录，旧失败发布树和首版候选保持不变。
- 新原版：`0.1.0~alpha455` RootHide `iphoneos-arm64e`，原包 371280 B，SHA256 `56a7777e73c07632d6c00d521a7c09251bb87c850b23c181071745a5febacde0`。
- 直接来源：失败提交 clone0.107 `b7fb463ce7d2ec19a96b1e3c7c84e813a8caf7e9` 的107文件。CI #132/run45523910145 实跑192测试全过，但正式编译在 `PXWindowMemory.m:154` 失败，未出DEB。
- 版本：`0.1.0~alpha455+clone0.107`。沿用原账号、设置、窗口记忆路径/格式/schema，不新增迁移或清空；分身、付款、设置和作者新功能原样保留。

## 原版变化（只读）
- 16 个作者载荷路径与 alpha451 相同；13 个文件逐字未变。
- `ParallelX.dylib` 754112→754208 B，SHA256 `324e10caca12770671e2c4b35e25c6dc7033939ebdcaf6c439993e9deb2d7389`，有实际代码变化。
- `ParallelXCameraSupport.dylib`、`ParallelXPrefs` 大小不变，所有非签名段逐字节相同，仅 UUID/签名差异。
- Root/Window/System/External/Keyboard/Info/SettingsHelp、PreferenceLoader 配置及三张图标与 alpha451 逐字节相同，自有两条设置入口的叠加仍成立。
- 本轮关注的 7 个宿主/停靠类共 197 个方法，selector 和参数编码未变；开窗、layoutHost、sourceSize、贴边入口未换类或签名。静态证据见 `evidence/native-layout/README.md`。

## 本地候选改动
- 唯一生产改动：`Common/PXWindowMemory.m:154` 的 `context->generation` 改为 `context.generation`。复用本文件既有属性访问方式；没有改判据或其他生产代码。
- 新增 `tests/test_window_memory_context_property.py` 四项检查：抽取完整生产context声明/实现与真实helper，宿主clang仅语法检查；原错误写法和直接访问私有 `_generation` 均被真实编译器拒绝；另检查属性不能当公共字段读。
- 此检查不链接、不产生对象文件、不使用Apple框架或iOS target。已先在未修正源码上真实复现CI同类错误，再修正并通过。
- 旧192项检查不改；现有CI的unittest discover会发现新增四项，无需改workflow。
- 作者vendor、持久化、版本标记、保存/取消/方向/分身/付款/停靠等其他生产代码字节不动。

## 本地检查
- 全套196项：179实跑通过、17项Apple runtime专用跳过；新增四项全部实际执行。
- 普通validate与`--pinned-vendor`均`ALL LOCAL CHECKS PASSED`，alpha455原包/16载荷、双scheme维护脚本等通过。
- 本轮只做宿主C/静态及抽取context的宿主ObjC语法检查；没有完整Apple SDK生产翻译单元编译、链接签名或iOS机器码，也没有新CI/DEB/安装加载/真机验收。

## 边界复核与未解决项
- 撤回旧“完全不影响普通layout”“nil只限首开”的过强结论。generation0未resolved时，程序化frame仍可参与预检；普通geometry局部判据也接纳nil bundle。这两项未在本轮修改。
- 普通move/resize开始会递增generation并置resolved；关闭取消binding，新开绑定前要求canvas/bundle精确相等。但不能据此证明全部异常时序安全；尚未证实标准跨App路径能实际串用记忆。
- 首次可见即恢复的目标仍待验证，源尺寸未知仍等待，不隐藏或猜尺寸。完整编译、UIKit和两项边界真机效果均未验证。
- 本轮重新推送、CI、安装、注销和重启均未获授权；下一闸门单独征求重推并监控CI/验包同意。

## 证据
- 上层`evidence/BASELINE-FAILED-0107.json`、`01-REPRODUCED-OLD-COMPILE-ERROR.log`、`02-PROPERTY-SYNTAX-AND-NEGATIVES.log`、`03-FULL-UNIT.log`、`04-VALIDATE.log`、`05-VALIDATE-PINNED.log`。
- 只读边界报告：上层`evidence/BOUNDARY-REVIEW.md`；最终差异与保护审计：上层`evidence/FINAL-LOCAL-AUDIT.json`。
- 旧失败记录仍位于`ParallelX-alpha455-clone0107-first-frame-20261125/release`；可用回滚仍为已交付clone0.106，本轮未安装。
