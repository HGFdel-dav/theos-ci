#ifndef RD_CLICK_ROUTER_H
#define RD_CLICK_ROUTER_H
#import "RDLinkPolicy.h"

static BOOL RDRouteEnabled(void) {
    return RDReadBoolPref(kEnabledKey, YES) && RDReadBoolPref(kHandoffKey, YES);
}
static BOOL RDExactFlag(id value, BOOL fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}
static BOOL RDWebScheme(NSString *scheme) {
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}
static BOOL RDInternalScheme(NSString *scheme) {
    static NSSet<NSString *> *internal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        internal = [NSSet setWithArray:@[@"about",@"data",@"blob",@"javascript",
            @"moz-extension",@"jar",@"view-source",@"file",@"resource",@"wyciwyg",
            @"ws",@"wss",@"ftp",@"intent",@"reynard",@"chrome",@"chrome-extension"]];
    });
    return [internal containsObject:scheme.lowercaseString];
}
static NSURL *RDAppTarget(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length || text.length >= RD_URL_CAP) return nil;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    char normalized[RD_URL_CAP + 2];
    if (!RDNormalizeAppURL(text.UTF8String, normalized, sizeof(normalized))) return nil;
    NSString *value = [NSString stringWithUTF8String:normalized];
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (!parts.scheme.length || RDWebScheme(parts.scheme) || RDInternalScheme(parts.scheme)) return nil;
    return parts.URL;
}
static NSURL *RDValidatedWebURL(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length || text.length >= RD_URL_CAP) return nil;
    NSCharacterSet *bad = [NSCharacterSet controlCharacterSet];
    if ([text rangeOfCharacterFromSet:bad].location != NSNotFound ||
        [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!RDWebScheme(scheme) || !parts.host.length || parts.user.length || parts.password.length) return nil;
    return parts.URL;
}
/* Telegram does not claim t.me as a Universal Link in this WebView path, so
   translate the public link forms into Telegram's own scheme. Only exact
   t.me paths are mapped; everything else keeps its original navigation. */
static NSURL *RDTelegramAppTarget(NSURL *webURL) {
    if (!webURL || ![webURL.host.lowercaseString isEqualToString:@"t.me"]) return nil;
    NSMutableArray<NSString *> *parts = [[webURL.pathComponents filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString *value, __unused NSDictionary *bindings) {
            return value.length > 0 && ![value isEqualToString:@"/"];
        }]] mutableCopy];
    if (!parts.count || [parts[0] isEqualToString:@"s"]) return nil;
    NSString *invite = nil;
    NSString *username = parts[0];
    if ([username hasPrefix:@"+"]) {
        invite = [username substringFromIndex:1];
    } else if ([username isEqualToString:@"joinchat"] && parts.count > 1) {
        invite = parts[1];
    }
    NSURLComponents *out = [NSURLComponents new];
    out.scheme = @"tg";
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    if (invite.length) {
        out.host = @"join";
        [items addObject:[NSURLQueryItem queryItemWithName:@"invite" value:invite]];
    } else {
        out.host = @"resolve";
        [items addObject:[NSURLQueryItem queryItemWithName:@"domain" value:username]];
        if (parts.count > 1 && [parts[1] integerValue] > 0)
            [items addObject:[NSURLQueryItem queryItemWithName:@"post" value:parts[1]]];
    }
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:webURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"start"] && item.value.length)
            [items addObject:item];
    }
    out.queryItems = items;
    return out.URL;
}

@interface RDRouteReply : NSObject {
    BOOL _finished;
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
    if (_finished) return;
    _finished = YES;
    id<RDEventCallback> callback = self.callback;
    self.callback = nil;
    if ([callback respondsToSelector:@selector(sendSuccess:)]) [callback sendSuccess:@(handled)];
}
@end

@interface RDOpenOperation : NSObject {
    BOOL _finished;
}
@property(nonatomic, strong) NSURL *webURL;
@property(nonatomic, strong) NSURL *appURL;
@property(nonatomic, copy) void (^completion)(BOOL handled);
- (void)start;
@end
@implementation RDOpenOperation
- (void)finish:(BOOL)handled {
    if (_finished) return;
    _finished = YES;
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    if (completion) completion(handled);
}
- (void)tryApp {
    if (_finished || !self.appURL || !RDRouteEnabled() ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self finish:NO];
        return;
    }
    [[UIApplication sharedApplication] openURL:self.appURL options:@{}
        completionHandler:^(BOOL accepted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!_finished) [self finish:accepted];
            });
        }];
}
- (void)start {
    if (_finished) return;
    UIApplication *application = [UIApplication sharedApplication];
    if (!RDRouteEnabled() || application.applicationState != UIApplicationStateActive) {
        [self finish:NO];
        return;
    }
    NSTimeInterval timeout = self.webURL ? 3.0 : 30.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self->_finished) [self finish:NO];
    });
    if (!self.webURL) {
        [self tryApp];
        return;
    }
    [application openURL:self.webURL
                  options:@{UIApplicationOpenURLOptionUniversalLinksOnly:@YES}
       completionHandler:^(BOOL accepted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_finished) return;
            if (accepted) [self finish:YES];
            else if (self.appURL) [self tryApp];
            else [self finish:NO];
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

static NSMutableDictionary *RDWebAttempts(id dispatcher) {
    static NSMapTable *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = [NSMapTable weakToStrongObjectsMapTable]; });
    NSMutableDictionary *attempts = [sessions objectForKey:dispatcher];
    if (!attempts) {
        attempts = [NSMutableDictionary dictionary];
        [sessions setObject:attempts forKey:dispatcher];
    }
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    for (NSString *key in [attempts.allKeys copy]) {
        RDNavigationAttempt *attempt = attempts[key];
        if (attempt.finished && now - attempt.started > 4.0) [attempts removeObjectForKey:key];
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
    attempt.finished = YES;
    attempt.handled = handled;
    NSArray *replies = [attempt.replies copy];
    [attempt.replies removeAllObjects];
    for (RDRouteReply *reply in replies) [reply finish:handled];
}

