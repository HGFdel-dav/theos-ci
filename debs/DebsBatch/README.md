# DebsBatch

为 Debs（com.iosdump.Debs.Debs）提供「批量上传到我の源」的越狱插件。

## 功能
- 「管理文件」页出现贴底按钮「上传我的源」。
- 面板内多选/全选本地 .deb（来自 Documents/Downloads），选择目标仓库（读取 App 已绑定的 GitHub 仓库，即「源 → 我的越狱源」）与目录（仓库配置的 customPath，如 debs）。
- 逐文件上传：解析包名 → `Package_Version_Arch.deb` 命名（解析失败用原文件名）→ POST git/blobs(201) → 服务器回读校验 SHA（git blob sha1）→ tree/commit/ref 提交到默认分支。
- 「正在批量上传 · 已处理 X/N」+「停止后续文件」；结束后「批量上传逐文件结果」逐文件显示 成功/失败。
- 不自动更新 Packages/Release 索引（与录屏一致），不做批次回滚与自动重试。

## 注入
MobileSubstrate 过滤器：com.iosdump.Debs.Debs

## 构建
theos-ci（roothide arm64e + rootless arm64 双架构）。

## 版本
0.1.0 — 首版：入口按钮 + 批量面板 + git blob 回读校验上传。