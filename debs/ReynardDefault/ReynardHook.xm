#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#include <math.h>
#import "Common/Common.h"

#define RD_TAG @"[ReynardDefault]"
static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kReynardHelperBundleID = @"com.minh-ton.Reynard.Helper";
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
#import "Common/RDNativeLink.h"

static BOOL gRDRelayArmed=NO;
static void RDConsumeRelayedURL(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ RDConsumeRelayedURL(); }); return; }
    if (!gRDRelayArmed || !RDNativeEnabled()) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *payload=RDNativeConsumeExternalURL();
    gRDRelayArmed=NO;
    NSString *spec=[payload[@"url"] isKindOfClass:[NSString class]] ? payload[@"url"] : nil;
    NSNumber *stamp=[payload[@"time"] isKindOfClass:[NSNumber class]] ? payload[@"time"] : nil;
    if (!spec || !stamp || fabs([[NSDate date] timeIntervalSince1970]-stamp.doubleValue)>5.0) return;
    NSURL *url=RDNativeAppURL(spec);
    if (!url) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL accepted=[UIApplication.sharedApplication openURL:url];
#pragma clang diagnostic pop
    RDLog(@"relayed external URL scheme=%@ accepted=%d",url.scheme,accepted);
}
static void RDRelayNotification(CFNotificationCenterRef center,const void *observer,CFStringRef name,const void *object,CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{ gRDRelayArmed=YES; RDConsumeRelayedURL(); });
}
static void RDInstallRelayObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        RDRelayNotification, RD_HOOK_NOTIFICATION, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
            RDConsumeRelayedURL();
        }];
        RDConsumeRelayedURL();
    });
}

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
        NSString *bundleID=[NSBundle mainBundle].bundleIdentifier;
        if ([bundleID isEqualToString:kReynardHelperBundleID]) {
            RDNativeInstallXULHook();
            return;
        }
        if (![bundleID isEqualToString:kReynardBundleID]) return;
        RDInstallRelayObserver();
        Class cls=objc_getClass(kDispatcherClass.UTF8String);
        Method method=class_getInstanceMethod(cls,@selector(dispatchToSwift:message:callback:));
        if (!method || method_getNumberOfArguments(method)!=5) {
            RDLog(@"native dispatcher unavailable"); return;
        }
        %init(ReynardGroup);
        RDNativeInstallXULHook();
        RDLog(@"loaded plugin-only router with Helper relay enabled=%d",RDRouteEnabled());
    }
}
