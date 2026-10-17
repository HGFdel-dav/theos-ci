# DebsBatch — 把「批量上传我的源」内置进 Debs App

将录屏演示的「批量上传」功能直接做进 Debs（com.iosdump.Debs.Debs）的修改版 IPA，
装上就是带功能的 App，**不需要安装任何插件**（无 substrate/Logos 依赖）。

## 原理
1. 功能代码编译为动态库 `libDebsBatch.dylib`（纯 UIKit/Foundation，零三方依赖）。
2. 把 dylib 放入 `Debs.app/Frameworks/`，用 insert_dylib 给主二进制加入
   `LC_LOAD_DYLIB` 加载项，ldid 重签。
3. 重新打包为 IPA：装上「管理文件」页出现贴底按钮「上传我的源」。

## 功能
- 「管理文件」页贴底按钮「上传我的源」。
- 面板内多选/全选本地 .deb（Documents/Downloads 递归扫描），选择目标仓库
  （读取 App 自己绑定的 managed_github_repos.plist，即「源 → 我的越狱源」）与目录。
- 逐文件上传：解析包名 → `Package_Version_Arch.deb` 命名 → POST git/blobs(201)
  → 服务器回读校验（git blob sha1）→ 增量 tree → commit → 更新分支引用。
- 「正在批量上传 · 已处理 X/N」+「停止后续文件」；结束显示逐文件成功/失败明细。
- 不自动更新 Packages/Release 索引（与录屏一致）。

## 构建
- 原版 IPA：`ipa/Debs_v8.0.ipa`（App Store 版 v8.0）。
- CI workflow：`.github/workflows/build-debsbatch-ipa.yml`，监听 `tools/DebsBatchLib/**`，
  产物为 artifact `DebsBatch-0.1.0-ipa`（修改版 IPA）。
- 安装：TrollStore 直接装 IPA；RootHide/Dopamine 用户可同样方式侧载。

## 版本
0.1.0 — 首版：入口按钮 + 批量面板 + git blob 回读校验上传。