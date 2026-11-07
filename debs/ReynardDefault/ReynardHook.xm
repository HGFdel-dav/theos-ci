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
static NSString *const kMessageEvent = @"GeckoView:WebExtension:Message";
static NSString *const kPortMessageEvent = @"GeckoView:WebExtension:PortMessage";
static NSString *const kEnsureEvent = @"GeckoView:WebExtension:EnsureBuiltIn";
static NSString *const kHandoffAddonID = @"reynarddefault@local";
static NSString *const kHandoffAddonDir = @"/Library/ReynardDefault/handoff/";
static NSString *const kHandoffXpiPath = @"/Library/ReynardDefault/handoff.xpi";
static NSString *const kInstallEvent = @"GeckoView:WebExtension:Install";

// GeckoView's EventCallback (ObjC protocol in the framework). Declared here so
// the .xm compiles as ObjC++ without dragging in the framework headers.
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

static BOOL RDBoolValue(id value, BOOL fallback) {
    if (!value || value == [NSNull null]) return fallback;
    if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
        return [value boolValue];
    }
    return fallback;
}

static void RDLogOnce(NSString *type, id payload);

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
// Some extension events only need to be seen once per type, with their payload.
static void RDLogOnce(NSString *type, id payload) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", type, payload];
        if ([seen containsObject:key]) return;
        [seen addObject:key];
        RDLog(@"%@ %@", type, payload);
    }
}

static BOOL RDClaimHandoff(NSString *uri) {
    static NSString *lastURI;
    static NSTimeInterval lastAt;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (lastURI && [lastURI isEqualToString:uri] && now - lastAt < 3.0) return NO;
    lastURI = [uri copy];
    lastAt = now;
    return YES;
}

static NSSet *RDInternalSchemes(void);

@interface RDEnsureCallback : NSObject <RDEventCallback>
@end

static RDEnsureCallback *rdEnsureCallback;
static id rdGeckoBackend;
static BOOL rdEnsureDone;

static BOOL rdInstallTried;
static BOOL rdAddonConfirmed;

// Our callback object must really conform to GeckoView's EventCallback, otherwise
// the Swift side's `as? EventCallback` fails and the response is dropped.
static void RDConformToEventCallback(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Protocol *protocol = objc_getProtocol("EventCallback");
        if (!protocol) {
            RDLog(@"EventCallback protocol not found");
            return;
        }
        Class cls = [RDEnsureCallback class];
        if (!class_conformsToProtocol(cls, protocol)) {
            class_addProtocol(cls, protocol);
        }
        RDLog(@"callback conforms=%@", class_conformsToProtocol(cls, protocol) ? @"yes" : @"no");
    });
}

static void RDInstallPackedExtension(void);

static void RDInstallPackedExtension(void) {
    if (rdInstallTried || !rdGeckoBackend) return;
    rdInstallTried = YES;
    static int counter;
    NSString *location = [NSString stringWithFormat:@"file://%@", jbRootPath(kHandoffXpiPath)];
    RDLog(@"install packed addon %@", location);
    [(id<RDGeckoDispatch>)rdGeckoBackend dispatchToGecko:kInstallEvent
                                                message:@{@"locationUri": location,
                                                          @"installId": [NSString stringWithFormat:@"reynarddefault-%d", ++counter]}
                                               callback:rdEnsureCallback];
}

@implementation RDEnsureCallback
- (void)sendSuccess:(id)response {
    rdAddonConfirmed = YES;
    RDLog(@"addon ready: %@", response);
    // The page that is already loaded predates the content script: reload once.
    if (rdGeckoBackend) {
        [(id<RDGeckoDispatch>)rdGeckoBackend dispatchToGecko:@"GeckoView:Reload"
                                                     message:nil callback:nil];
    }
}
- (void)sendError:(id)response {
    RDLog(@"addon error: %@", response);
    if (!rdInstallTried) {
        // Built-in location refused (built-ins normally live in resource://app):
        // fall back to a normal packed install, the user confirms once.
        RDInstallPackedExtension();
    } else {
        rdEnsureDone = YES;
    }
}
@end

