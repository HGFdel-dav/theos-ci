// TWArcGeometry.m
#import "TWArcGeometry.h"

@implementation TWArcGeometry

+ (CGFloat)clampAngle:(CGFloat)a {
    while (a > M_PI) a -= 2.0 * M_PI;
    while (a < -M_PI) a += 2.0 * M_PI;
    return a;
}

+ (BOOL)point:(CGPoint)point inTriggerRegionForSide:(NSInteger)side width:(CGFloat)width bounds:(CGRect)bounds {
    if (width <= 0) width = 24;
    CGFloat inset = width;
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

+ (CGPoint)centerForItemAtIndex:(NSInteger)index count:(NSInteger)count radius:(CGFloat)radius anchor:(CGPoint)anchor side:(NSInteger)side bounds:(CGRect)bounds {
    if (count < 1) count = 1;
    // Sweep the arc from straight up (M_PI/2) toward the screen edge, so the
    // icons fan out from the anchor into the screen like ScreenCore's menu.
    CGFloat startAngle = M_PI / 2.0;                 // pointing up
    CGFloat sweep = 1.45f * (M_PI / 2.0);            // ~130 degrees
    CGFloat step = (count > 1) ? sweep / (count - 1) : 0;
    CGFloat angle;
    if (side == 0) { // left edge: fan clockwise from up toward the right
        angle = startAngle - index * step;
    } else {         // right edge: fan counter-clockwise
        angle = M_PI - (startAngle - index * step);
    }
    CGFloat x = anchor.x + radius * cos(angle);
    CGFloat y = anchor.y - radius * sin(angle);
    x = MAX(CGRectGetMinX(bounds) + 34, MIN(CGRectGetMaxX(bounds) - 34, x));
    y = MAX(CGRectGetMinY(bounds) + 34, MIN(CGRectGetMaxY(bounds) - 34, y));
    return CGPointMake(x, y);
}

@end