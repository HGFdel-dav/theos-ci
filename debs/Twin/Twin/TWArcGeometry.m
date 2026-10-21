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

// Trigger anchor verified against SCArcTriggerAnchorPoint (sc_geom.s).
+ (CGPoint)triggerAnchorForCorner:(NSInteger)corner offsetX:(CGFloat)x offsetY:(CGFloat)y bounds:(CGRect)bounds {
    x = isfinite(x) ? MIN(MAX(x, 0), CGRectGetWidth(bounds)) : 0;
    y = isfinite(y) ? MIN(MAX(y, 0), CGRectGetHeight(bounds)) : 0;
    BOOL left = corner == TWCornerBottomLeft || corner == TWCornerTopLeft;
    BOOL top = corner == TWCornerTopLeft || corner == TWCornerTopRight;
    return CGPointMake(left ? CGRectGetMinX(bounds) + x : CGRectGetMaxX(bounds) - x,
                       top ? CGRectGetMinY(bounds) + y : CGRectGetMaxY(bounds) - y);
}

+ (UIBezierPath *)triggerPathForCorner:(NSInteger)corner mode:(NSInteger)mode radius:(CGFloat)radius
                              length:(CGFloat)length height:(CGFloat)height cornerRadius:(CGFloat)cornerRadius
                             offsetX:(CGFloat)x offsetY:(CGFloat)y bounds:(CGRect)bounds {
    UIBezierPath *path = [UIBezierPath bezierPath];
    if (CGRectIsEmpty(bounds) || CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) return path;
    CGPoint anchor = [self triggerAnchorForCorner:corner offsetX:x offsetY:y bounds:bounds];
    BOOL left = corner == TWCornerBottomLeft || corner == TWCornerTopLeft;
    BOOL top = corner == TWCornerTopLeft || corner == TWCornerTopRight;
    CGFloat sx = left ? 1 : -1, sy = top ? 1 : -1;
    if (mode == 1) {
        length = isfinite(length) && length >= 1 ? length : 40;
        height = isfinite(height) && height >= 1 ? height : 40;
        CGFloat w = MIN(length, left ? CGRectGetMaxX(bounds) - anchor.x : anchor.x - CGRectGetMinX(bounds));
        CGFloat h = MIN(height, top ? CGRectGetMaxY(bounds) - anchor.y : anchor.y - CGRectGetMinY(bounds));
        if (w <= 0 || h <= 0) return path;
        CGFloat r = isfinite(cornerRadius) && cornerRadius >= 0 ? MIN(cornerRadius, MIN(w, h)) : MIN(12, MIN(w, h));
        // Local bottom-left path: only the inward corner is rounded, as in sc_sector.s.
        [path moveToPoint:CGPointZero];
        [path addLineToPoint:CGPointMake(w, 0)];
        [path addLineToPoint:CGPointMake(w, h - r)];
        if (r > 0) [path addArcWithCenter:CGPointMake(w - r, h - r) radius:r startAngle:0 endAngle:M_PI_2 clockwise:YES];
        [path addLineToPoint:CGPointMake(0, h)];
        [path closePath];
        CGAffineTransform transform = CGAffineTransformMake(sx, 0, 0, sy, anchor.x, anchor.y);
        [path applyTransform:transform];
    } else {
        radius = isfinite(radius) && radius >= 1 ? radius : 40;
        CGFloat start = [self startAngleForCorner:corner];
        [path moveToPoint:anchor];
        [path addArcWithCenter:anchor radius:radius startAngle:start endAngle:start + M_PI_2 clockwise:YES];
        [path closePath];
    }
    return path;
}

+ (CGFloat)menuStartAngleForCorner:(NSInteger)corner mirrored:(BOOL)mirrored {
    // arm64 constants at 0x73f90/0x73f98: right=180°, left=-90°.
    // Mirror reverses left-side entry order without enabling another trigger side.
    if (mirrored && corner == TWCornerBottomLeft) return 0;
    if (mirrored && corner == TWCornerTopLeft) return M_PI_2;
    return [self startAngleForCorner:corner];
}

+ (CGFloat)menuSweepAngleForCorner:(NSInteger)corner mirrored:(BOOL)mirrored {
    BOOL left = corner == TWCornerBottomLeft || corner == TWCornerTopLeft;
    return mirrored && left ? -kTWSweepAngle : kTWSweepAngle;
}

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

#pragma mark - 多环扇形

// 90° 象限内排环：第一环 firstRowCount 个，之后每环按"最小夹角 36°"排，
// 放不下就换到下一环。半径逐环加大 iconSize + ringGap。
// 起点/终点各内缩 6°，避免贴边的图标被屏幕裁掉一半。
+ (NSArray<NSValue *> *)centersForCount:(NSInteger)count
                          firstRowCount:(NSInteger)firstRowCount
                             ringCounts:(NSArray<NSNumber *> *)ringCounts
                               iconSize:(CGFloat)iconSize
                                  radius:(CGFloat)radius
                                ringGap:(CGFloat)ringGap
                                 anchor:(CGPoint)anchor
                                 corner:(NSInteger)corner
                                 bounds:(CGRect)bounds {
    return [self centersForCount:count firstRowCount:firstRowCount ringCounts:ringCounts iconSize:iconSize
                         radius:radius ringGap:ringGap anchor:anchor
                     startAngle:[self startAngleForCorner:corner] sweepAngle:kTWSweepAngle bounds:bounds];
}

