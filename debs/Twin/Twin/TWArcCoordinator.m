// TWArcCoordinator.m
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import "TWArcWindow.h"
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>
#import <CoreFoundation/CoreFoundation.h>

static void TWArcLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TWArcCoordinator sharedInstance] refreshEnabledState];
    });
}

static const char *TWArcType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type ?: "";
}

static NSMethodSignature *TWArcSignature(id target, SEL selector, NSUInteger arguments) {
    @try {
        if (!target || ![target respondsToSelector:selector]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:selector];
        return sig.numberOfArguments == arguments ? sig : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static id TWArcObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWArcSignature(target, selector, 2);
    if (!sig || TWArcType(sig.methodReturnType)[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id TWArcValue(id target, NSString *key) {
    @try { return [target valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL TWArcBool(id target, NSString *name, BOOL *known) {
    *known = NO;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *sig = TWArcSignature(target, selector, 2);
    if (!sig) return YES;
    @try {
        const char *type = TWArcType(sig.methodReturnType);
        if (!strcmp(type, @encode(BOOL))) {
            BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
            *known = YES; return result;
        }
        if (!strcmp(type, @encode(signed char))) {
            signed char result = ((signed char (*)(id, SEL))objc_msgSend)(target, selector);
            *known = YES; return result != 0;
        }
    } @catch (__unused NSException *exception) {}
    return YES;
}

static BOOL TWArcDeviceUnlocked(void) {
    id manager = TWArcObject(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    BOOL known = NO;
    if (TWArcBool(manager, @"isLocked", &known) || !known) return NO;
    // Cover-sheet/UI lock state, when exposed on this OS, is also authoritative.
    SEL uiLocked = NSSelectorFromString(@"isUILocked");
    @try {
        if ([manager respondsToSelector:uiLocked] &&
            (TWArcBool(manager, @"isUILocked", &known) || !known)) return NO;
    } @catch (__unused NSException *exception) { return NO; }
    return YES; // Missing/changed lock APIs fail closed above.
}

@implementation TWArcCoordinator {
    UIPanGestureRecognizer *_pan;
    TWArcMenuView *_menu;
    CGPoint _startPoint;
    BOOL _hasStartPoint;
    BOOL _tracking;
    BOOL _didPresent;
    BOOL _started;
    NSArray<NSString *> *_cachedBundleIDs;
}

+ (instancetype)sharedInstance {
    static TWArcCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedBundleIDs = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshEnabledState)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            TWArcLockStateChanged, CFSTR("com.apple.springboard.lockstate"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

#pragma mark - lifecycle

- (void)start {
    if (_started) return;
    _started = YES;
    [self attachRecognizer];
    // attach may have been too early (no window yet); retry briefly.
    if (!_pan) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachRecognizer];
        });
    }
}

// Tapping the status bar or system gestures must keep working; we only own
// a thin strip along the chosen edge, outside the top/bottom system zones.
- (void)attachRecognizer {
    if (_pan) return;
    UIWindow *window = nil;
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (w.isKeyWindow || w.windowLevel == UIWindowLevelNormal) { window = w; break; }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    _pan.delegate = self;
    _pan.maximumNumberOfTouches = 1;
    _pan.cancelsTouchesInView = NO;
    [window addGestureRecognizer:_pan];
}

- (void)refreshEnabledState {
    [[TWPrefs shared] reload];
    if (!TWArcDeviceUnlocked() ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) [self cancelCurrentGesture];
}

#pragma mark - gesture delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (recognizer != _pan || !recognizer.view) return NO;
    _hasStartPoint = NO;
    [[TWPrefs shared] reload];
    if (![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES] ||
        !TWArcDeviceUnlocked()) return NO;
    CGPoint point = [touch locationInView:recognizer.view];
    NSInteger side = [[TWPrefs shared] integerForKey:TWKeyArcSide defaultValue:0];
    CGFloat width = [[TWPrefs shared] floatForKey:TWKeyArcTriggerWidth defaultValue:24];
    if (![TWArcGeometry point:point inTriggerRegionForSide:side width:width bounds:recognizer.view.bounds]) return NO;
    _startPoint = point; // UITouch origin, before UIPanGestureRecognizer's threshold.
    _hasStartPoint = YES;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    return recognizer == _pan && _hasStartPoint && TWArcDeviceUnlocked() &&
        [[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO] &&
        [[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES];
}

- (void)cancelCurrentGesture {
    [_menu dismissAnimated:NO];
    _hasStartPoint = NO;
    _tracking = NO;
    _didPresent = NO;
    [self releaseOverlayWindow];
}

// 菜单收起后收尾：先让收起动画画完，再把整个覆盖窗口隐藏并关掉交互。
// 隐藏即彻底让出触摸，空闲时不会挡状态栏、系统手势或前台应用。
- (void)releaseOverlayWindow {
    if (_menu.isPresented) return;
    __weak TWArcCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TWArcCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_menu.isPresented) return;
        strongSelf->_menu.userInteractionEnabled = NO;
        strongSelf->_menu.hidden = YES;
        [[TWArcWindow sharedWindow] hideMenuContainer];
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

#pragma mark - pan handling

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan != _pan) return;
    if (!_hasStartPoint || !TWArcDeviceUnlocked() ||
        ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO] ||
        ![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) {
        [self cancelCurrentGesture];
        return;
    }
    CGPoint p = [pan locationInView:pan.view];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            // Began has already passed UIKit's threshold; do not replace the origin.
            if (!_tracking) {
                CGFloat dx = p.x - _startPoint.x, dy = p.y - _startPoint.y;
                if (hypot(dx, dy) >= 22) {
                    [self presentMenuFromPoint:_startPoint];
                    _tracking = _menu.isPresented;
                }
            }
            if (_tracking) [_menu updateSelectionAtPoint:[pan locationInView:_menu]];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (_tracking) {
                NSString *selected = [_menu finishSelectionAtPoint:[pan locationInView:_menu]];
                if (selected.length && TWArcDeviceUnlocked()) [self launchBundleID:selected];
            }
            _hasStartPoint = NO;
            _tracking = NO;
            _didPresent = NO;
            [self releaseOverlayWindow];
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self cancelCurrentGesture];
            break;
        default: break;
    }
}

- (void)presentMenuFromPoint:(CGPoint)point {
    if (_didPresent || !TWArcDeviceUnlocked()) return;
    UIWindow *reference = (UIWindow *)_pan.view; // the recognizer is attached to the SB window
    if (![reference isKindOfClass:[UIWindow class]] || reference.hidden) return;

    // 层级：自建高层级覆盖窗口（Arc-X 结构），不再塞进 SpringBoard 的普通窗口
    // （UIWindowLevelNormal = 0，会被状态栏与系统界面压住）。取不到可用场景时
    // 退回旧宿主，手势不会哑掉。
    TWArcWindow *host = [TWArcWindow sharedWindow];
    UIView *container = nil;
    if (host && [host attachToSceneFromWindow:reference]) container = [host menuContainer];
    if (!container) {
        container = reference;
    } else {
        [host showMenuContainer];
    }

    _didPresent = YES;
    if (!_menu) {
        _menu = [[TWArcMenuView alloc] initWithFrame:container.bounds];
        _menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        _menu.frame = container.bounds;
    }
    _menu.hidden = NO;
    _menu.userInteractionEnabled = YES;
    [container addSubview:_menu];

    NSArray *bundleIDs = [self recentBundleIDs];
    NSInteger side = [[TWPrefs shared] integerForKey:TWKeyArcSide defaultValue:0];
    CGFloat radius = [[TWPrefs shared] floatForKey:TWKeyArcRadius defaultValue:140];
    NSInteger count = [[TWPrefs shared] integerForKey:TWKeyArcItemCount defaultValue:6];
    count = MAX(2, MIN(8, count));
    if (bundleIDs.count > (NSUInteger)count) bundleIDs = [bundleIDs subarrayWithRange:NSMakeRange(0, (NSUInteger)count)];
    [_menu presentFromTriggerPoint:point bundleIDs:bundleIDs side:side radius:radius menuScale:1.0];
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) {
        AudioServicesPlaySystemSound(1104);
    }
}

#pragma mark - app launching

- (void)launchBundleID:(NSString *)bundleID {
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length || !TWArcDeviceUnlocked()) return;
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) AudioServicesPlaySystemSound(1519);
    // Crane gate first: container switch (possibly biometric) must settle
    // before any launch. completion runs on the main queue.
    [TWCraneBridge prepareLaunchForBundleID:bundleID completion:^(BOOL success) {
        if (!success || !TWArcDeviceUnlocked()) return;
        [self performVerifiedLaunch:bundleID];
    }];
}

