// PXPArcGeometry.h
// Ported geometry from ScreenCore's arc launcher:
//   - trigger region: a vertical strip along the chosen screen edge
//   - item placement: icons laid out along an arc anchored at the trigger point
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXPArcGeometry : NSObject
// Returns YES if the point lies inside the trigger strip for the given side.
+ (BOOL)point:(CGPoint)point inTriggerRegionForSide:(NSInteger)side width:(CGFloat)width bounds:(CGRect)bounds;
// Anchor (arc center) derived from the trigger point.
+ (CGPoint)anchorForTriggerPoint:(CGPoint)triggerPoint side:(NSInteger)side bounds:(CGRect)bounds;
// Fit the whole arc (including the 1.18x highlight) without clamping items separately.
+ (CGFloat)radiusForItemCount:(NSInteger)count preferredRadius:(CGFloat)radius menuScale:(CGFloat)scale bounds:(CGRect)bounds;
+ (CGFloat)itemSizeForCount:(NSInteger)count radius:(CGFloat)radius menuScale:(CGFloat)scale;
+ (CGPoint)anchorForTriggerPoint:(CGPoint)point side:(NSInteger)side radius:(CGFloat)radius itemSize:(CGFloat)size menuScale:(CGFloat)scale bounds:(CGRect)bounds;
// Center of the i-th menu item (0-based) when placing count items along the arc.
+ (CGPoint)centerForItemAtIndex:(NSInteger)index count:(NSInteger)count radius:(CGFloat)radius anchor:(CGPoint)anchor side:(NSInteger)side bounds:(CGRect)bounds;
@end

NS_ASSUME_NONNULL_END