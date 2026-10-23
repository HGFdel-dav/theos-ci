// CXArcMenu.m — 仅做几何：PX 负责菜单、图标、动画；这里只把它们摆成扇形。
#import "CXArcMenu.h"
#import <objc/runtime.h>
#include <math.h>

static char CXFanKey;

NSArray<UIView *> *CXFanIcons(UIWindow *window) {
    if (!window) return @[];
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i = 0; i < queue.count && i < 300; i++) {
        UIView *v = queue[i];
        [queue addObjectsFromArray:v.subviews];
        if ([NSStringFromClass(v.class) containsString:@"PXPanelIcon"] && !v.hidden && v.alpha > 0.01)
            [icons addObject:v];
    }
    return icons;
}

void CXFanArrange(NSArray<UIView *> *icons, UIWindow *window, BOOL left) {
    if (!icons.count || !window) return;
    CGSize size = window.bounds.size;
    CGFloat anchorX = left ? 6 : size.width - 6;
    CGFloat anchorY = size.height - 6;
    CGFloat start = left ? 1.5 * M_PI : M_PI;
    NSInteger perRing = icons.count > 8 ? 8 : (NSInteger)icons.count;
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)icons.count; i++) {
        UIView *icon = icons[i];
        CGFloat d = MAX(38, icon.bounds.size.width * 0.9);
        NSInteger ring = perRing ? i / perRing : 0;
        NSInteger inRing = perRing ? i % perRing : 0;
        NSInteger count = MIN(perRing, (NSInteger)icons.count - ring * perRing);
        CGFloat radius = 74 + ring * (d + 12);
        CGFloat t = count <= 1 ? 0.5 : (CGFloat)inRing / (CGFloat)(count - 1);
        CGFloat angle = start + (left ? 1 : -1) * (0.02 * M_PI_2 + M_PI_2 * 0.72 * t);
        CGPoint p = CGPointMake(anchorX + radius * cos(angle), anchorY + radius * sin(angle));
        p.x = MIN(MAX(p.x, 20), size.width - 20);
        p.y = MIN(MAX(p.y, 40), size.height - 20);
        icon.center = p; // 不动 transform，PX 自己的高亮缩放照旧
        [points addObject:[NSValue valueWithCGPoint:p]];
    }
    objc_setAssociatedObject(window, &CXFanKey, points, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NSInteger CXFanNearest(NSArray<UIView *> *icons, CGPoint point) {
    if (!icons.count) return -1;
    NSArray<NSValue *> *points = objc_getAssociatedObject(icons.firstObject.window, &CXFanKey);
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
