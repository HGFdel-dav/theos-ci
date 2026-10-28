//
//  POSplitPanelView.h
//  SplitX
//
//  ParallelX 形态的面板：从边缘手柄弹出的一整块玻璃，图标按斜向两列散开，
//  不再是一列竖表。命中按最近图标判定。
//

#import <UIKit/UIKit.h>
#import "QuickSwitchTableView.h"

NS_ASSUME_NONNULL_BEGIN

@interface POSplitPanelView : UIView <POQuickSwitchMenuPresenting>

@property (nonatomic, weak) id<QuickSwitchSelectionDelegate> selectionDelegate;
@property (nonatomic, assign) CGRect presentationAnchorFrame;

/// 当前吸附的屏幕边：YES = 手柄在左侧，面板向左展开
@property (nonatomic, assign) BOOL expandsRight;

@end

NS_ASSUME_NONNULL_END
