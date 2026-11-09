#ifndef RD_CLICK_ROUTER_H
#define RD_CLICK_ROUTER_H
#import "RDLinkPolicy.h"
#import "RDReplyGate.h"

static BOOL RDRouteEnabled(void) {
    return RDReadBoolPref(kEnabledKey, YES) && RDReadBoolPref(kHandoffKey, YES);
}
static BOOL RDExactFlag(id value, BOOL fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}
static BOOL RDWebScheme(NSString *scheme) {
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}
static BOOL RDAppScheme(NSString *scheme) {
    static NSSet<NSString *> *internal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        internal = [NSSet setWithArray:@[@"http", @"https", @"about", @"data", @"blob", @"javascript",
            @"moz-extension", @"jar", @"view-source", @"file", @"resource", @"wyciwyg", @"ws", @"wss",
            @"ftp", @"intent", @"reynard", @"chrome", @"chrome-extension"]];
    });
    return scheme.length > 0 && ![internal containsObject:scheme];
}
static NSURL *RDValidatedRouteURL(NSString *text, BOOL web) {
    if (![text isKindOfClass:[NSString class]] || !text.length || text.length > RD_URL_CAP - 1) return nil;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound ||
        [text rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    NSString *scheme = parts.scheme.lowercaseString;
    if (web ? !RDWebScheme(scheme) : !RDAppScheme(scheme)) return nil;
    if (web && (!parts.host.length || parts.user.length || parts.password.length)) return nil;
    return parts.URL;
}
static NSURL *RDNormalizedAppTarget(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    const char *input = text.UTF8String;
    char normalized[RD_URL_CAP + 2];
    if (!input || !RDNormalizeAppURL(input, normalized, sizeof(normalized))) return nil;
    return RDValidatedRouteURL([NSString stringWithUTF8String:normalized], NO);
}

@interface RDRouteReply : NSObject {
    RDReplyGate _gate;
}
@property(nonatomic, strong) id<RDEventCallback> callback;
- (void)finish:(BOOL)handled;
@end
@implementation RDRouteReply
- (void)finish:(BOOL)handled {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finish:handled]; });
        return;
    }
    if (!RDReplyFinish(&_gate, handled)) return;
    id<RDEventCallback> callback = self.callback;
    self.callback = nil;
    [callback sendSuccess:@(handled)];
}
@end

@interface RDOpenOperation : NSObject {
    RDReplyGate _gate;
}
@property(nonatomic, strong) NSURL *webURL;
@property(nonatomic, strong) NSURL *appURL;
@property(nonatomic, copy) void (^completion)(BOOL);
- (void)start;
- (void)finish:(BOOL)opened;
- (void)tryApp;
@end
@implementation RDOpenOperation
- (void)finish:(BOOL)opened {
    if (!RDReplyFinish(&_gate, opened)) return;
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    if (completion) completion(opened);
}
- (void)tryApp {
    if (_gate.finished) return;
    UIApplication *application = [UIApplication sharedApplication];
    if (!self.appURL || !RDRouteEnabled() || application.applicationState != UIApplicationStateActive) {
        [self finish:NO]; return;
    }
    [application openURL:self.appURL options:@{} completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_gate.finished) {
                RDLog(@"handoff custom accepted=%d", success);
                [self finish:success];
            }
        });
    }];
}
- (void)start {
    UIApplication *application = [UIApplication sharedApplication];
    if (!RDRouteEnabled() || application.applicationState != UIApplicationStateActive) {
        [self finish:NO]; return;
    }
    NSTimeInterval timeout = self.webURL ? 3.0 : 30.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_gate.finished) {
            RDLog(@"handoff timed out; no late fallback");
            [self finish:NO];
        }
    });
    if (!self.webURL) { [self tryApp]; return; }
    [application openURL:self.webURL options:@{UIApplicationOpenURLOptionUniversalLinksOnly: @YES}
      completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_gate.finished) return;
            if (success) {
                RDLog(@"handoff universal accepted=1");
                [self finish:YES];
            } else if (self.appURL) {
                [self tryApp];
            } else {
                // Return false to Gecko so the SAME navigation continues,
                // including its original URL, query, fragment and target.
                RDLog(@"no universal handler; continue original web navigation");
                [self finish:NO];
            }
        });
    }];
}
@end

@interface RDNavigationAttempt : NSObject
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL handled;
@property(nonatomic, strong) NSMutableArray<RDRouteReply *> *replies;
@end
@implementation RDNavigationAttempt
@end

/* All state is per live dispatcher and accessed on main. The later load phase
   reuses the preceding decision; only PreNavigation may start an OS request. */
