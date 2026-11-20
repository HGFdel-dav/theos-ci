<div align="center">

# HGFdel-dav · iOS Tweaks

**面向 iOS 定制固件的插件、工具与实验项目**

`Theos`　`RootHide`　`Rootless`　`GitHub Actions`

[项目目录](https://github.com/HGFdel-dav/theos-ci/tree/main/debs)　·　[构建包](https://github.com/HGFdel-dav/theos-ci/tree/main/packages)　·　[CI 构建记录](https://github.com/HGFdel-dav/theos-ci/actions)

</div>

> 项目功能、兼容性与验证状态因版本而异。首页只摘录仓库现有说明；未标注真机验收的项目，不表示已在设备验证。

## 精选项目

<table>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 多任务与窗口</sub></p><h3><a href="documentation/projects/parallelx.md">ParallelX</a></h3><p>分屏与分身相关组件；当前包说明标注 Alpha 391，并提及 Crane 分身集成。</p><p><a href="documentation/projects/parallelx.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/ParallelX">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>插件 · 多任务与窗口</sub></p><h3><a href="documentation/projects/twin.md">Twin</a></h3><p>分屏增强套件；包说明提到 Arc 唤醒、Crane 分身与窗口尺寸记忆。</p><p><a href="documentation/projects/twin.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/Twin">源码目录</a></p></td>
</tr>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 应用体验</sub></p><h3><a href="documentation/projects/choicywhitelist.md">ChoicyWhitelist</a></h3><p>Choicy 的 RootHide 改版：默认禁用注入，通过手动放行管理规则。</p><p><a href="documentation/projects/choicywhitelist.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/ChoicyWhitelist">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>插件 · 自动化与续期</sub></p><h3><a href="documentation/projects/shanlianrenew.md">ShanLianRenew</a></h3><p>闪连相关续期辅助插件。</p><p><a href="documentation/projects/shanlianrenew.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/ShanLianRenew">源码目录</a></p></td>
</tr>
</table>

<details><summary><strong>多任务与窗口</strong>　3 个项目</summary>

<table>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 多任务与窗口</sub></p><h3><a href="documentation/projects/splitx.md">SplitX</a></h3><p>弧形唤醒与窗口分屏整合面板。</p><p><a href="documentation/projects/splitx.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/SplitX">源码目录</a></p></td>
<td width="50%"></td>
</tr>
</table>

</details>

<details><summary><strong>系统界面</strong>　2 个项目</summary>

<table>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 系统界面</sub></p><h3><a href="documentation/projects/cleanstatus.md">CleanStatus</a></h3><p>状态栏图标显示控制与内联电池控件。</p><p><a href="documentation/projects/cleanstatus.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/CleanStatus">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>插件 · 系统界面</sub></p><h3><a href="documentation/projects/minisight.md">MiniSight</a></h3><p>SpringBoard 顶部胶囊提示 Minis 正在操作手机。</p><p><a href="documentation/projects/minisight.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/MiniSight">源码目录</a></p></td>
</tr>
</table>

</details>

<details><summary><strong>系统工具</strong>　2 个项目</summary>

<table>
<tr>
<td width="50%" valign="top"><p><sub>辅助组件 · 系统工具</sub></p><h3><a href="documentation/projects/minisagentdaemon.md">MinisAgentDaemon</a></h3><p>Minis tweak 开发流程使用的特权安装辅助组件。</p><p><a href="documentation/projects/minisagentdaemon.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/MinisAgentDaemon">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>插件 · 系统工具</sub></p><h3><a href="documentation/projects/insulation.md">Insulation</a></h3><p>温控模式管理；包说明列出 off、low、max、status 命令。</p><p><a href="documentation/projects/insulation.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/insulation">源码目录</a></p></td>
</tr>
</table>

</details>

<details><summary><strong>应用体验</strong>　4 个项目</summary>

<table>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 应用体验</sub></p><h3><a href="documentation/projects/reynarddefault.md">ReynardDefault</a></h3><p>将 Safari 发起的网页打开请求转交 Reynard；README 还描述浏览器内点击链接交接。</p><p><a href="documentation/projects/reynarddefault.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/ReynardDefault">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>插件 · 应用体验</sub></p><h3><a href="documentation/projects/dyyy.md">DYYY</a></h3><p>抖音界面与交互定制插件。</p><p><a href="documentation/projects/dyyy.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/DYYY">源码目录</a></p></td>
</tr>
<tr>
<td width="50%" valign="top"><p><sub>插件 · 应用体验</sub></p><h3><a href="documentation/projects/timcleankit.md">TIMCleanKit</a></h3><p>TIM 客户端增强与设置工具。</p><p><a href="documentation/projects/timcleankit.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/TIMCleanKit">源码目录</a></p></td>
<td width="50%"></td>
</tr>
</table>

</details>

<details><summary><strong>实验与参考</strong>　2 个项目</summary>

<table>
<tr>
<td width="50%" valign="top"><p><sub>实验项目 · 实验与参考</sub></p><h3><a href="documentation/projects/routepilot.md">RoutePilot</a></h3><p>按应用维护直连名单的项目脚手架；目前没有实际改变数据包路由。</p><p><a href="documentation/projects/routepilot.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/RoutePilot">源码目录</a></p></td>
<td width="50%" valign="top"><p><sub>参考材料 · 实验与参考</sub></p><h3><a href="documentation/projects/insulation-rh3.md">Insulation RH3</a></h3><p>温控相关参考/基线材料；没有 Makefile，不属于通用批量构建项目。</p><p><a href="documentation/projects/insulation-rh3.md">项目说明</a>　·　<a href="https://github.com/HGFdel-dav/theos-ci/tree/main/debs/insulation-rh3">源码目录</a></p></td>
</tr>
</table>

</details>

## 项目与构建

- 每个项目可进入单独说明页；源码链接直达当前项目目录。
- `packages/` 是现有构建产物快照；不同版本不是可互换副本。
- CI 构建通过不等于设备安装、加载或运行验收。
- 没有 README 的目录，其介绍页会标明仅据包元数据/目录结构整理。

