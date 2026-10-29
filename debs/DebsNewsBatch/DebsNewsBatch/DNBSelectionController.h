//
//  DNBSelectionController.h
//  DebsNewsBatch
//
//  挂在新闻页（SwiftUI 承载控制器）上的选择管家：底部条 + 行内勾选覆盖层。
//  只在新闻页存在期间活着，离开就摘掉。
//

#import <UIKit/UIKit.h>

@class DNBSelectionController;

@interface DNBSelectionController : NSObject

/* 给这个控制器挂上（已在则复用），找不到列表返回 nil */
+ (instancetype)attachToViewController:(UIViewController *)vc;

+ (DNBSelectionController *)controllerForViewController:(UIViewController *)vc;

- (void)detach;

@property (nonatomic, readonly) BOOL attached;

@end
