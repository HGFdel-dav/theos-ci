#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "Common/Common.h"
#import "Common/RDHandoffPayload.h"

#define RD_TAG @"[ReynardDefault]"
static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kDispatcherClass = @"_TtC9GeckoView27GeckoEventDispatcherWrapper";
static NSString *const kHandoffAddonID = @"reynarddefault@local";

@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)response;
- (void)sendError:(id)response;
@end

@protocol RDGeckoDispatch <NSObject>
- (void)dispatchToGecko:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback;
@end

static NSString *RDLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReynardDefault.log"];
    });
    return path;
}

#ifdef REYNARD_STRIP_LOGS
#define RDNSLog(...) do {} while (0)
#else
#define RDNSLog(...) NSLog(__VA_ARGS__)
#endif

static void RDLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    RDNSLog(@"%@ %@", RD_TAG, line);

    NSString *path = RDLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    if (attributes && size > 256 * 1024) {
        [fm removeItemAtPath:path error:NULL];
        attributes = nil;
    }
    NSString *entry = [NSString stringWithFormat:@"%@ %@ %@\n", [NSDate date], RD_TAG, line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    if (!attributes) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *exception) {
        (void)exception;
    }
    [handle closeFile];
}


#import "Common/RDExtensionInstall.h"
#import "Common/RDClickRouter.h"

%group ReynardGroup
%hook _TtC9GeckoView27GeckoEventDispatcherWrapper

// Verified ObjC protocol entry point: v24@0:8@16.
- (void)attach:(id)backend {
    RDRememberAttachedBackend(self, backend);
    %orig;
}

// Verified ObjC method: v40@0:8@16@24@32. Gecko callbacks are answered on main,
// matching GeckoEventListenerInternal.handleMessage in the original framework.
- (void)dispatchToSwift:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback {
    BOOL navigation = [type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                      [type isEqualToString:@"GeckoView:OnLoadRequest"];
    BOOL runtime = [type isEqualToString:@"GeckoView:WebExtension:OnReady"] ||
                   [type isEqualToString:@"GeckoView:WebExtension:OnInstalled"];
    if (!navigation && !runtime) {
        // OnVisited, OnLoadError, arbitrary extension messages and startup events
        // never trigger openURL. The original app handles them unchanged.
        %orig;
        return;
    }
    void (^handle)(void) = [^{
        if (runtime) RDObserveRuntimeExtension(self, type, message);
        if (navigation && RDHandleClickNavigation(self, type, message, callback)) return;
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
        SEL incoming = @selector(dispatchToSwift:message:callback:);
        Method method = class_getInstanceMethod(cls, incoming);
        if (!method || method_getNumberOfArguments(method) != 5) {
            RDLog(@"hook unavailable: incompatible dispatcher"); return;
        }
        %init(ReynardGroup);
        RDLog(@"loaded 1.5.34 click-only router; enabled=%d", RDRouteEnabled());
    }
}
