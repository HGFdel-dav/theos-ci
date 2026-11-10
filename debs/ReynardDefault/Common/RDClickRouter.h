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
        ![callback respondsToSelector:@selector(sendSuccess:)]) {
        RDLog(@"route reject reason=event-or-payload event=%@", type);
        return NO;
    }
    NSString *uri = [payload[@"uri"] isKindOfClass:[NSString class]] ? payload[@"uri"] : nil;
    if (!uri.length) { RDLog(@"route reject reason=missing-uri event=%@",type); return NO; }

    NSURLComponents *parts = [NSURLComponents componentsWithString:uri];
    NSString *scheme = parts.scheme.lowercaseString;
    BOOL gesture = RDExactFlag(payload[@"hasUserGesture"], NO);
    BOOL topLevel = RDExactFlag(payload[@"isTopLevel"], YES);
    uint32_t flags = [payload[@"flags"] isKindOfClass:[NSNumber class]] ?
                     [payload[@"flags"] unsignedIntValue] : 0;
    BOOL foreground = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
    BOOL enabled = RDRouteEnabled();
    BOOL eligible = RDClickEventAllowed(YES, gesture, topLevel, flags, foreground) && enabled;
    RDLog(@"route gate event=%@ scheme=%@ gesture=%d top=%d flags=0x%x foreground=%d enabled=%d eligible=%d",
          type, scheme, gesture, topLevel, flags, foreground, enabled, eligible);
    RDRouteReply *reply = [RDRouteReply new];
    reply.callback = callback;

    /* Custom protocols are handled exclusively by RDNativeOnLinkClick. This
       GeckoView notification path is only used for HTTP(S) Universal Links. */
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

    NSURL *webURL = RDValidatedWebURL(uri);
    if (!webURL) { RDLog(@"route reject reason=invalid-web-uri"); return NO; }
    NSString *trigger = [payload[@"triggerUri"] isKindOfClass:[NSString class]] ? payload[@"triggerUri"] : nil;
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
    operation.webURL = webURL;
    operation.completion = ^(BOOL handled) { RDFinishWebAttempt(attempt, handled); };
    [operation start];
    return YES;
}
#endif
