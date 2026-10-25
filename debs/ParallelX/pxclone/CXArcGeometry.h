// CXArcGeometry.h — 仅移植旧 TWArcGeometry 的原版触发路径；不实现菜单。
#pragma once
#import <UIKit/UIKit.h>
#include <math.h>

static inline UIBezierPath *CXArcTriggerPath(BOOL left, NSInteger mode, CGFloat radius,
                                            CGFloat length, CGFloat height, CGFloat cornerRadius,
                                            CGFloat offsetX, CGFloat offsetY, CGRect bounds) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (CGRectIsEmpty(bounds) || CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) return path;
    offsetX = isfinite(offsetX) ? MIN(MAX(offsetX, 0), CGRectGetWidth(bounds)) : 0;
    offsetY = isfinite(offsetY) ? MIN(MAX(offsetY, 0), CGRectGetHeight(bounds)) : 0;
    CGPoint anchor = CGPointMake(left ? CGRectGetMinX(bounds) + offsetX : CGRectGetMaxX(bounds) - offsetX,
                                 CGRectGetMaxY(bounds) - offsetY);
    if (mode == 1) {
        length = isfinite(length) && length >= 1 ? length : 40;
        height = isfinite(height) && height >= 1 ? height : 40;
        CGFloat w = MIN(length, left ? CGRectGetMaxX(bounds) - anchor.x : anchor.x - CGRectGetMinX(bounds));
        CGFloat h = MIN(height, anchor.y - CGRectGetMinY(bounds));
        if (w <= 0 || h <= 0) return path;
        CGFloat r = isfinite(cornerRadius) && cornerRadius >= 0 ? MIN(cornerRadius, MIN(w, h)) : MIN(12, MIN(w, h));
        // ScreenCore rounds only the inward corner; the two screen edges stay square.
        [path moveToPoint:CGPointZero];
        [path addLineToPoint:CGPointMake(w, 0)];
        [path addLineToPoint:CGPointMake(w, h - r)];
        if (r > 0) [path addArcWithCenter:CGPointMake(w - r, h - r)
                                   radius:r startAngle:0 endAngle:M_PI_2 clockwise:YES];
        [path addLineToPoint:CGPointMake(0, h)];
        [path closePath];
        CGAffineTransform transform = CGAffineTransformMake(left ? 1 : -1, 0, 0, -1,
                                                             anchor.x, anchor.y);
        [path applyTransform:transform];
    } else {
        radius = isfinite(radius) && radius >= 1 ? radius : 40;
        CGFloat start = -M_PI_2;
        CGFloat end = left ? 0 : -M_PI;
        [path moveToPoint:anchor];
        [path addArcWithCenter:anchor radius:radius startAngle:start endAngle:end clockwise:left];
        [path closePath];
    }
    return path;
}
