#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Common/Common.h"
#import <objc/runtime.h>

// Reynard-side half of the tweak.
//
// Every click/tap navigation inside Reynard is delivered to
// -[GeckoEventDispatcherWrapper dispatchToSwift:message:callback:] (Swift class,
// ObjC visible, in Frameworks/GeckoView.framework) with type
// "GeckoView:OnLoadRequest". The app answers .allow for anything that is not a
// web URL, so tg://, mailto:, tel:... die in the browser. Here the request is
// taken over: the URL is handed to the system and the navigation is denied by
// answering "handled" (true) to the callback.

#define RD_TAG @"[ReynardDefault]"

static NSString *const kReynardBundleID = @"com.minh-ton.Reynard";
static NSString *const kDispatcherClass = @"_TtC9GeckoView27GeckoEventDispatcherWrapper";
static NSString *const kOnLoadRequestEvent = @"GeckoView:OnLoadRequest";

// GeckoView's EventCallback (ObjC protocol in the framework). Declared here so
// the .xm compiles as ObjC++ without dragging in the framework headers.
@protocol RDEventCallback <NSObject>
- (void)sendSuccess:(id)response;
- (void)sendError:(id)response;
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

static BOOL RDBoolValue(id value, BOOL fallback) {
    if (!value || value == [NSNull null]) return fallback;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return fallback;
}

static void RDLogTypeOnce(NSString *type) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if ([seen containsObject:type]) return;
        [seen addObject:type];
        RDLog(@"event type %@", type);
    }
}

// Clicks on unknown schemes produce no request event at all in this build; the
// only signal is the history event. Keep a short window so one click cannot
// open twice when several events describe it.
static BOOL RDClaimHandoff(NSString *uri) {
    static NSString *lastURI;
    static NSTimeInterval lastAt;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (lastURI && [lastURI isEqualToString:uri] && now - lastAt < 3.0) return NO;
    lastURI = [uri copy];
    lastAt = now;
    return YES;
}

static BOOL RDHandoffAllowed(void) {
    return RDReadBoolPref(kEnabledKey, YES) && RDReadBoolPref(kHandoffKey, YES);
}

// Schemes Gecko must keep rendering itself.
static NSSet *RDInternalSchemes(void) {
    static NSSet *schemes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        schemes = [NSSet setWithArray:@[
            @"http", @"https", @"about", @"data", @"blob", @"javascript",
            @"moz-extension", @"jar", @"view-source", @"file", @"resource",
            @"wyciwyg", @"ws", @"wss", @"ftp"
        ]];
    });
    return schemes;
}

static void RDOpenExternally(NSURL *url) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = [UIApplication sharedApplication];
        [application openURL:url options:@{} completionHandler:^(BOOL success) {
            RDLog(@"open %@ ok=%d", url.scheme, success);
        }];
    });
}

%group ReynardGroup

%hook _TtC9GeckoView27GeckoEventDispatcherWrapper

- (void)dispatchToSwift:(NSString *)type message:(id)message callback:(id<RDEventCallback>)callback {
    BOOL isRequest = [type isEqualToString:kOnLoadRequestEvent] ||
                      [type hasSuffix:@"OnLoadRequest"] ||
                      [type hasSuffix:@"OnPreNavigation"];
    BOOL isError = [type hasSuffix:@"OnLoadError"];
    BOOL isVisited = [type hasSuffix:@"OnVisited"];
    if ((!isRequest && !isError && !isVisited) || ![message isKindOfClass:[NSDictionary class]]) {
        RDLogTypeOnce(type);
        %orig;
        return;
    }

    NSDictionary *payload = (NSDictionary *)message;
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    NSURL *url = uri.length ? [NSURL URLWithString:uri] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    BOOL topLevel = RDBoolValue(payload[@"isTopLevel"], YES);
    BOOL userInitiated = RDBoolValue(payload[@"isUserInitiatedNavigation"], YES);
    RDLog(@"%@ scheme=%@ top=%d user=%d err=%@ keys=%@ uri=%@", type, scheme, topLevel, userInitiated,
          payload[@"error"], [[payload allKeys] componentsJoinedByString:@","], uri);

    BOOL wanted = scheme.length > 0 && ![RDInternalSchemes() containsObject:scheme];
    if (!wanted || !topLevel || !RDHandoffAllowed()) {
        %orig;
        return;
    }

    if (isVisited) {
        // History event: keep the app's own handling, just open the app too.
        %orig;
        if (RDClaimHandoff(url.absoluteString)) {
            RDLog(@"handoff(visited) %@ %@", scheme, url.absoluteString);
            RDOpenExternally(url);
        }
        return;
    }

    if (!RDClaimHandoff(url.absoluteString)) {
        %orig;
        return;
    }

    RDLog(@"handoff %@ %@", scheme, url.absoluteString);
    RDOpenExternally(url);

    if (isError) {
        // Known failure path for unknown schemes: replace the error page with
        // an empty document, the user is already in the other app.
        [callback sendSuccess:@""];
    } else {
        // true == "handled by the app", Gecko stops the navigation.
        [callback sendSuccess:@(YES)];
    }
}

%end

%end

static void RDInstallHook(int attempt) {
    Class dispatcher = objc_getClass(kDispatcherClass.UTF8String);
    if (dispatcher) {
        %init(ReynardGroup);
        RDLog(@"hook installed after %d attempt(s)", attempt);
        return;
    }
    if (attempt >= 100) {
        RDLog(@"dispatcher class never showed up");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RDInstallHook(attempt + 1);
    });
}

%ctor {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (![bundleID isEqualToString:kReynardBundleID]) return;
    RDLog(@"loaded in %@ enabled=%d handoff=%d", bundleID,
          RDReadBoolPref(kEnabledKey, YES), RDReadBoolPref(kHandoffKey, YES));
    RDInstallHook(0);
}
