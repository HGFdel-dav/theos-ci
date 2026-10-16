//  DBUploadPanel — 批量上传面板
#import <UIKit/UIKit.h>

@interface DBUploadPanelViewController : UINavigationController

// 弹出批量上传面板（pageSheet）。presenter 为空时自动取当前顶层 VC。
+ (void)presentFromViewController:(UIViewController *)presenter;

@end