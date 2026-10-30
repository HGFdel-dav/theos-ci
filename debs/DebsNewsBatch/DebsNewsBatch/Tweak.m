//
//  Tweak.m
//  DebsNewsBatch
//
//  进入 App 的「新闻」页时挂我们的选择管家（底部条 + 行内勾选），离开就摘掉。
//  只用 objc runtime 挂钩，不依赖 substrate。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "DNBCommon.h"
#import "DNBHook.h"
#import "DNBSelectionController.h"

static IMP DNBOrigViewDidAppear;
static IMP DNBOrigViewWillDisappear;

static BOOL DNBIsNewsPage(UIViewController *vc)
{
    if (!vc) {
        return NO;
    }
    if ([vc.navigationItem.title isEqualToString:@"新闻"]) {
        return YES;
    }
    return [NSStringFromClass([vc class]) containsString:@"NewsView"];
}

static void DNBViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated)
{
    if (DNBOrigViewDidAppear) {
        ((void (*)(id, SEL, BOOL))DNBOrigViewDidAppear)(self, _cmd, animated);
    }
    if (!DNBIsNewsPage(self)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [DNBSelectionController attachToViewController:self];
    });
}

static void DNBViewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated)
{
    if (DNBOrigViewWillDisappear) {
        ((void (*)(id, SEL, BOOL))DNBOrigViewWillDisappear)(self, _cmd, animated);
    }
    [[DNBSelectionController controllerForViewController:self] detach];
}

__attribute__((constructor)) static void DebsNewsBatchInit(void)
{
    @autoreleasepool {
        DNBLog(@"DebsNewsBatch dylib 构造函数执行 pid=%d", getpid());
        Class vcClass = [UIViewController class];
        DNBOrigViewDidAppear = DNBHookInstanceMethod(vcClass, @selector(viewDidAppear:), (IMP)DNBViewDidAppear);
        DNBOrigViewWillDisappear = DNBHookInstanceMethod(vcClass, @selector(viewWillDisappear:), (IMP)DNBViewWillDisappear);
        DNBLog(@"挂钩 viewDidAppear/viewWillDisappear：%s / %s",
               DNBOrigViewDidAppear ? "ok" : "fail",
               DNBOrigViewWillDisappear ? "ok" : "fail");
    }
}
