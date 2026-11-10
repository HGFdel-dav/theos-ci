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
static BOOL RDAppScheme(NSString *scheme) {
    static NSSet *internal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        internal = [NSSet setWithArray:@[
            @"http", @"https", @"about", @"data", @"blob", @"javascript",
            @"moz-extension", @"jar", @"view-source", @"file", @"resource",
            @"wyciwyg", @"ws", @"wss", @"ftp", @"intent", @"reynard",
            @"chrome", @"chrome-extension"
        ]];
    });
    return scheme.length > 0 && ![internal containsObject:scheme];
}
static NSURL *RDValidatedRouteURL(NSString *text, BOOL web) {
    if (![text isKindOfClass:[NSString class]] || !text.length || text.length >= RD_URL_CAP) return nil;
    NSCharacterSet *bad = [NSCharacterSet controlCharacterSet];
    if ([text rangeOfCharacterFromSet:bad].location != NSNotFound ||
        [text rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    NSString *scheme = parts.scheme.lowercaseString;
    if (web ? !RDWebScheme(scheme) : !RDAppScheme(scheme)) return nil;
    if (web && (!parts.host.length || parts.user.length || parts.password.length)) return nil;
    return parts.URL;
}
static NSURL *RDNormalizedAppTarget(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    char normalized[RD_URL_CAP + 2];
    if (!RDNormalizeAppURL(text.UTF8String, normalized, sizeof(normalized))) return nil;
    return RDValidatedRouteURL([NSString stringWithUTF8String:normalized], NO);
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
    if (!isRequest || ![payload isKindOfClass:[NSDictionary class]] ||
        ![callback respondsToSelector:@selector(sendSuccess:)]) return NO;
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    if (!uri.length) return NO;

    NSURLComponents *parts = [NSURLComponents componentsWithString:uri];
    NSString *scheme = parts.scheme.lowercaseString;
    BOOL gesture = RDExactFlag(payload[@"hasUserGesture"], NO);
    BOOL topLevel = RDExactFlag(payload[@"isTopLevel"], YES);
    uint32_t flags = [payload[@"flags"] isKindOfClass:[NSNumber class]] ?
                     [payload[@"flags"] unsignedIntValue] : 0;
    BOOL foreground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    BOOL eligible = RDClickEventAllowed(YES, gesture, topLevel, flags, foreground) && RDRouteEnabled();
    RDRouteReply *reply = [RDRouteReply new];
    reply.callback = callback;

    /* A later OnLoadRequest is only a reply phase of the earlier decision. */
    if ([type isEqualToString:@"GeckoView:OnLoadRequest"] &&
        (RDWebScheme(scheme) || RDAppScheme(scheme))) {
        RDNavigationAttempt *attempt = RDWebAttempts(dispatcher)[uri];
        if (attempt && !attempt.finished) [attempt.replies addObject:reply];
        else [reply finish:attempt ? attempt.handled : NO];
        return YES;
    }
    if (!eligible) return NO;

    if (RDWebScheme(scheme)) {
        NSURL *webURL = RDValidatedRouteURL(uri, YES);
        if (!webURL) return NO;
        NSString *trigger = [payload[@"triggerUri"] isKindOfClass:[NSString class]] ? payload[@"triggerUri"] : nil;
        if (trigger.length && parts.fragment.length) {
            NSURLComponents *from = [NSURLComponents componentsWithString:trigger];
            NSURLComponents *to = [parts copy];
            from.fragment = nil; to.fragment = nil;
            if (from.URL && [from.URL isEqual:to.URL]) return NO;
        }
        RDNavigationAttempt *attempt = RDBeginWebAttempt(dispatcher, uri, reply);
        if (!attempt) return YES;
        RDOpenOperation *operation = [RDOpenOperation new];
        operation.webURL = webURL;
        operation.completion = ^(BOOL handled) { RDFinishWebAttempt(attempt, handled); };
        [operation start];
        return YES;
    }

    NSURL *appURL = RDNormalizedAppTarget(uri);
    if (!appURL) return NO;
    RDNavigationAttempt *attempt = RDBeginWebAttempt(dispatcher, uri, reply);
    if (!attempt) return YES;
    /* Keep the Gecko callback pending until LaunchServices reports whether
       the target app accepted the exact clicked URI. Failure returns NO so the
       original Gecko path remains available; success blocks it exactly once. */
    RDOpenOperation *operation = [RDOpenOperation new];
    operation.appURL = appURL;
    operation.completion = ^(BOOL accepted) { RDFinishWebAttempt(attempt, accepted); };
    dispatch_async(dispatch_get_main_queue(), ^{ [operation start]; });
    return YES;
}
#endif