// Install the built-in content script extension (it intercepts non-web clicks,
// which the engine swallows without telling the host).
// The wrapper itself does NOT implement dispatchToGecko: — the gecko side lives
// in its `gecko` ivar. Sending it to the wrapper is an unrecognized selector.
static id RDGeckoBackend(id wrapper) {
    Class cls = [wrapper class];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    id backend = nil;
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        const char *raw = ivar_getName(ivars[index]);
        NSString *name = raw ? @(raw) : @"?";
        [names addObject:name];
        if (!backend && [name.lowercaseString containsString:@"gecko"]) {
            backend = object_getIvar(wrapper, ivars[index]);
        }
    }
    free(ivars);
    if (!backend && [wrapper respondsToSelector:@selector(valueForKey:)]) {
        @try { backend = [wrapper valueForKey:@"gecko"]; } @catch (NSException *exception) {
            (void)exception;
        }
    }
    static BOOL loggedIvars;
    if (!loggedIvars) { loggedIvars = YES; RDLog(@"backend=%@ ivars=%@",
        backend ? @"yes" : @"no", [names componentsJoinedByString:@","]); }
    return backend;
}

static void RDEnsureExtension(id wrapper) {
    static int tries;
    RDConformToEventCallback();
    static BOOL logged;
    if (rdEnsureDone || !wrapper) return;

    id backend = RDGeckoBackend(wrapper);
    if (!backend || ![backend respondsToSelector:@selector(dispatchToGecko:message:callback:)]) {
        if (!logged) {
            logged = YES;
            RDLog(@"no gecko backend, addon skipped for now");
        }
        if (++tries > 80) rdEnsureDone = YES;
        return;
    }

    rdEnsureDone = YES;
    rdGeckoBackend = backend;
    if (!rdEnsureCallback) rdEnsureCallback = [RDEnsureCallback new];
    NSString *location = [NSString stringWithFormat:@"file://%@", jbRootPath(kHandoffAddonDir)];
    [(id<RDGeckoDispatch>)backend dispatchToGecko:kEnsureEvent
                                          message:@{@"locationUri": location,
                                                    @"webExtensionId": kHandoffAddonID}
                                         callback:rdEnsureCallback];

    // No answer (callback dropped / engine refuses) -> install the packed copy.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!rdAddonConfirmed && !rdInstallTried) {
            RDLog(@"no answer from built-in install, falling back");
            RDInstallPackedExtension();
        }
    });
}

static NSString *RDURLFromPayload(id node) {
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)node;
        if ([text hasPrefix:@"{"] || [text hasPrefix:@"["]) {
            id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                       options:0 error:NULL];
            if (parsed) {
                NSString *nested = RDURLFromPayload(parsed);
                if (nested) return nested;
            }
        }
        NSString *scheme = [NSURL URLWithString:text].scheme.lowercaseString;
        if (scheme.length && ![RDInternalSchemes() containsObject:scheme]) return text;
        return nil;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)node allValues]) {
            NSString *found = RDURLFromPayload(value);
            if (found) return found;
        }
        return nil;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = RDURLFromPayload(value);
            if (found) return found;
        }
    }
    return nil;
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
    if (!rdEnsureDone) RDEnsureExtension(self);

    if ([type isEqualToString:kMessageEvent] || [type isEqualToString:kPortMessageEvent] ||
        [type hasSuffix:@"WebExtension:Message"] || [type hasSuffix:@"WebExtension:PortMessage"]) {
        NSString *found = RDURLFromPayload(message);
        if (found && RDHandoffAllowed() && RDClaimHandoff(found)) {
            RDLog(@"handoff(script) %@", found);
            RDOpenExternally([NSURL URLWithString:found]);
        }
        %orig;
        return;
    }

    BOOL isRequest = [type isEqualToString:kOnLoadRequestEvent] ||
                      [type hasSuffix:@"OnLoadRequest"] ||
                      [type hasSuffix:@"OnPreNavigation"];
    BOOL isError = [type hasSuffix:@"OnLoadError"];
    BOOL isVisited = [type hasSuffix:@"OnVisited"];
    if ((!isRequest && !isError && !isVisited) || ![message isKindOfClass:[NSDictionary class]]) {
        if ([type hasPrefix:@"GeckoView:WebExtension:On"]) {
            RDLogOnce(type, message);
        } else {
            RDLogTypeOnce(type);
        }
        %orig;
        return;
    }

    NSDictionary *payload = (NSDictionary *)message;
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    if (!uri.length && [payload[@"url"] isKindOfClass:[NSString class]]) uri = payload[@"url"];
    if (!uri.length && [payload[@"lastVisitedURL"] isKindOfClass:[NSString class]]) {
        uri = payload[@"lastVisitedURL"];
    }
    NSURL *url = uri.length ? [NSURL URLWithString:uri] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    BOOL topLevel = RDBoolValue(payload[@"isTopLevel"], YES);
    BOOL userInitiated = RDBoolValue(payload[@"isUserInitiatedNavigation"], YES);
    RDLog(@"%@ scheme=%@ top=%d user=%d msg=%@", type, scheme, topLevel, userInitiated, payload);

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