static NSMutableDictionary *RDWebAttempts(id dispatcher) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = [NSMapTable weakToStrongObjectsMapTable]; });
    NSMutableDictionary *attempts = [sessions objectForKey:dispatcher];
    if (!attempts) { attempts = [NSMutableDictionary dictionary]; [sessions setObject:attempts forKey:dispatcher]; }
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    for (NSString *key in [attempts.allKeys copy]) {
        RDNavigationAttempt *attempt = attempts[key];
        if (attempt.finished && now - attempt.started > 3.5) [attempts removeObjectForKey:key];
    }
    return attempts;
}
static RDNavigationAttempt *RDBeginWebAttempt(id dispatcher, NSString *uri, RDRouteReply *reply) {
    NSMutableDictionary *attempts = RDWebAttempts(dispatcher);
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    RDNavigationAttempt *existing = attempts[uri];
    if (existing && (!existing.finished || now - existing.started < 0.35)) {
        if (existing.finished) [reply finish:existing.handled];
        else [existing.replies addObject:reply];
        return nil;
    }
    if (attempts.count >= 32) { [reply finish:NO]; return nil; }
    RDNavigationAttempt *attempt = [RDNavigationAttempt new];
    attempt.started = now;
    attempt.replies = [NSMutableArray arrayWithObject:reply];
    attempts[uri] = attempt;
    return attempt;
}
static void RDFinishWebAttempt(RDNavigationAttempt *attempt, BOOL handled) {
    if (attempt.finished) return;
    attempt.finished = YES; attempt.handled = handled;
    NSArray *replies = [attempt.replies copy];
    [attempt.replies removeAllObjects];
    for (RDRouteReply *reply in replies) [reply finish:handled];
}

static BOOL RDReservedBridge(NSURLComponents *parts) {
    NSString *host = parts.host.lowercaseString;
    return [host isEqualToString:@"reynarddefault.invalid"] ||
           [host isEqualToString:@"reynarddefault.open"];
}
static BOOL RDExactBridge(NSURLComponents *parts) {
    return [parts.scheme.lowercaseString isEqualToString:@"https"] &&
           [parts.host.lowercaseString isEqualToString:@"reynarddefault.invalid"] &&
           [parts.percentEncodedPath isEqualToString:@"/.well-known/handoff/v2"] &&
           !parts.user.length && !parts.password.length && !parts.port && !parts.percentEncodedQuery.length;
}
static BOOL RDClaimClickID(id dispatcher, NSString *identifier, uint64_t now) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = [NSMapTable weakToStrongObjectsMapTable]; });
    NSMutableDictionary *seen = [sessions objectForKey:dispatcher];
    if (!seen) { seen = [NSMutableDictionary dictionary]; [sessions setObject:seen forKey:dispatcher]; }
    for (NSString *key in [seen.allKeys copy]) {
        uint64_t saved = [seen[key] unsignedLongLongValue];
        if (now > saved && now - saved > 10000) [seen removeObjectForKey:key];
    }
    if (seen[identifier] || seen.count >= 64) return NO;
    seen[identifier] = @(now);
    return YES;
}

/* Bridge disabled: replay the original link through Gecko, never open an app.
   This keeps the switch meaningful even while an already-injected script remains
   alive in an old tab. The replay bypass is exact-URI and expires quickly. */
static NSMapTable *RDReplayMap(void) {
    static NSMapTable *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMapTable weakToStrongObjectsMapTable]; });
    return map;
}
static BOOL RDIsBrowserReplay(id dispatcher, NSString *uri) {
    NSDictionary *record = [RDReplayMap() objectForKey:dispatcher];
    if (!record) return NO;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now > [record[@"expires"] doubleValue]) {
        [RDReplayMap() removeObjectForKey:dispatcher]; return NO;
    }
    return [record[@"uri"] isEqualToString:uri];
}
static void RDResumeOriginalNavigation(id dispatcher, NSString *uri) {
    id backend = objc_getAssociatedObject(dispatcher, &kRDBackendKey);
    if (![backend respondsToSelector:@selector(dispatchToGecko:message:callback:)]) {
        RDLog(@"handoff disabled: browser backend unavailable; document retained"); return;
    }
    [RDReplayMap() setObject:@{@"uri": uri, @"expires": @([NSProcessInfo processInfo].systemUptime + 2.0)} forKey:dispatcher];
    dispatch_async(dispatch_get_main_queue(), ^{
        [(id<RDGeckoDispatch>)backend dispatchToGecko:@"GeckoView:LoadUri"
          message:@{@"uri": uri, @"flags": @0, @"headerFilter": @1} callback:nil];
    });
}

/* Called ONLY on the main queue. This component owns the callback only when
   returning YES. Returning NO leaves the original application entirely in charge. */
