//
//  POSplitPanelView.h
//  SplitX
//
//  无整块底板的轻玻璃图标菜单。真实尺寸防重叠布局，放不下的账号分页显示。
//  从手柄朝屏幕内侧展开；命中使用当前页实际图标位置。
//

#import <UIKit/UIKit.h>
#import "QuickSwitchTableView.h"

NS_ASSUME_NONNULL_BEGIN

@interface POSplitPanelView : UIView <POQuickSwitchMenuPresenting>

@property (nonatomic, weak) id<QuickSwitchSelectionDelegate> selectionDelegate;
@property (nonatomic, assign) CGRect presentationAnchorFrame;

/// YES = 手柄在左侧，图标向右（屏幕内）展开。
@property (nonatomic, assign) BOOL expandsRight;

@end

NS_ASSUME_NONNULL_END