+ (NSArray<NSValue *> *)centersForCount:(NSInteger)count firstRowCount:(NSInteger)firstRowCount
                             ringCounts:(NSArray<NSNumber *> *)ringCounts iconSize:(CGFloat)iconSize
                                 radius:(CGFloat)radius ringGap:(CGFloat)ringGap anchor:(CGPoint)anchor
                             startAngle:(CGFloat)startAngle sweepAngle:(CGFloat)sweepAngle bounds:(CGRect)bounds {
    NSMutableArray<NSValue *> *centers = [NSMutableArray array];
    if (count <= 0) return centers;
    if (!isfinite(iconSize) || iconSize <= 0) iconSize = 44;
    if (!isfinite(radius) || radius <= 0) radius = 140;
    if (!isfinite(ringGap) || ringGap < 0) ringGap = 10;
    NSInteger first = firstRowCount > 0 ? MIN(firstRowCount, count) : MIN((NSInteger)5, count);

    CGFloat start = isfinite(startAngle) ? startAngle : M_PI;
    CGFloat sweep = isfinite(sweepAngle) && fabs(sweepAngle) > 0.001 ? sweepAngle : kTWSweepAngle;
    NSInteger remaining = count;
    NSInteger ring = 0;
    CGFloat rowRadius = radius;
    CGFloat stepOut = iconSize + ringGap;

    while (remaining > 0) {
        // 原版扇形排布：一圈比一圈多一个（第一环 N 个，第二环 N+1，第三环 N+2…），
        // 而不是每环都按同一个最大容量硬塞。
        // 每环个数：由调用方按面板里的「第一/二/三/四环」传入，未设置的环按 +1 递增。
        NSInteger capacity;
        if (ring < (NSInteger)ringCounts.count && [ringCounts[ring] integerValue] > 0) {
            capacity = [ringCounts[ring] integerValue];
        } else {
            capacity = (ring == 0) ? first : (first + ring);
        }
        NSInteger n = MIN(remaining, MAX(capacity, 1));
        // The same "图标间隙" value also sets the minimum centre-to-centre chord
        // inside a ring. Without this, only the ring-to-ring distance changed:
        // the inner ring stayed cramped while outer rings looked scattered.
        CGFloat chord = MAX(1.0, iconSize + ringGap);
        CGFloat minStep = 2.0 * asin(MIN(1.0, chord / MAX(2.0 * rowRadius, 1.0)));
        if (minStep > 0.001) {
            NSInteger fits = (NSInteger)floor(fabs(sweep) / minStep) + 1;
            n = MIN(n, MAX(fits, 1));
        }
        // Edge-angle inset follows icon extent / row radius, rather than a fixed 6°.
        CGFloat inset = asin(MIN(1.0, iconSize * 0.5 / MAX(rowRadius, 1)));
        inset = MIN(inset, fabs(sweep) * 0.5);
        CGFloat direction = sweep < 0 ? -1 : 1;
        CGFloat a0 = start + direction * inset;
        CGFloat a1 = start + sweep - direction * inset;
        for (NSInteger i = 0; i < n; i++) {
            CGFloat t = (n == 1) ? 0.5 : (CGFloat)i / (CGFloat)(n - 1);
            CGFloat angle = a0 + (a1 - a0) * t;
            CGPoint p = CGPointMake(anchor.x + rowRadius * cos(angle),
                                    anchor.y + rowRadius * sin(angle));
            // 夹进屏幕（留半个图标的内边距），保证不被裁。
            CGFloat half = iconSize * 0.5 + 2;
            CGFloat minX = CGRectGetMinX(bounds) + half, maxX = CGRectGetMaxX(bounds) - half;
            CGFloat minY = CGRectGetMinY(bounds) + half, maxY = CGRectGetMaxY(bounds) - half;
            p.x = maxX >= minX ? MIN(MAX(p.x, minX), maxX) : CGRectGetMidX(bounds);
            p.y = maxY >= minY ? MIN(MAX(p.y, minY), maxY) : CGRectGetMidY(bounds);
            [centers addObject:[NSValue valueWithCGPoint:p]];
        }
        remaining -= n;
        ring++;
        rowRadius += stepOut;
    }
    return centers;
}

+ (CGFloat)clampedRadius:(CGFloat)radius anchor:(CGPoint)anchor corner:(NSInteger)corner bounds:(CGRect)bounds {
    if (!isfinite(radius) || radius <= 0) radius = 140;
    CGFloat cap = [self maxRadiusForCorner:corner anchor:anchor margin:12 bounds:bounds];
    if (cap > 0) radius = MIN(radius, cap);
    return MAX(radius, 60);
}

@end