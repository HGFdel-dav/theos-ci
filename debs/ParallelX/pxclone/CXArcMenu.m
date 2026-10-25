// CXArcMenu.m — 仅做几何：PX 负责菜单、图标、动画；这里只把它们摆成扇形。
#import "CXArcMenu.h"
#import "CXLog.h"
#import "CXPrefs.h"
#import "CXArcSettings.h"
#import <objc/runtime.h>
#include <math.h>

// points 挂在 icons 数组本身：不依赖 icon.window（图标脱离窗口时仍能命中）
static char CXFanKey;
static char CXFanHitKey;

static CGFloat CXFanNumber(NSString *key, CGFloat fallback) {
    id value = [CXPrefs.shared objectForKey:key] ?: CXArcDefaultValue(key);
    CGFloat number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
    return isfinite(number) ? number : fallback;
}

static BOOL CXFanIsIcon(UIView *v) {
    if (!v || CGRectIsEmpty(v.bounds)) return NO;
    NSString *name = NSStringFromClass(v.class);
    return [name containsString:@"PXPanelIcon"];
}

static NSArray<UIView *> *CXFanScan(UIWindow *window, NSMutableSet<NSValue *> *seen) {
    if (!window) return @[];
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i = 0; i < queue.count && i < 600; i++) {
        UIView *v = queue[i];
        if (!seen) seen = [NSMutableSet set];
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)v];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [queue addObjectsFromArray:v.subviews];
        if (CXFanIsIcon(v)) [icons addObject:v];
    }
    return icons;
}

NSArray<UIView *> *CXFanIcons(UIWindow *window) { return CXFanScan(window, nil); }

NSArray<UIView *> *CXFanIconsInWindows(NSArray<UIWindow *> *windows) {
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSArray<UIView *> *best = @[];
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:UIWindow.class]) continue;
        NSArray<UIView *> *icons = CXFanScan(window, seen);
        if (icons.count > best.count) best = icons;
        if (best.count >= 2) break;
    }
    return best;
}

void CXFanArrange(NSArray<UIView *> *icons, UIWindow *window, BOOL left) {
    if (!icons.count) return;
    UIView *rail = icons.firstObject.superview;
    CGSize size = window ? window.bounds.size : CGSizeZero;
    if (size.width < 100 || size.height < 100) size = UIScreen.mainScreen.bounds.size;
    if (size.width < 100 || size.height < 100) return;

    BOOL landscape = size.width > size.height;
    CGFloat iconSize = MIN(MAX(CXFanNumber(@"CXArcIconSize", 44), 20), 100);
    CGFloat menuScale = CXFanNumber(landscape ? @"CXArcLandscapeMenuScalePercent" : @"CXArcMenuScalePercent", 100) / 100.0;
    menuScale = MIN(MAX(menuScale, 0.5), 4.0);
    CGFloat ringGap = MIN(MAX(CXFanNumber(@"CXArcIconSpacing", 10), 0), 80) * menuScale;
    CGFloat radius = MIN(MAX(CXFanNumber(@"CXArcMenuRadius", 140), 40), 600) * menuScale;
    CGFloat offsetX = MAX(0, CXFanNumber(@"CXArcOffsetX", 0));
    CGFloat offsetY = MAX(0, CXFanNumber(@"CXArcOffsetY", 0));
    CGFloat distance = MAX(0, CXFanNumber(landscape ? @"CXArcLandscapeOffsetDistance" : @"CXArcPortraitOffsetDistance", 0));
    if (landscape) {
        CGFloat horizontal = MAX(0, CXFanNumber(@"CXArcLandscapeHorizontalOffset", 0));
        offsetX += horizontal;
    } else {
        offsetX += distance / M_SQRT2;
        offsetY += distance / M_SQRT2;
    }
    CGFloat edge = MIN(MAX(CXFanNumber(@"CXArcMenuEdgeInset", 0), 0), 160);
    CGPoint anchor = CGPointMake(left ? offsetX - edge : size.width - offsetX + edge,
                                 size.height - offsetY + edge);
    CGFloat start = left ? -M_PI_2 : M_PI;
    CGFloat sweep = M_PI_2;
    if (left && CXFanNumber(@"CXArcMirror", 0) > 0.5) {
        start = 0;
        sweep = -M_PI_2;
    }

    NSInteger first = (NSInteger)MIN(MAX(CXFanNumber(@"CXArcFirstRowItemCount", 5), 1), 20);
    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:icons.count];
    NSInteger remaining = icons.count, index = 0, ring = 0;
    CGFloat rowRadius = radius;
    CGFloat stepOut = iconSize * menuScale + ringGap;
    CGFloat scaledIcon = iconSize * menuScale;
    while (remaining > 0 && ring < 12) {
        NSInteger capacity = first + ring;
        NSInteger n = MIN(remaining, MAX(capacity, 1));
        CGFloat chord = MAX(1, scaledIcon + ringGap);
        CGFloat minStep = 2 * asin(MIN(1.0, chord / MAX(2 * rowRadius, 1)));
        if (minStep > 0.001) n = MIN(n, MAX((NSInteger)floor(fabs(sweep) / minStep) + 1, 1));
        CGFloat inset = asin(MIN(1.0, scaledIcon * 0.5 / MAX(rowRadius, 1)));
        inset = MIN(inset, fabs(sweep) * 0.5);
        CGFloat direction = sweep < 0 ? -1 : 1;
        CGFloat a0 = start + direction * inset;
        CGFloat a1 = start + sweep - direction * inset;
        for (NSInteger i = 0; i < n && index < (NSInteger)icons.count; i++, index++) {
            CGFloat t = n == 1 ? 0.5 : (CGFloat)i / (CGFloat)(n - 1);
            CGFloat angle = a0 + (a1 - a0) * t;
            CGPoint p = CGPointMake(anchor.x + rowRadius * cos(angle), anchor.y + rowRadius * sin(angle));
            CGFloat half = scaledIcon * 0.5 + 2;
            p.x = MIN(MAX(p.x, half), size.width - half);
            p.y = MIN(MAX(p.y, half), size.height - half);
            [points addObject:[NSValue valueWithCGPoint:p]];
            UIView *icon = icons[index];
            UIView *hostView = window ?: icon.window;
            CGPoint local = (rail && hostView && rail != hostView) ? [rail convertPoint:p fromView:hostView] : p;
            icon.center = local;
        }
        remaining -= n;
        rowRadius += stepOut;
        ring++;
    }
    objc_setAssociatedObject(icons, &CXFanKey, points, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(icons, &CXFanHitKey, @(MAX(38.0, scaledIcon * 0.9 + ringGap * 0.5)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CXLog(@"[arc] arranged %lu icons rail=%@ radius=%.0f size=%.0f gap=%.0f scale=%.2f",
          (unsigned long)icons.count, NSStringFromClass(rail.class), radius, scaledIcon, ringGap, menuScale);
}

NSInteger CXFanNearest(NSArray<UIView *> *icons, CGPoint point) {
    if (!icons.count) return -1;
    NSArray<NSValue *> *points = objc_getAssociatedObject(icons, &CXFanKey);
    if (points.count != icons.count) return -1;
    NSInteger best = -1;
    CGFloat bestDistance = [objc_getAssociatedObject(icons, &CXFanHitKey) doubleValue];
    if (bestDistance < 1) bestDistance = 38;
    for (NSInteger i = 0; i < (NSInteger)points.count; i++) {
        CGPoint p = [points[i] CGPointValue];
        CGFloat d = hypot(p.x - point.x, p.y - point.y);
        if (d < bestDistance) { bestDistance = d; best = i; }
    }
    return best;
}
