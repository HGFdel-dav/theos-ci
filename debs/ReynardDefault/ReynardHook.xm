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
#ifdef REYNARD_STRIP_LOGS
    (void)format;
#else
    va_list args; va_start(args, format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSLog(@"%@ %@",RD_TAG,line);
#endif
}

#import "Common/RDClickRouter.h"
#import "Common/RDExternalLink.h"

%group ReynardGroup
%hook _TtC9GeckoView27GeckoEventDispatcherWrapper
- (void)dispatchToSwift:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback {
    BOOL navigation=[type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                     [type isEqualToString:@"GeckoView:OnLoadRequest"];
    if (!navigation) { %orig; return; }
    NSDictionary *payload=[message isKindOfClass:[NSDictionary class]] ? message : nil;
    NSString *diagURI=[payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : @"<none>";
    id diagGesture=[payload[@"hasUserGesture"] isKindOfClass:[NSNumber class]] ? payload[@"hasUserGesture"] : @"<none>";
    id diagTop=[payload[@"isTopLevel"] isKindOfClass:[NSNumber class]] ? payload[@"isTopLevel"] : @"<none>";
    id diagFlags=[payload[@"flags"] isKindOfClass:[NSNumber class]] ? payload[@"flags"] : @"<none>";
    NSURLComponents *parts=[NSURLComponents componentsWithString:diagURI];
    RDLog(@"route event=%@ scheme=%@ gesture=%@ top=%@ flags=%@ callback=%d",type,
          parts.scheme.lowercaseString ?: @"<none>",diagGesture,diagTop,diagFlags,
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

%ctor {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:kReynardBundleID]) return;
        Class cls=objc_getClass(kDispatcherClass.UTF8String);
        Method method=class_getInstanceMethod(cls,@selector(dispatchToSwift:message:callback:));
        if (!method || method_getNumberOfArguments(method)!=5) {
            RDLog(@"native dispatcher unavailable"); return;
        }
        %init(ReynardGroup);
        RDInstallExternalLinkHook();
        RDLog(@"loaded native-only router enabled=%d",RDRouteEnabled());
    }
}
