//
//  Tweak.m
//  DebsNewsBatch
//
//  启动一个窗口级管家：它自己找当前在显示的「新闻」页，贴底部条与勾选层。
//  不 Hook App 的任何方法，也不用 substrate。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "DNBCommon.h"
#import "DNBSelectionController.h"

__attribute__((constructor)) static void DebsNewsBatchInit(void)
{
    @autoreleasepool {
        DNBLog(@"DebsNewsBatch dylib 构造函数执行 pid=%d", getpid());
        dispatch_async(dispatch_get_main_queue(), ^{
            [DNBSelectionController start];
        });
    }
}
