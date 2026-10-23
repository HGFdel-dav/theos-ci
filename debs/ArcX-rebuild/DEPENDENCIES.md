# ArcX 1.1.3 依赖分析

## 外部依赖
- ScreenCore >= 2.0.4（提供 SCArcGestureCoordinator）
- SpringBoard（注入目标）

## 核心类职责推断
- AXGestureEnhancer：增强手势灵敏度
- AXTriggerZoneManager：自定义触发区域
- AXAnimationController：动画效果增强
- AXPreferences：独立配置存储

## 调用链
SpringBoard 启动 → AXGestureEnhancer hook SCArcGestureCoordinator 
→ AXTriggerZoneManager 扩展热区 → AXAnimationController 播放动画
