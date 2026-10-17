// TWArcMenuView.h
// Arc menu: frosted circular icons laid out along an arc, with a gradient
// arc background, spring presentation and highlight-on-swipe selection.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWArcMenuView : UIView
- (void)presentFromTriggerPoint:(CGPoint)point bundleIDs:(NSArray<NSString *> *)bundleIDs side:(NSInteger)side radius:(CGFloat)radius menuScale:(CGFloat)menuScale;
- (void)updateSelectionAtPoint:(CGPoint)point;
// Returns the selected bundleID (nil if none) and dismisses.
- (NSString *)finishSelectionAtPoint:(CGPoint)point;
- (void)dismissAnimated:(BOOL)animated;
@property (nonatomic, readonly, getter=isPresented) BOOL presented;
@end

NS_ASSUME_NONNULL_END