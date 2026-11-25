# ParallelX clone0.108 发布准备与本地修正来源

本轮获准仅升版本/诊断标记到`clone0.108`及同步对应测试，然后复核、推送、监控CI、独立验包；不改两项边界策略，不包含安装/设备操作/注销/重启。当前版本元数据与测试已同步，逻辑修正和新四项编译守卫与已验107编译修正相同。

最终发布状态以项目上层`release/STATUS.md`为准。下文是**前一阶段历史记录**，用于解释修复来源，不代表本轮没有推送授权，也不代表108已完整Apple编译或已真机通过。

## 历史：clone0.107 编译错误的本地最小修正结果

## 本轮范围
用户在CI失败报告后“继续”，只批准属性读取修正、补检查和两项边界只读复核。未批准策略调整、提交/重推、CI、设备/安装/注销/重启。

候选：`/var/minis/shared/ParallelX-alpha455-clone0107-compilefix-20261125/source`。
从失败提交`b7fb463ce7d2ec19a96b1e3c7c84e813a8caf7e9`的107文件冻结复制；旧失败候选、发布树和CI日志不动。CI #132的失败不能被本地通过覆盖。

## 唯一生产改动
`Common/PXWindowMemory.m:154` 将`context->generation`改为`context.generation`，按照本文件既有属性访问方式读取。其余生产代码、version/control、作者载荷、保存规则、路径/schema、方向、取消、分身/付款/贴边行为逐字保留。当前仍为0.107本地修正，不是新发布版本或可安装包。

## 补上的检查与结果
新增`tests/test_window_memory_context_property.py`四项：
1. 抽取完整真实context声明/实现与首帧helper，以宿主clang作ObjC语法检查。
2. 把真实helper改回旧`->generation`，要求编译器拒绝并诊断成员不存在。
3. 改成`->_generation`，要求编译器因私有字段而拒绝。
4. 守卫context属性不能当公共C字段访问，真实公共native字段仍保留。

先在未修源码上真实复现原CI同类报错，修正后四项全部实跑通过。完整回归196项：179实跑通过、17项Apple runtime跳过。普通validate和pinned校验均ALL LOCAL CHECKS PASSED，旧192项测试代码未改。

新增检查仅用类型桩替代框架声明，不使用Foundation/UIKit、iOS target，不生成对象或iOS机器码；它证明这处ObjC语法得到纠正，不等于完整Apple SDK生产编译、链接签名或真机功能成功。现有CI测试发现规则会自动运行四项，不需要改workflow。

## 两项边界只读复核
- 首帧helper接纳generation0且未resolved的bound context，不是一次性opening-ticket锁；未递增generation的程序化frame可能继续预检。用户move/resize开始会递增generation、置resolved并撤initialTarget，但这不能证明所有程序化layout安全。
- 普通PXWMReadGeometry的局部bundleMatches接纳nil，并非只有首开参数才允许。标准新开流程先取消旧binding，且新binding前要求canvas/bundle精确匹配；标准跨App实际串用未证实。异常时序仍未知。
- 因此撤回原本地报告“不影响普通layout”“nil只限首开”的过强表述。本轮没有顺手改这两项策略，也没有把复核当作安全验收。

## 尚未完成
没有重新提交/推送、CI、DEB、安装、设备操作、注销重启；“首次可见即记忆尺寸”仍未获真机验证。下一步须另获重推+监控CI+验包批准；构建前版本闸门仍须处理，安装/注销/重启分别另问。

证据位于候选上层`evidence/`；总报告见上层`LOCAL-RESULT.md`、`STATUS.md`。
