// TWArcGeometry.m
// 角落版几何（0.4.0）。UIKit 坐标（y 向下）：角度 0 = 向右，π/2 = 向下。
// 每个角落的扇形都朝屏幕内侧展开：右下 [π, 1.5π]，左下 [1.5π, 2π]，
// 左上 [0, π/2]，右上 [π/2, π]。
#import "TWArcGeometry.h"
#import <math.h>

static const CGFloat kTWSweepAngle = M_PI_2;   // 扇形总角度：一个象限
static const CGFloat kTWTopInset = 28;         // 状态栏 / 刘海区不触发
static const CGFloat kTWBottomInset = 28;      // Home 条区不触发

@implementation TWArcGeometry

+ (CGFloat)sweepAngle { return kTWSweepAngle; }

+ (CGFloat)startAngleForCorner:(NSInteger)corner {
    switch (corner) {
        case TWCornerBottomRight: return M_PI;          // 往左
        case TWCornerBottomLeft:  return 1.5 * M_PI;    // 往上
        case TWCornerTopLeft:     return 0;             // 往右
        case TWCornerTopRight:    return M_PI_2;        // 往下
        default: return M_PI;
    }
}

+ (NSInteger)cornerAtPoint:(CGPoint)point corners:(NSInteger)cornersMask size:(CGFloat)size bounds:(CGRect)bounds {
    if (!isfinite(point.x) || !isfinite(point.y) || !isfinite(size) || size <= 0) return -1;
    CGFloat w = CGRectGetWidth(bounds), h = CGRectGetHeight(bounds);
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return -1;
    CGFloat s = MIN(size, MIN(w, h) / 3.0);
    CGRect areas[4];
    areas[TWCornerBottomRight] = CGRectMake(w - s, h - kTWBottomInset - s, s, s);
    areas[TWCornerBottomLeft]  = CGRectMake(0,     h - kTWBottomInset - s, s, s);
    areas[TWCornerTopLeft]     = CGRectMake(0,     kTWTopInset,           s, s);
    areas[TWCornerTopRight]    = CGRectMake(w - s, kTWTopInset,           s, s);
    for (NSInteger corner = 0; corner < 4; corner++) {
        if (!(cornersMask & (1 << corner))) continue;
        if (CGRectContainsPoint(areas[corner], point)) return corner;
    }
    return -1;
}

+ (CGPoint)anchorForCorner:(NSInteger)corner margin:(CGFloat)margin bounds:(CGRect)bounds {
    CGFloat w = CGRectGetWidth(bounds), h = CGRectGetHeight(bounds);
    if (!isfinite(margin) || margin < 0) margin = 34;
    switch (corner) {
        case TWCornerBottomLeft:  return CGPointMake(margin, h - margin);
        case TWCornerTopLeft:     return CGPointMake(margin, margin);
        case TWCornerTopRight:    return CGPointMake(w - margin, margin);
        case TWCornerBottomRight:
        default:                  return CGPointMake(w - margin, h - margin);
    }
}

+ (CGFloat)maxRadiusForCorner:(NSInteger)corner anchor:(CGPoint)anchor margin:(CGFloat)margin bounds:(CGRect)bounds {
    CGFloat w = CGRectGetWidth(bounds), h = CGRectGetHeight(bounds);
    CGFloat toLeft = anchor.x - margin;
    CGFloat toRight = w - anchor.x - margin;
    CGFloat toTop = anchor.y - margin;
    CGFloat toBottom = h - anchor.y - margin;
    switch (corner) {
        case TWCornerBottomLeft:  return MAX(0, MIN(toRight, toTop));
        case TWCornerTopLeft:     return MAX(0, MIN(toRight, toBottom));
        case TWCornerTopRight:    return MAX(0, MIN(toLeft, toBottom));
        case TWCornerBottomRight:
        default:                  return MAX(0, MIN(toLeft, toTop));
    }
}

+ (CGFloat)itemSizeForCount:(NSInteger)count radius:(CGFloat)radius menuScale:(CGFloat)scale {
    scale = isfinite(scale) && scale > 0 ? scale : 1;
    NSInteger n = MAX(count, 2);
    CGFloat step = kTWSweepAngle / (CGFloat)(n - 1);
    CGFloat chord = 2 * fabs(radius) * sin(step / 2);
    // √2 兜住正方形图标任意角度，1.18 兼顾高亮放大。
    return MAX(0, MIN(78, (chord - 6) / (M_SQRT2 * 1.18 * scale)));
}

+ (CGFloat)radiusForItemCount:(NSInteger)count preferredRadius:(CGFloat)radius menuScale:(CGFloat)scale corner:(NSInteger)corner bounds:(CGRect)bounds {
    scale = isfinite(scale) && scale > 0 ? scale : 1;
    radius = isfinite(radius) && radius > 0 ? radius : 150;
    NSInteger n = MAX(count, 2);
    CGFloat step = kTWSweepAngle / (CGFloat)(n - 1);
    // 1) 排得下：按 48pt 图标的弦长反推理想半径。
    CGFloat desired = (48 * scale * M_SQRT2 * 1.18 + 6) / (2 * sin(step / 2));
    // 2) 不出屏：先粗估 margin 限一次，再按图标实际直径收紧一次。
    CGFloat margin = 34;
    CGFloat cap = [self maxRadiusForCorner:corner anchor:[self anchorForCorner:corner margin:margin bounds:bounds] margin:margin bounds:bounds];
    CGFloat r = MIN(MAX(radius, desired), cap);
    CGFloat size = [self itemSizeForCount:count radius:r menuScale:scale];
    if (size > 0) {
        CGFloat margin2 = size * scale * 1.18 / 2 + 10;
        CGFloat cap2 = [self maxRadiusForCorner:corner anchor:[self anchorForCorner:corner margin:margin2 bounds:bounds] margin:margin2 bounds:bounds];
        r = MIN(r, cap2);
    }
    return MAX(0, r);
}

+ (CGPoint)centerForItemAtIndex:(NSInteger)index count:(NSInteger)count radius:(CGFloat)radius anchor:(CGPoint)anchor corner:(NSInteger)corner bounds:(CGRect)bounds {
    NSInteger n = MAX(count, 2);
    CGFloat step = kTWSweepAngle / (CGFloat)(n - 1);
    CGFloat angle = [self startAngleForCorner:corner] + (CGFloat)index * step;
    return CGPointMake(anchor.x + radius * cos(angle), anchor.y + radius * sin(angle));
}

@end