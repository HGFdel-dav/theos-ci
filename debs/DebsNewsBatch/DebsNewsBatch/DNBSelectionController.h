//
//  DNBSelectionController.h
//  DebsNewsBatch
//
//  窗口级管家：自己找当前在显示的「新闻」页，把底部条与行内勾选层贴上去。
//  不依赖页面生命周期（SwiftUI 会不停重建承载控制器）。
//

#import <UIKit/UIKit.h>

@interface DNBSelectionController : NSObject

+ (instancetype)sharedController;

/* App 启动后调用一次 */
+ (void)start;

@property (nonatomic, readonly) BOOL bound;

@end
