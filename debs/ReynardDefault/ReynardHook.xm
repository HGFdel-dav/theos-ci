#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <math.h>
#import "Common/Common.h"

#define RD_TAG @"[ReynardDefault]"
static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kDispatcherClass = @"_TtC9GeckoView27GeckoEventDispatcherWrapper";

@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)response;
- (void)sendError:(id)response;
@end

/* Release hooks must not synchronously write files from Gecko or dyld paths. */
static void RDLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSLog(@"%@ %@",RD_TAG,line);
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"tmp/rdboot-1.5.56.txt"];
    NSData *data=[[NSString stringWithFormat:@"%@ %@\n",[NSDate date],line] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];
    if(!h) [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
    else { @try {[h seekToEndOfFile];[h writeData:data];} @catch(NSException *e){} [h closeFile]; }
}

#import "Common/RDClickRouter.h"
#import "Common/RDExternalLink.h"

%group ReynardGroup
%hook _TtC9GeckoView27GeckoEventDispatcherWrapper
- (void)dispatchToSwift:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback {
    BOOL navigation=[type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                     [type isEqualToString:@"GeckoView:OnLoadRequest"] ||
                     [type isEqualToString:@"GeckoView:OnNewSession"];
    if (!navigation) { %orig; return; }
    NSDictionary *payload=[message isKindOfClass:[NSDictionary class]] ? message : nil;
    NSString *diagURI=[payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : @"<none>";
    id diagGesture=[payload[@"hasUserGesture"] isKindOfClass:[NSNumber class]] ? payload[@"hasUserGesture"] : @"<none>";
    id diagTop=[payload[@"isTopLevel"] isKindOfClass:[NSNumber class]] ? payload[@"isTopLevel"] : @"<none>";
    id diagFlags=[payload[@"flags"] isKindOfClass:[NSNumber class]] ? payload[@"flags"] : @"<none>";
    id diagTrigger=[payload[@"triggerUri"] isKindOfClass:[NSString class]] ? payload[@"triggerUri"] : @"<none>";
    NSURLComponents *parts=[NSURLComponents componentsWithString:diagURI];
    RDLog(@"route event=%@ scheme=%@ gesture=%@ trigger=%@ top=%@ flags=%@ callback=%d",type,
          parts.scheme.lowercaseString ?: @"<none>",diagGesture,diagTrigger,diagTop,diagFlags,
          [callback respondsToSelector:@selector(sendSuccess:)]);
    void (^handle)(void)=^{
        BOOL handled=RDHandleClickNavigation(self,type,message,callback);
        RDLog(@"route decision event=%@ handled=%d",type,handled);
        if (handled) return;
        %orig(type,message,callback);
    };
    if ([NSThread isMainThread]) handle(); else dispatch_async(dispatch_get_main_queue(),handle);
}
%end
%end

static void RDAttachDispatcher(unsigned attempt) {
    static BOOL attached=NO;
    if (attached) return;
    Class cls=objc_getClass(kDispatcherClass.UTF8String);
    Method method=cls?class_getInstanceMethod(cls,@selector(dispatchToSwift:message:callback:)):NULL;
    if (method && method_getNumberOfArguments(method)==5) {
        %init(ReynardGroup);
        attached=YES;
        RDLog(@"dispatcher hook installed attempt=%u",attempt);
        return;
    }
    if (attempt<50) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RDAttachDispatcher(attempt+1); });
    } else {
        RDLog(@"native dispatcher unavailable");
    }
}

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kReynardBundleID]) return;
        RDLog(@"1.5.56 boot pid=%d enabled=%d",getpid(),RDRouteEnabled());
        RDInstallExternalLinkHook();
        RDAttachDispatcher(0);
        RDLog(@"loaded native-only router enabled=%d",RDRouteEnabled());
    }
}
