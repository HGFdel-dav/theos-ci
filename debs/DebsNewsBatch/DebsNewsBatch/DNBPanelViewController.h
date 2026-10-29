//
//  DNBPanelViewController.h
//  DebsNewsBatch
//

#import <UIKit/UIKit.h>

@interface DNBPanelViewController : UIViewController

/* 面板关闭后回调（用于恢复悬浮按钮显示） */
@property (nonatomic, copy) void (^onDismiss)(void);

@end
