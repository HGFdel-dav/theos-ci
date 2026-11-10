#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Common/Common.h"

#define RD_TAG @"[ReynardDefault]"
static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kDispatcherClass = @"_TtC9GeckoView27GeckoEventDispatcherWrapper";

@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)response;
- (void)sendError:(id)response;
@end

#import "Common/RDClickRouter.h"

static NSString *RDLogPath(void) {
    static NSString *path; static dispatch_once_t once;
    dispatch_once(&once, ^{ path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReynardDefault.log"]; });
    return path;
}
#ifdef REYNARD_STRIP_LOGS
#define RDNSLog(...) do {} while (0)
#else
#define RDNSLog(...) NSLog(__VA_ARGS__)
#endif
static void RDLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    RDNSLog(@"%@ %@", RD_TAG, line);
    NSString *path = RDLogPath(); NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs && [[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 256 * 1024) {
        [fm removeItemAtPath:path error:NULL]; attrs = nil;
    }
    NSData *data = [[NSString stringWithFormat:@"%@ %@ %@\n", [NSDate date], RD_TAG, line] dataUsingEncoding:NSUTF8StringEncoding];
    if (!attrs) { [data writeToFile:path atomically:YES]; return; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path]; if (!handle) return;
    @try { [handle seekToEndOfFile]; [handle writeData:data]; } @catch (NSException *e) { (void)e; }
    [handle closeFile];
}

%group ReynardGroup
%hook _TtC9GeckoView27GeckoEventDispatcherWrapper
- (void)dispatchToSwift:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback {
    BOOL navigation = [type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                      [type isEqualToString:@"GeckoView:OnLoadRequest"];
    if (!navigation) { %orig; return; }
    void (^handle)(void) = [^{
        if (RDHandleClickNavigation(self, type, message, callback)) return;
        %orig(type, message, callback);
    } copy];
    if ([NSThread isMainThread]) handle();
    else dispatch_async(dispatch_get_main_queue(), handle);
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kReynardBundleID]) return;
        Class cls = objc_getClass(kDispatcherClass.UTF8String);
        Method method = class_getInstanceMethod(cls, @selector(dispatchToSwift:message:callback:));
        if (!method || method_getNumberOfArguments(method) != 5) {
            RDLog(@"native click hook unavailable"); return;
        }
        %init(ReynardGroup);
        RDLog(@"loaded plugin-only click router enabled=%d", RDRouteEnabled());
    }
}
