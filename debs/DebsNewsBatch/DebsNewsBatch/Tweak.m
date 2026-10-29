//
//  Tweak.m
//  DebsNewsBatch
//
//  没有 Hook 任何原生方法：只是在 Debs 进程里挂一个我们自己的悬浮按钮与面板。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "DNBCommon.h"
#import "DNBFloatingButton.h"

__attribute__((constructor)) static void DebsNewsBatchInit(void)
{
    @autoreleasepool {
        DNBLog(@"DebsNewsBatch dylib 构造函数执行 pid=%d", getpid());
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DNBFloatingButton shared] start];
        });
    }
}