static BOOL RDHandleClickNavigation(id dispatcher, NSString *type, NSDictionary *payload,
                                   id<RDEventCallback> callback) {
    BOOL isRequest = [type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                     [type isEqualToString:@"GeckoView:OnLoadRequest"];
    if (!isRequest || ![payload isKindOfClass:[NSDictionary class]] ||
        ![callback respondsToSelector:@selector(sendSuccess:)]) return NO;
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    if (!uri.length || RDIsBrowserReplay(dispatcher, uri)) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithString:uri];
    BOOL bridge = RDReservedBridge(parts);
    BOOL enabled = RDRouteEnabled();
    // hasUserGesture is supplied by Gecko. Missing/NSNull is false. An event
    // that merely says 'user initiated navigation' is not enough by itself.
    BOOL gesture = RDExactFlag(payload[@"hasUserGesture"], NO);
    BOOL top = RDExactFlag(payload[@"isTopLevel"], YES);
    uint32_t flags = [payload[@"flags"] isKindOfClass:[NSNumber class]] ? [payload[@"flags"] unsignedIntValue] : 0;
    BOOL foreground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    BOOL clickEligible = RDClickEventAllowed(isRequest, gesture, top, flags, foreground);
    BOOL eligible = clickEligible && enabled;
    RDRouteReply *reply = [RDRouteReply new]; reply.callback = callback;

    if (bridge) {
        // Always deny reserved transport URLs, including malformed/legacy ones.
        // They must never leak out as actual network navigations or app URLs.
        [reply finish:YES];
        if (!clickEligible || !RDExactBridge(parts)) {
            RDLog(@"handoff bridge rejected (gesture=%d enabled=%d)", gesture, enabled);
            return YES;
        }
        RDClickPayload data;
        if (!RDParseClickPayload(parts.percentEncodedFragment.UTF8String, &data)) {
            RDLog(@"handoff bridge rejected: bad encoding"); return YES;
        }
        uint64_t now = (uint64_t)([NSDate date].timeIntervalSince1970 * 1000.0);
        if (!RDPayloadFresh(now, data.time_ms)) { RDLog(@"handoff bridge rejected: expired"); return YES; }
        NSString *identifier = [NSString stringWithUTF8String:data.id];
        NSString *app = [NSString stringWithUTF8String:data.app];
        NSString *web = [NSString stringWithUTF8String:data.web];
        NSURL *appURL = app.length ? RDNormalizedAppTarget(app) : nil;
        NSURL *webURL = web.length ? RDValidatedRouteURL(web, YES) : nil;
        if ((app.length && !appURL) || (web.length && !webURL) || (!appURL && !webURL)) return YES;
        // v2 content-script bridge is exclusively for custom-scheme anchors.
        // HTTP links stay on Gecko's own request, whose callback permits fallback.
        if (webURL || !appURL) return YES;
        if (!RDClaimClickID(dispatcher, identifier, now)) return YES;
        if (!enabled) {
            RDResumeOriginalNavigation(dispatcher, app);
            return YES;
        }
        RDLog(@"handoff click id=%@ scheme=%@", identifier, appURL.scheme.lowercaseString);
        RDOpenOperation *operation = [RDOpenOperation new];
        operation.appURL = appURL;
        operation.completion = ^(BOOL opened) {
            if (!opened) RDLog(@"handoff not accepted; original document retained");
        };
        // Let Gecko process the deny reply before launching the other app.
        dispatch_async(dispatch_get_main_queue(), ^{ [operation start]; });
        return YES;
    }
    if (!eligible) return NO;
    NSString *scheme = parts.scheme.lowercaseString;
    // PreNavigation is the validated top-level decision point in this port.
    // OnLoadRequest is a subsequent load phase: never issue another openURL
    // for it, including when a late phase arrives after the short burst window.
    // A bridge is different: its explicit click ID is handled above.
    if ([type isEqualToString:@"GeckoView:OnLoadRequest"] &&
        (RDWebScheme(scheme) || RDAppScheme(scheme))) {
        RDNavigationAttempt *attempt = RDWebAttempts(dispatcher)[uri];
        if (attempt && !attempt.finished) [attempt.replies addObject:reply];
        else [reply finish:attempt ? attempt.handled : NO];
        return YES;
    }
    if (RDWebScheme(scheme)) {
        NSURL *webURL = RDValidatedRouteURL(uri, YES);
        if (!webURL) return NO;
        // Same-document anchors do not represent an external app request.
        NSString *trigger = [payload[@"triggerUri"] isKindOfClass:[NSString class]] ? payload[@"triggerUri"] : nil;
        if (trigger.length && parts.fragment.length) {
            NSURLComponents *from = [NSURLComponents componentsWithString:trigger];
            NSURLComponents *to = [parts copy]; from.fragment = nil; to.fragment = nil;
            if (from.URL && [from.URL isEqual:to.URL]) return NO;
        }
        RDNavigationAttempt *attempt = RDBeginWebAttempt(dispatcher, uri, reply);
        if (!attempt) return YES;
        RDOpenOperation *operation = [RDOpenOperation new]; operation.webURL = webURL;
        operation.completion = ^(BOOL handled) { RDFinishWebAttempt(attempt, handled); };
        [operation start];
        return YES;
    }
    // User-gesture custom navigations from buttons/window.open are accepted too.
    // No gesture -> fail open to Reynard; no auto-handoff on visited/error events.
    NSURL *appURL = RDNormalizedAppTarget(uri);
    if (!appURL) return NO;
    RDNavigationAttempt *attempt = RDBeginWebAttempt(dispatcher, uri, reply);
    if (!attempt) return YES;
    RDFinishWebAttempt(attempt, YES);
    RDOpenOperation *operation = [RDOpenOperation new]; operation.appURL = appURL;
    operation.completion = ^(BOOL opened) {
        RDLog(@"handoff custom navigation accepted=%d", opened);
    };
    dispatch_async(dispatch_get_main_queue(), ^{ [operation start]; });
    return YES;
}
#endif
