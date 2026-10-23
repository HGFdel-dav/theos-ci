// CXArcMenu.m — 仅做几何：PX 负责菜单、图标、动画；这里只把它们摆成扇形。
#import "CXArcMenu.h"
#import "CXLog.h"
#import "CXPrefs.h"
#import <objc/runtime.h>
#include <math.h>

// points 挂在 icons 数组本身：不依赖 icon.window（图标脱离窗口时仍能命中）
static char CXFanKey;

static BOOL CXFanIsIcon(UIView *v) {
    if (!v || v.hidden || v.alpha <= 0.01 || CGRectIsEmpty(v.bounds)) return NO;
    NSString *name = NSStringFromClass(v.class);
    BOOL named = [name containsString:@"PXPanelIcon"];
    return named;
}

static NSArray<UIView *> *CXFanScan(UIWindow *window, NSMutableSet<NSValue *> *seen) {
    if (!window || window.hidden) return @[];
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i = 0; i < queue.count && i < 600; i++) {
        UIView *v = queue[i];
        if (!seen) { seen = [NSMutableSet set]; }
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [queue addObjectsFromArray:v.subviews];
        if (CXFanIsIcon(v)) [icons addObject:v];
    }
    return icons;
}

NSArray<UIView *> *CXFanIcons(UIWindow *window) {
    return CXFanScan(window, nil);
}

NSArray<UIView *> *CXFanIconsInWindows(NSArray<UIWindow *> *windows) {
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSArray<UIView *> *best = @[];
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:UIWindow.class]) continue;
        NSArray<UIView *> *icons = CXFanScan(window, seen);
        if (icons.count > best.count) best = icons;
        if (best.count >= 2) break; // 面板窗拿到就停，不去扫手柄条/宿主窗
    }
    return best;
}

void CXFanArrange(NSArray<UIView *> *icons, UIWindow *window, BOOL left) {
    if (!icons.count) return;
    // 不修改 PX 的 rail 锚点和 position；那会与原版布局动画互相覆盖。
    UIView *rail = icons.firstObject.superview;
    CGSize size = window ? window.bounds.size : CGSizeZero;
    if (size.width < 100 || size.height < 100) size = UIScreen.mainScreen.bounds.size;
    if (size.width < 100 || size.height < 100) return;
    id radiusObject = [CXPrefs.shared objectForKey:@"CXArcRadius"];
    id offsetXObject = [CXPrefs.shared objectForKey:@"CXArcOffsetX"];
    id offsetYObject = [CXPrefs.shared objectForKey:@"CXArcOffsetY"];
    CGFloat radiusSetting = [radiusObject isKindOfClass:NSNumber.class] ? [(NSNumber *)radiusObject doubleValue] : 86;
    CGFloat offsetX = [offsetXObject isKindOfClass:NSNumber.class] ? [(NSNumber *)offsetXObject doubleValue] : 0;
    CGFloat offsetY = [offsetYObject isKindOfClass:NSNumber.class] ? [(NSNumber *)offsetYObject doubleValue] : 0;
    if (radiusSetting < 1) radiusSetting = 86;
    CGFloat anchorX = left ? offsetX : size.width - offsetX;
    CGFloat anchorY = size.height - offsetY;
    anchorX += left ? offsetX : -offsetX;
    anchorY -= offsetY;
    CGFloat radiusBase = MAX(54, radiusSetting);
    CGFloat start = left ? -M_PI_2 : -M_PI;
    NSInteger perRing = icons.count > 8 ? 8 : (NSInteger)icons.count;
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)icons.count; i++) {
        UIView *icon = icons[i];
        CGFloat d = MAX(38, icon.bounds.size.width * 0.9);
        NSInteger ring = perRing ? i / perRing : 0;
        NSInteger inRing = perRing ? i % perRing : 0;
        NSInteger count = MIN(perRing, (NSInteger)icons.count - ring * perRing);
        CGFloat radius = radiusBase + ring * (d + 12);
        CGFloat t = count <= 1 ? 0.5 : (CGFloat)inRing / (CGFloat)(count - 1);
        CGFloat angle = start + (left ? 1 : -1) * (0.02 * M_PI_2 + M_PI_2 * 0.72 * t);
        CGPoint p = CGPointMake(anchorX + radius * cos(angle), anchorY + radius * sin(angle));
        p.x = MIN(MAX(p.x, 20), size.width - 20);
        p.y = MIN(MAX(p.y, 40), size.height - 20);
        UIView *hostView = window ?: icon.window;
        [points addObject:[NSValue valueWithCGPoint:p]];
        CGPoint local = (rail && hostView && rail != hostView) ? [rail convertPoint:p fromView:hostView] : p;
        icon.center = local;
    }
    objc_setAssociatedObject(icons, &CXFanKey, points, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CXLog(@"[arc] arranged %lu icons rail=%@", (unsigned long)icons.count, NSStringFromClass(rail.class));
}

NSInteger CXFanNearest(NSArray<UIView *> *icons, CGPoint point) {
    if (!icons.count) return -1;
    NSArray<NSValue *> *points = objc_getAssociatedObject(icons, &CXFanKey);
    if (points.count != icons.count) return -1;
    NSInteger best = -1;
    CGFloat bestDistance = 38;
    for (NSInteger i = 0; i < (NSInteger)points.count; i++) {
        CGPoint p = [points[i] CGPointValue];
        CGFloat d = hypot(p.x - point.x, p.y - point.y);
        if (d < bestDistance) { bestDistance = d; best = i; }
    }
    return best;
}
