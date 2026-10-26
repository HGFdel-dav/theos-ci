// CXWindowLevel.m - ParallelX 可调层级实现
#import "CXWindowLevel.h"
#import "CXPrefs.h"  // 复用你现有的 CXPrefs
#import "CXLog.h"    // 复用你现有的 CXLog

// 默认层级值
static const CGFloat kCXWindowLevelNormal = 0.0;
static const CGFloat kCXWindowLevelHigh = 2046.0;  // ← ScreenCore/Arc-X 的"至高无上"

CXWindowLevelMode CXGetWindowLevelMode(void) {
    id value = [CXPrefs.shared objectForKey:@"CXWindowLevelMode"];
    if ([value isKindOfClass:NSNumber.class]) {
        NSInteger mode = [(NSNumber *)value integerValue];
        if (mode >= 0 && mode <= 2) return (CXWindowLevelMode)mode;
    }
    return CXWindowLevelModeNormal;  // 默认普通模式
}

CGFloat CXGetCustomWindowLevel(void) {
    id value = [CXPrefs.shared objectForKey:@"CXCustomWindowLevel"];
    if ([value isKindOfClass:NSNumber.class]) {
        CGFloat level = [(NSNumber *)value doubleValue];
        // 限制在合理范围：0~3000（超过 3000 可能影响系统安全界面）
        if (level >= 0 && level <= 3000) return level;
    }
    return 46.0;  // 默认自定义值
}

CGFloat CXGetWindowLevel(void) {
    CXWindowLevelMode mode = CXGetWindowLevelMode();
    switch (mode) {
        case CXWindowLevelModeNormal:
            return kCXWindowLevelNormal;
        case CXWindowLevelModeHigh:
            return kCXWindowLevelHigh;
        case CXWindowLevelModeCustom:
            return CXGetCustomWindowLevel();
        default:
            return kCXWindowLevelNormal;
    }
}

void CXApplyWindowLevel(UIWindow *window) {
    if (!window) return;

    // 默认「普通」= 完全不动，保留 PX 原生层级。
    // 早期实现把“普通”当成 level 0，会把 PX 的悬浮面板压到 App 窗口下面，
    // 表现就是回桌面有、一进 App 全部消失且点不到。
    if (CXGetWindowLevelMode() == CXWindowLevelModeNormal) return;

    CGFloat targetLevel = CXGetWindowLevel();
    CGFloat currentLevel = window.windowLevel;
    
    // 如果层级已正确，不重复设置
    if (fabs(currentLevel - targetLevel) < 0.1) {
        return;
    }
    
    window.windowLevel = targetLevel;
    CXLog(@"[CXWindowLevel] 已应用层级到窗口 %@: %.0f (模式=%ld)", 
          NSStringFromClass(window.class), targetLevel, (long)CXGetWindowLevelMode());
}