// Actual launch, called from the Crane completion on the main queue only.
- (void)performVerifiedLaunch:(NSString *)bundleID {
    // Split-window behavior still depends on the installed ParallelX engine.
    Class pxEntry = NSClassFromString(@"PXPanelEntry");
    SEL pxSelector = NSSelectorFromString(@"applicationActivated:");
    NSMethodSignature *pxSig = TWArcSignature(pxEntry, pxSelector, 3);
    @try {
        if (pxSig && !strcmp(TWArcType(pxSig.methodReturnType), @encode(void)) &&
            TWArcType([pxSig getArgumentTypeAtIndex:2])[0] == '@') {
            ((void (*)(id, SEL, id))objc_msgSend)(pxEntry, pxSelector, bundleID);
            return;
        }
        UIApplication *app = [UIApplication sharedApplication];
        SEL selector = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        NSMethodSignature *sig = TWArcSignature(app, selector, 4);
        if (!sig || TWArcType([sig getArgumentTypeAtIndex:2])[0] != '@') return;
        const char *argument = TWArcType([sig getArgumentTypeAtIndex:3]);
        BOOL boolArgument = !strcmp(argument, @encode(BOOL));
        if (!boolArgument && strcmp(argument, @encode(signed char))) return;
        const char *result = TWArcType(sig.methodReturnType);
        if (strcmp(result, @encode(BOOL)) && strcmp(result, @encode(signed char)) &&
            strcmp(result, @encode(int)) && strcmp(result, @encode(void))) return;
        // NSInvocation marshals the verified return encoding instead of guessing id.
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        invocation.target = app;
        invocation.selector = selector;
        [invocation setArgument:&bundleID atIndex:2];
        BOOL suspended = NO;
        signed char charSuspended = 0;
        if (boolArgument) [invocation setArgument:&suspended atIndex:3];
        else [invocation setArgument:&charSuspended atIndex:3];
        [invocation invoke];
    } @catch (__unused NSException *exception) { /* Private API failure: no launch. */ }
}

