// TWArcMenuView.h
// 角落弧形菜单（0.4.0）：以屏幕角落为圆心，图标沿扇形朝屏内展开。
// 每个条目 = 一个"应用 + 容器"，所以一个应用有几个容器就有几个图标（角标区分）。
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TWArcMenuView : UIView
// entries: NSArray<NSDictionary *>，每项固定键
//   @{@"bundleID": NSString, @"containerID": NSString(可空), @"title": NSString, @"badge": NSString(可空,如 @"默"/@"分")}
- (void)presentFromTriggerPoint:(CGPoint)point entries:(NSArray<NSDictionary *> *)entries corner:(NSInteger)corner radius:(CGFloat)radius menuScale:(CGFloat)menuScale;
- (void)updateSelectionAtPoint:(CGPoint)point;
// 当前高亮项下标（-1 = 没有），长按判定要用。
- (NSInteger)selectedIndex;
- (nullable NSDictionary *)entryAtIndex:(NSInteger)index;
// 返回选中的条目（nil = 没选中）并收起菜单。
- (NSDictionary *)finishSelectionAtPoint:(CGPoint)point;
- (void)dismissAnimated:(BOOL)animated;
@property (nonatomic, readonly, getter=isPresented) BOOL presented;
@end

NS_ASSUME_NONNULL_END