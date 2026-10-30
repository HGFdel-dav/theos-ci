//
//  DNBFloatingButton.h
//  DebsNewsBatch
//

#import <UIKit/UIKit.h>

@interface DNBFloatingButton : NSObject

+ (instancetype)shared;

/* 在 Debs 进程里启动：挂通知 + 定时兜底，把悬浮按钮贴到当前 key window */
- (void)start;

@end
