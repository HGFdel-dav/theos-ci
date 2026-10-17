// PXPArcGeometry.m
#import "PXPArcGeometry.h"
#import <math.h>

@implementation PXPArcGeometry

+ (CGFloat)clampAngle:(CGFloat)a {
    while (a > M_PI) a -= 2.0 * M_PI;
    while (a < -M_PI) a += 2.0 * M_PI;
    return a;
}

+ (BOOL)point:(CGPoint)point inTriggerRegionForSide:(NSInteger)side width:(CGFloat)width bounds:(CGRect)bounds {
    if ((side != 0 && side != 1) || !isfinite(point.x) || !isfinite(point.y) ||
        !isfinite(CGRectGetWidth(bounds)) || !isfinite(CGRectGetHeight(bounds)) ||
        CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 140) return NO;
    if (!isfinite(width) || width <= 0) width = 24;
    CGFloat inset = MIN(width, CGRectGetWidth(bounds) / 2);
    // Keep clear of the status bar / notification center zone and the home-bar zone.
    CGFloat top = CGRectGetMinY(bounds) + 70;
    CGFloat bottom = CGRectGetMaxY(bounds) - 70;
    if (side == 0) { // left edge
        return point.x >= CGRectGetMinX(bounds) && point.x <= CGRectGetMinX(bounds) + inset &&
               point.y >= top && point.y <= bottom;
    }
    // right edge
    return point.x >= CGRectGetMaxX(bounds) - inset && point.x <= CGRectGetMaxX(bounds) &&
           point.y >= top && point.y <= bottom;
}

+ (CGPoint)anchorForTriggerPoint:(CGPoint)triggerPoint side:(NSInteger)side bounds:(CGRect)bounds {
    CGFloat inset = 26;
    if (side == 0) {
        return CGPointMake(CGRectGetMinX(bounds) + inset, triggerPoint.y);
    }
    return CGPointMake(CGRectGetMaxX(bounds) - inset, triggerPoint.y);
}

+ (CGFloat)radiusForItemCount:(NSInteger)count preferredRadius:(CGFloat)radius menuScale:(CGFloat)scale bounds:(CGRect)bounds {
    CGFloat sweep = 1.45 * M_PI_2;
    scale = isfinite(scale) && scale > 0 ? scale : 1;
    radius = isfinite(radius) && radius > 0 ? radius : 140;
    // A square's diagonal envelope also protects adjacent highlighted icons.
    CGFloat step = count > 1 ? sweep / (count - 1) : sweep;
    CGFloat desired = (48 * scale * M_SQRT2 * 1.18 + 6) / (2 * sin(step / 2));
    CGFloat footprint = 78 * scale * 1.18;
    CGFloat availableWidth = MAX(0, CGRectGetWidth(bounds) - 16);
    CGFloat availableHeight = MAX(0, CGRectGetHeight(bounds) - 16);
    // Reserve space for a 78pt item's highlight; small screens shrink both.
    footprint = MIN(footprint, MIN(availableWidth, availableHeight) * 0.4);
    CGFloat cap = MIN(availableWidth - footprint,
                      (availableHeight - footprint) / (1 - cos(sweep)));
    return MAX(0, MIN(MAX(radius, desired), cap));
}

+ (CGFloat)itemSizeForCount:(NSInteger)count radius:(CGFloat)radius menuScale:(CGFloat)scale {
    scale = isfinite(scale) && scale > 0 ? scale : 1;
    CGFloat step = 1.45 * M_PI_2 / MAX(count - 1, 1);
    CGFloat chord = 2 * radius * sin(step / 2);
    // sqrt(2) bounds square boxes for every angle; 1.18 covers highlighting.
    return MAX(0, MIN(78, (chord - 6) / (M_SQRT2 * 1.18 * scale)));
}

+ (CGPoint)anchorForTriggerPoint:(CGPoint)point side:(NSInteger)side radius:(CGFloat)radius itemSize:(CGFloat)size menuScale:(CGFloat)scale bounds:(CGRect)bounds {
    CGFloat margin = size * scale * 1.18 / 2 + 8;
    CGFloat minY = CGRectGetMinY(bounds) + margin + radius;
    CGFloat maxY = CGRectGetMaxY(bounds) - margin + radius * cos(1.45 * M_PI_2);
    CGFloat y = MAX(minY, MIN(maxY, point.y));
    return CGPointMake(side == 0 ? CGRectGetMinX(bounds) + margin : CGRectGetMaxX(bounds) - margin, y);
}

+ (CGPoint)centerForItemAtIndex:(NSInteger)index count:(NSInteger)count radius:(CGFloat)radius anchor:(CGPoint)anchor side:(NSInteger)side bounds:(CGRect)bounds {
    CGFloat step = count > 1 ? 1.45 * M_PI_2 / (count - 1) : 0;
    CGFloat angle = M_PI_2 - index * step;
    if (side != 0) angle = M_PI - angle;
    // Fit the anchor/radius as one layout: per-item clamping collapses spacing.
    return CGPointMake(anchor.x + radius * cos(angle), anchor.y - radius * sin(angle));
}

@end