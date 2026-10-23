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
        CGRect rect = left ? CGRectMake(anchor.x, anchor.y - h, w, h)
                           : CGRectMake(anchor.x - w, anchor.y - h, w, h);
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:r]];
    } else {
        radius = isfinite(radius) && radius >= 1 ? radius : 40;
        // 屏幕坐标系：两个角都从底边向上扫入屏幕，避免左侧变换后跑到屏幕外。
        CGFloat start = -M_PI_2;
        CGFloat end = left ? 0 : -M_PI;
        [path moveToPoint:anchor];
        [path addArcWithCenter:anchor radius:radius startAngle:start endAngle:end clockwise:left];
        [path closePath];
    }
    return path;
}