/* This is called on the main queue only. It owns a callback only when it
   returns YES; otherwise Gecko handles the request exactly as before. */
static BOOL RDHandleClickNavigation(id dispatcher, NSString *type,
                                    NSDictionary *payload,
                                    id<RDEventCallback> callback) {
    BOOL isRequest = [type isEqualToString:@"GeckoView:OnPreNavigation"] ||
                     [type isEqualToString:@"GeckoView:OnLoadRequest"];
    BOOL isNewSession = [type isEqualToString:@"GeckoView:OnNewSession"];
    if ((!isRequest && !isNewSession) || ![payload isKindOfClass:[NSDictionary class]] ||
        ![callback respondsToSelector:@selector(sendSuccess:)]) {
        RDLog(@"route reject reason=event-or-payload event=%@", type);
        return NO;
    }
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    if (!uri.length) { RDLog(@"route reject reason=missing-uri event=%@",type); return NO; }

    NSURLComponents *parts = [NSURLComponents componentsWithString:uri];
    NSString *scheme = parts.scheme.lowercaseString;
    // Only an app's own URL scheme may leave the browser. Ordinary HTTP(S)
    // pages stay in Reynard, including GitHub/Universal-Link pages.
    if (RDWebScheme(scheme)) {
        RDLog(@"route leave-web-uri scheme=%@", scheme);
        return NO;
    }
    BOOL gesture = RDExactFlag(payload[@"hasUserGesture"], NO);
    BOOL topLevel = RDExactFlag(payload[@"isTopLevel"], YES);
    uint32_t flags = [payload[@"flags"] isKindOfClass:[NSNumber class]] ?
                     [payload[@"flags"] unsignedIntValue] : 0;
    BOOL foreground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    BOOL enabled = RDRouteEnabled();
    NSString *trigger = [payload[@"triggerUri"] isKindOfClass:[NSString class]] ? payload[@"triggerUri"] : nil;
    NSURL *webTarget = RDWebScheme(scheme) ? RDValidatedWebURL(uri) : nil;
    NSURL *appTarget = webTarget ? RDTelegramAppTarget(webTarget) : nil;
    // Ordinary HTTP(S) links stay in Reynard. Only explicit app links or a
    // known t.me mapping may leave the browser. GitHub and other Universal
    // Links must not steal a normal page click.
    BOOL webClick = gesture || appTarget != nil || (trigger.length && !(flags & 0x800000));
    BOOL eligible = RDClickEventAllowed(YES, webClick, topLevel, flags, foreground) && enabled;
    RDLog(@"route gate event=%@ scheme=%@ gesture=%d trigger=%@ top=%d flags=0x%x foreground=%d enabled=%d eligible=%d app=%@",
          type, scheme, gesture, trigger ?: @"<none>", topLevel, flags, foreground, enabled, eligible,
          appTarget.scheme ?: @"<none>");
    RDRouteReply *reply = [RDRouteReply new];
    reply.callback = callback;

    /* A link with target=_blank/window.open reaches OnNewSession in the main
       app; this is the one click path that does not need a content process. */
    if (isNewSession) {
        if (!enabled || !foreground) return NO;
        if (!webTarget && !RDAppTarget(uri)) return NO;
        if (webTarget && !appTarget) return NO;
        RDOpenOperation *operation = [RDOpenOperation new];
        operation.webURL = nil;
        operation.appURL = webTarget ? appTarget : RDAppTarget(uri);
        operation.completion = ^(BOOL handled) { [reply finish:handled]; };
        [operation start];
        return YES;
    }

    /* Custom protocols are handled exclusively by RDNativeOnLinkClick. This
       GeckoView notification path only handles an explicit Telegram t.me
       mapping; all other HTTP(S) navigation stays in the browser. */
    if (!RDWebScheme(scheme)) return NO;
    if ([type isEqualToString:@"GeckoView:OnLoadRequest"]) {
        RDNavigationAttempt *attempt = RDWebAttempts(dispatcher)[uri];
        if (!attempt) return NO;
        if (!attempt.finished) [attempt.replies addObject:reply];
        else [reply finish:attempt.handled];
        RDLog(@"route load-phase reuse web finished=%d handled=%d",attempt.finished,attempt.handled);
        return YES;
    }
    if (!eligible) {
        RDLog(@"route reject reason=gate scheme=%@ gesture=%d top=%d flags=0x%x foreground=%d enabled=%d",
              scheme, gesture, topLevel, flags, foreground, enabled);
        return NO;
    }

    if (!webTarget || !appTarget) { RDLog(@"route reject reason=not-app-link"); return NO; }
    NSURL *webURL = webTarget;
    if (trigger.length && parts.fragment.length) {
        NSURLComponents *from = [NSURLComponents componentsWithString:trigger];
        NSURLComponents *to = [parts copy];
        from.fragment = nil; to.fragment = nil;
        if (from.URL && [from.URL isEqual:to.URL]) {
            RDLog(@"route skip reason=same-document-anchor");
            return NO;
        }
    }
    RDNavigationAttempt *attempt = RDBeginWebAttempt(dispatcher, uri, reply);
    if (!attempt) return YES;
    RDOpenOperation *operation = [RDOpenOperation new];
    operation.webURL = nil;
    operation.appURL = appTarget;
    operation.completion = ^(BOOL handled) { RDFinishWebAttempt(attempt, handled); };
    [operation start];
    return YES;
}
#endif
