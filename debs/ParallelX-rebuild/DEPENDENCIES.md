# ParallelX 依赖分析（基于 clone0.24 行为）

## 外部依赖
- Crane >= 1.3（容器管理）
- ScreenCore（可选，若用户同时装则增强交互）

## 核心类职责推断（从 clone0.24 源码）
- PXSceneBridge：窗口管理核心（openApplication:inView:keyboardOverlay:）
- PXPanelEntry：菜单入口（+applicationActivated: / +externalOpenApplication:）
- PXAppRailSelection：菜单条目数据模型
- PXMenuController：菜单 UI 控制器

## 调用链（clone0.24 实证）
点击菜单项 → performConfiguredAction: → Crane 切容器 
→ PXSceneBridge openApplication: → 分屏窗口显示
