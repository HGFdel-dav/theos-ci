# DebsNewsBatch 0.2.0

给 Debs（`com.iosdump.Debs.Debs`）的**新闻页**底部加一条蓝条「新闻批量下载 · 选择软件包」。
点它 → 列表进入选择态（每行左侧出勾选圈）→ 直接在新闻列表里勾要下的包 → 条上点「下载」，一次全部下到 `Documents/Downloads/DEBs/`。

不改 App 源码、不重打包：注入一个 dylib。**零 Hook 原生方法**（只用 runtime 挂 `viewDidAppear`/`viewWillDisappear` 来决定什么时候贴条），**零 substrate 依赖**，可以直接 TrollFools 注入。

## 交互

1. 进「新闻」页 → 底部出现蓝条「新闻批量下载 · 选择软件包」
2. 点蓝条 → 选择态：每行左边出勾选圈，点行即选中/取消（**不会跳进详情**，想进详情先点「取消」）
3. 条上可以「全选」（按当前筛选/搜索后的整个列表，不只可见行）、「取消」、「下载」
4. 下载中：行右侧显示「下载中 / 完成 / 失败 / 已存在」，条上显示 `下载中 x/y · 成功 a 失败 b`，可「停止」
5. 结束显示汇总；点「完成」回到蓝条初始态
6. 长按蓝条：打开批量面板（旧版界面，作为兜底）/ 查看日志

App 自己的架构筛选条、搜索框照旧生效——你在列表里看到什么，就能选什么。

## 下载行为（沿用 0.1.x 已测过的下载器）

- 串行逐条下载，不并发轰源
- HTTP 非 200 判失败；落盘前验 deb 魔术字节 `!<arch>\n`，HTML 错误页/空文件删掉记失败
- 同名已存在默认跳过（不覆盖）
- 下载记录写回 `Documents/downloaded_metadata.plist`（结构同原生条目，写前 `.bak`）
- 日志 `Documents/debsnewsbatch.log`（上限 1MB）

## 文件落点（全在 App 自己的容器里）

| 用途 | 路径 |
| --- | --- |
| 读新闻 | `NSHomeDirectory()/Documents/news.plist` |
| 存 deb | `NSHomeDirectory()/Documents/Downloads/DEBs/<名称>-<版本>-<架构>.deb` |
| 下载记录 | `NSHomeDirectory()/Documents/downloaded_metadata.plist` |
| 日志 | `NSHomeDirectory()/Documents/debsnewsbatch.log` |

RootHide 侧：不写 `/var/mobile/Library/Preferences`，不碰 `/var/jb`，路径全靠 `NSHomeDirectory()`，零硬编码 UUID。

## 目录

```
Makefile / control / DebsNewsBatch.plist
DebsNewsBatch/
  DNBLogic.h                 纯 C 逻辑层（URL / 命名 / 过滤 / deb 魔术字节 / 选择 / 行标签解析），插件与单测共用
  DNBHook.{h,m}              只用 runtime 的实例方法挂钩（不链接 substrate）
  DNBNewsBarView.{h,m}       底部条（初始 / 选择 / 下载中 / 完成 四态）
  DNBRowTarget.{h,m}         盖在行上的勾选控件（圈 + 状态字）
  DNBSelectionController.{h,m}  列表发现、勾选集合、全选、下载编排、跟随滚动
  DNBCommon.{h,m}            路径与日志
  DNBNewsItem / DNBNewsStore / DNBDownloader   数据与串行下载
  DNBPanelViewController / DNBFloatingButton   旧面板（长按兜底，悬浮按钮默认不再显示）
  Tweak.m                    入口：挂 viewDidAppear / viewWillDisappear
tests/
  check.py                   静态守卫（195 项）
  dnb_logic_test.c           纯 C 单测（129 项，含行标签解析）
  news_sample_test.py        真机 news.plist 数据 + 真实源 HTTP
```

## 本地自测（iSH 就能跑）

```sh
cc -Wall -Wextra -Werror -IDebsNewsBatch tests/dnb_logic_test.c -o /tmp/t && /tmp/t
python3 tests/check.py
```

## 已知边界

- **未在真机验证过这一版的列表内选择**（0.1.0 的面板版真机可用）。选择圈的位置/滚动跟随/SwiftUI 单元格取词都要装上实测；日志会打印「新闻页已挂载 scroll=… 行数=…」
- 若某个 Debs 版本的新闻行不再暴露「名称, 变更, 版本, 架构, 来源」这样的可访问标签，勾选圈会贴不出来 —— 此时长按蓝条走旧面板
- 老条目对应的 deb 可能已被源删档（实测有 404），会记失败，属正常