#pragma mark - recent apps

- (NSArray<NSString *> *)recentBundleIDs {
    NSMutableArray *ids = [NSMutableArray array];
    // SpringBoard switcher: most recently used apps first.
    Class switcherClass = NSClassFromString(@"SBMainSwitcherViewController");
    if (switcherClass) {
        id shared = TWArcObject(switcherClass, @"sharedInstance");
        id layouts = TWArcObject(shared, @"recentAppLayouts");
        if ([layouts isKindOfClass:[NSArray class]]) {
            for (id layout in layouts) {
                id items = TWArcValue(layout, @"allItems");
                if (![items isKindOfClass:[NSArray class]]) continue;
                for (id item in items) {
                    NSString *bundleID = TWArcValue(item, @"bundleIdentifier");
                    if ([bundleID isKindOfClass:[NSString class]] && bundleID.length && ![ids containsObject:bundleID]) {
                        [ids addObject:bundleID];
                    }
                }
            }
        }
    }
    // Fallback: installed user apps (ordered by localized name).
    if (ids.count < 4) {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            id workspace = TWArcObject(workspaceClass, @"defaultWorkspace");
            id apps = TWArcObject(workspace, @"allApplications");
            if ([apps isKindOfClass:[NSArray class]]) {
                NSMutableArray *extras = [NSMutableArray array];
                for (id proxy in apps) {
                    NSString *bundleID = TWArcValue(proxy, @"bundleIdentifier");
                    NSString *name = TWArcValue(proxy, @"localizedName");
                    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;
                    if ([bundleID hasPrefix:@"com.apple."]) continue; // skip most system apps
                    if (![name isKindOfClass:[NSString class]] || !name.length) name = bundleID;
                    [extras addObject:@{@"id": bundleID, @"name": name}];
                }
                [extras sortUsingComparator:^NSComparisonResult(id a, id b) {
                    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
                }];
                for (NSDictionary *entry in extras) {
                    if (ids.count >= 8) break;
                    if (![ids containsObject:entry[@"id"]]) [ids addObject:entry[@"id"]];
                }
            }
        }
    }
    return ids;
}

@end