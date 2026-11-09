# CleanStatus 0.3.1 动画子页面入口修复：本地候选

## 当前授权
用户在只读核查结论后明确说「修复」，随后明确说「推送」。本轮已授权本候选 commit/push/CI 和下载验包；仍未授权安装、注销、重启或设备配置写入。旧版安装/推送结果不扩展到本候选。

## 故障与已核对事实
- 手机实装0.3.0；设置 → 状态栏 → 动画效果，显示 preference bundle loading error / (null)。
- preferenceloader.top 2.2.8-2；手机设置包的类/资源齐全，代码与交付一致。之前记录“未安装”已过时。
- 主因高度疑似同包子页面错误带 bundle 字段；实装 Choicy/ParallelX 和公开成熟源码均不带此字段。实装 libprefs 错误分支匹配已查源码，但未取得点击时实际 lazy bundle path，仍不称真机定因。
- 证据报告：../CleanStatus-animation-0.3.0/research/panel-load-audit/REPORT.md（从项目父目录 shared 起）。

## 基线与改动
- 0.3.0精确提交：a470c85eada0a7e3e3ae670d4d9f6a66007fa3da。该版CI159/42601772989成功，但真机动画设置入口失败。
- 隔离工作目录：/var/minis/shared/CleanStatus-panel-0.3.1/source。
- 对照基线：../research/baseline-0.3.0；旧0.2.5保护清单：docs/BASELINE-0.2.5-PROTECTED.json。
- LocalCleanStatusRoot.plist 的动画入口、LocalCleanStatusAnimations.plist 的高级入口，各仅删除 bundle=LocalCleanStatusPrefs；保留 detail/isController。
- 顶层 PreferenceLoader entry、原控制器、原24项设置、所有动画实现和保存/通知/恢复代码保持。
- 包control和设置包Info版本升0.3.1；核验工具同步版本并添加两级入口正反例。原系统操作模块的代码和版本保持原样。

## 已完成的本地检查
- 原功能0.2.5的31份 .h/.m/.xm 哈希一致；0.3.0的49份 .h/.m/.xm/.c 文件全部逐字节一致。
- 两个设置资源的语义差异仅为各删除一个bundle字段；顶层入口文件逐字节一致。
- 原0.3.0实际入口被新增检查拒绝；修复候选通过。入口、错误detail、缺资源、缺类、误删顶层bundle等10个正反例通过。
- 核心5,252,881项、控制中心策略658项、源不变量354项、路径模型37例、Mach-O核验器46例通过。
- 动画参数/关闭门控、数学/接口编码测试和46文件括号检查通过。以上均为本地静态/便携检查。
- 新入口检查已接入tools/check.py及verify_deb.py；以后验实际DEB中的入口，而不只查源码资源存在。

## 未验证与下一步
- 未编译iOS、未触发CI、无0.3.1 DEB、未安装/注销/重启。
- 真实设置页面打开、进入高级页及返回、自动保存到运行端效果、开关关闭恢复仍需安装后单独验收。
- 动画接口及第三方插件共存的旧未验证项全部保留，不以本次入口静态修复声称解决。
- 待用户单独确认推送0.3.1候选；构建验包后另问安装，注销/重启另问。
