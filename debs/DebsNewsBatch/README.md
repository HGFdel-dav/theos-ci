# DebsNewsBatch 0.1.0

给 Debs（com.iosdump.Debs.Debs）加一个**「新闻批量下载」**：在 App 里点右下角悬浮按钮 → 打开我们自己的面板 → 勾选新闻条目 → 一次性把它们对应的 deb 全部下到 `Documents/Downloads/DEBs/`。

不是改 App 源码，也不是重打包 IPA：**注入一个 dylib**（和现在 App 里那个 `Frameworks/B8Selection.dylib` 同一个路子）。网络功能只在我们自己的代码里走，**没有 Hook 任何原生方法**。

## 功能

- 悬浮按钮「批量下载」（可拖动，位置会记住；长按有菜单：重置位置 / 查看日志 / 隐藏按钮）
- 面板列表：包名 + 版本、架构、来源名、该条 deb 是否已存在本机
- 筛选：全部 / arm64 / arm64e / 仅未下载（对应 Debs 自己的架构分类）
- 选择：全选 / 全不选（按当前筛选范围）/ 点行切换
- 批量下载：串行逐条下载（不并发轰源），每条显示 未下载 / 下载中 / 完成 / 失败 / 跳过 / 已取消，底部有总进度与「成功 x 失败 y 跳过 z」
- 校验：HTTP 状态非 200 直接判失败；落盘前检查 deb 魔术字节 `!<arch>\n`，是 HTML 错误页/空文件就删掉并记失败
- 去重：同名文件已存在时默认**跳过**，可在面板里开「覆盖已有」
- 下载记录：默认写回 App 自己的 `Documents/downloaded_metadata.plist`（结构与原生条目一致，写前备份 `.bak`，可关闭）
- 日志：App 容器 `Documents/debsnewsbatch.log`（自动截断，上限 1MB）

## 文件落点（全部在 App 自己的容器里）

| 用途 | 路径 |
| --- | --- |
| 读新闻 | `NSHomeDirectory()/Documents/news.plist` |
| 存 deb | `NSHomeDirectory()/Documents/Downloads/DEBs/<名称>-<版本>-<架构>.deb` |
| 下载记录 | `NSHomeDirectory()/Documents/downloaded_metadata.plist` |
| 日志 | `NSHomeDirectory()/Documents/debsnewsbatch.log` |
| 按钮位置 | App 容器内 `com.niubiprass.debsnewsbatch` suite（不是 `standardUserDefaults`，不动 App 自己的偏好） |

## RootHide / 越狱侧约定

- 不往 `/var/mobile/Library/Preferences/` 写任何东西（也就没有 `.jbroot-*` 动态根的适配负担）
- 不碰 `/var/jb`、不碰 App 沙盒以外的任何路径，不需要任何私有 API 或 SpringBoard Hook
- 代码里零硬编码容器 UUID，路径全靠 `NSHomeDirectory()` 运行时解析（静态守卫会拦住硬编码）

## 目录

```
Makefile                 Theos tweak 工程（ARC、iOS 15.5 SDK、arm64+arm64e）
control / DebsNewsBatch.plist
DebsNewsBatch/
  DNBLogic.h             纯 C 逻辑层（URL 拼接 / 落盘命名 / 架构筛选 / deb 魔术字节 / 多选），插件与单测编译同一份
  DNBCommon.{h,m}        路径与日志
  DNBNewsItem.{h,m}      news.plist 条目模型
  DNBNewsStore.{h,m}     读新闻、去重排序、筛选、已下载判断、写下载记录
  DNBDownloader.{h,m}    串行下载队列 + 校验 + 落盘 + 记录
  DNBPanelViewController.{h,m}  面板 UI
  DNBFloatingButton.{h,m}        悬浮按钮 + 面板呈现
  Tweak.m                注入入口（只有构造函数，没有 %hook）
tests/
  check.py               静态守卫（143 项）
  dnb_logic_test.c       纯 C 单测（94 项，本机 cc 直接跑）
  news_sample_test.py    拿真机导出的 news.plist 生成用例并跑，顺带对真实源做 HTTP 校验
```

## 本地怎么自测（iSH 里就能跑，不需要真机）

```sh
cc -Wall -Wextra -Werror -IDebsNewsBatch tests/dnb_logic_test.c -o /tmp/t && /tmp/t
python3 tests/check.py
python3 tests/news_sample_test.py <news.plist>      # 真实数据 + 真实源 HTTP
```

## 已知边界（务必先看）

- **未在真机运行过**：源码与静态/逻辑测试全绿，但界面观感、悬浮按钮位置、SwiftUI 覆盖层交互都要装上去实测
- 新闻里的**老条目对应的 deb 可能已被源删档**（实测有 404），这类会记「失败」，属正常
- 下载是串行的，条目多时耗时较长，中途可「停止」
- 写 `downloaded_metadata.plist` 是**尽力而为**：App 自己在内存里也持有一份，若之后它整体重写该文件，我们追加的记录可能被覆盖（文件本身仍在，不影响下载结果）
- 如果 Debs 更新版本改了 `news.plist` 的结构，需要跟着调整 `DNBNewsItem` / `DNBNewsStore`
