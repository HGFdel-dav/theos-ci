# STATUS 0.1.0（本地源码完成，未编译、未安装）

## 数据来源（2026-10-30 直接从用户手机只读取得）

- App：`com.iosdump.Debs.Debs` v8.0，容器 `.../Data/Application/FC0524B5-…`，Bundle `C338CB0A-…/Debs.app`
- App 包里已注入 `Frameworks/B8Selection.dylib`（162387 字节，sha256 与用户提供的 zip 内文件一致）
  → 该 dylib 就是本项目之前那版「批量上传我的源」，说明**注入 dylib 是可行的既有成功路径**
- `Documents/news.plist`：21 条（最新 2026-10-29 22:20），字段
  `{date, isNew, package{id,name,version,architecture,filename,iconPath,maintainer,packageDescription}, source{url{relative},name,iconData}}`
- `Documents/downloaded_metadata.plist`：56 条 `{package{…}, source{…}, fileName}`，落盘命名 `名称-版本-架构.deb`
- `Documents/Downloads/DEBs/`：现存 60 个 deb

## 本机已跑通的验证

| 项目 | 结果 |
| --- | --- |
| 纯 C 单测（`tests/dnb_logic_test.c`，与插件同一份 `DNBLogic.h`） | 通过 94 项 / 失败 0 |
| 静态守卫（`tests/check.py`） | 通过 143 项 / 失败 0 |
| 真实数据端到端（`tests/news_sample_test.py`，21 条真机新闻） | 通过 72 项：地址构造全对 |
| 真实源 HTTP 抽查 | 5/5 HTTP 200，大小 34 KB – 1.9 MB |
| 实际下载校验 | 下到 34192 字节 deb，魔术字节 `!<arch>\n` 正确，落盘名 `QQ图文同发-1.0.6-iphoneos-arm64.deb` |
| 老条目（源已删档）表现 | 两个 8 月条目实测 404 —— 插件会判「失败」而不是存下错误页 |

## 尚未验证（不得当成已通过）

1. 未在 iOS 编译（本地 iSH 不编译 iOS 插件），未出 DEB/dylib 产物
2. 未安装、未真机运行：悬浮按钮落点、面板在 SwiftUI 上的呈现、点按与拖动手感
3. 未验证本项目 dylib 通过 **substrate（deb）** 注入 TrollStore 化 App 是否成功
   （已知可行的是把 dylib 塞进 App 包 `Frameworks/` 那种做法）
4. `downloaded_metadata.plist` 追加记录后 App 列表是否立即刷新，未验证
5. 大量条目连续下载的稳定性与源限流表现，未实测
6. 「覆盖已有」开关、失败重试（当前**不做自动重试**）的真实表现未测

## 下一步（等用户决定）

- A：推 GitHub CI（`Niubiprass/theos-ci` 独立分支，macOS + roothide/theos，SDK 15.5）出 roothide/rootless 双架构 deb，并收 lib*.dylib 供注入式安装
- B：本地 MCP 真机装 Theos 直出（需先在越狱环境装工具链，耗时长）

编译成功 ≠ 运行成功：出包后需用户安装实测，若面板空白/按钮无响应/App 闪退，请给 CrashReporter 日志与 `Documents/debsnewsbatch.log`。
