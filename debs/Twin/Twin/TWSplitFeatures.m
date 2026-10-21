#import "TWSplitFeatures.h"
#import "TWPrefs.h"
#import "TWRuntimeLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// Static sources: sc_arm64.dylib (VM addresses, arm64 slice).
// 0x28288 installs SBIconImageView/SBIconView initWithFrame:, shortcut setter,
// +activateShortcut:withBundleIdentifier:forIconView:, system/section getters.
// 0x2850c -> original init -> two swipes (4/8), cancelsTouchesInView=NO.
// 0x28894 checks Ended -> preferences -> parent SBIconView -> icon bundle ID.
// 0x28adc filters own item then prepends; 0x28ed4 handles only own item.
// 0x4ba4c installs notification hooks. 0x4c364/384 label pull/preview 1/2;
// 0x4c664 consumes that label, extracts notificationRequest, opens once, calls
// completion(NO). Non-target / failure calls original with all arguments.
// PX owns notification taps and URL delivery: never replay those here.
// Explicit gaps: native URL system/shortcut/callback routing (0x49770), and
// SC external bottom regions (0x32df8/0x3350c) have no verified PX equivalent.
// No settings are published for those gaps; no guessed selectors or nil gestures.

static BOOL gSpringBoard;
static void (*gHook)(Class, SEL, IMP, IMP *);
static NSHashTable *gImages, *gIcons;
static NSString *const TWShortcutType = @"com.niubiprass.twin.split";
static char TWUpKey, TWDownKey, TWEngineDefaults, TWOriginalInteraction;
static NSInteger gNotificationTrigger; // main-thread synchronous scope only

static const char *TWType(const char *t) {
    while (t && *t && strchr("rnNoORV", *t)) ++t;
    return t ?: "";
}
// Each character describes one exact ABI category. O = non-block object,
// K = block, b = BOOL (B/c), i = signed 64-bit integer (q/l on arm64).
static BOOL TWABI(Method m, const char *pattern) {
    if (!m || method_getNumberOfArguments(m) != strlen(pattern) - 1) return NO;
    for (NSUInteger i = 0; i < strlen(pattern); ++i) {
        char *raw = i ? method_copyArgumentType(m, (unsigned int)i - 1) : method_copyReturnType(m);
        const char *t = TWType(raw); char p = pattern[i];
        BOOL ok = p == 'O' ? t[0] == '@' && t[1] != '?' :
                  p == 'K' ? t[0] == '@' && t[1] == '?' :
                  p == 'b' ? t[0] == 'B' || t[0] == 'c' :
                  p == 'i' ? t[0] == 'q' || (sizeof(long) == 8 && t[0] == 'l') :
                  t[0] == p;
        free(raw); if (!ok) return NO;
    }
    return YES;
}
static BOOL TWResponds(id obj, NSString *name, const char *abi) {
    return obj && TWABI(class_getInstanceMethod(object_getClass(obj), NSSelectorFromString(name)), abi);
}
static id TWGet(id obj, NSString *name) {
    if (!TWResponds(obj, name, "OO:")) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name)); }
    @catch (__unused NSException *e) { return nil; }
}
static BOOL TWAllowed(void) {
    if (!gSpringBoard || !NSThread.isMainThread || ![TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES]) return NO;
    id manager = TWGet(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    // Unknown lock state fails closed for our entries; original calls still run.
    if (!TWResponds(manager, @"isUILocked", "bO:")) return NO;
    @try { return !((BOOL (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"isUILocked")); }
    @catch (__unused NSException *e) { return NO; }
}
static BOOL TWOn(NSString *key) { return [TWPrefs.shared boolForKey:key defaultValue:NO]; }
static NSString *TWString(id obj) { return [obj isKindOfClass:NSString.class] ? obj : @""; }
static BOOL TWLaunch(NSString *bundleID) {
    if (!TWAllowed() || !bundleID.length || [bundleID isEqual:@"com.apple.springboard"]) return NO;
    Class entry = NSClassFromString(@"PXPanelEntry");
    if (!TWResponds(entry, @"applicationActivated:", "vO:O")) return NO;
    // Verified +applicationActivated: v24@0:8@16; externalOpenApplication: is
    // fullscreen and must not be used for this operation.
    ((void (*)(id, SEL, id))objc_msgSend)(entry, NSSelectorFromString(@"applicationActivated:"), bundleID);
    return YES;
}
static NSString *TWIconBundle(id view) {
    id icon = TWGet(view, @"icon"); // SC 0x29900 -> 0x29814
    if (!icon) return @"";
    NSString *name = NSStringFromClass([icon class]);
    if ([name containsString:@"Folder"] || [name containsString:@"Widget"]) return @"";
    return TWString(TWGet(icon, @"applicationBundleID"));
}
static UIView *TWIconParent(UIView *view) {
    Class cls = NSClassFromString(@"SBIconView");
    for (UIView *v = view; v; v = v.superview) if (cls && [v isKindOfClass:cls]) return v;
    return nil;
}

@interface TWSplitGestureTarget : NSObject <UIGestureRecognizerDelegate>
- (void)swiped:(UISwipeGestureRecognizer *)gesture;
@end
@implementation TWSplitGestureTarget
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!TWAllowed() || !TWIconBundle(TWIconParent(gesture.view)).length) return NO;
    return TWOn(gesture == objc_getAssociatedObject(gesture.view, &TWUpKey) ? @"splitIconSwipeUpEnabled" : @"splitIconSwipeDownEnabled");
}
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || ![self gestureRecognizerShouldBegin:gesture]) return;
    TWLaunch(TWIconBundle(TWIconParent(gesture.view)));
}
@end
static TWSplitGestureTarget *gTarget;
static void TWSyncImage(UIView *view) {
    BOOL enabled = [TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES];
    for (NSNumber *up in @[@YES, @NO]) {
        const void *key = up.boolValue ? &TWUpKey : &TWDownKey;
        UISwipeGestureRecognizer *gesture = objc_getAssociatedObject(view, key);
        if (!gesture) {
            gesture = [[UISwipeGestureRecognizer alloc] initWithTarget:gTarget action:@selector(swiped:)];
            gesture.direction = up.boolValue ? UISwipeGestureRecognizerDirectionUp : UISwipeGestureRecognizerDirectionDown;
            gesture.cancelsTouchesInView = NO; // same as SC 0x285ec / 0x28694
            gesture.delaysTouchesBegan = NO; gesture.delaysTouchesEnded = NO;
            gesture.delegate = gTarget;
            [view addGestureRecognizer:gesture];
            objc_setAssociatedObject(view, key, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        gesture.enabled = enabled && TWOn(up.boolValue ? @"splitIconSwipeUpEnabled" : @"splitIconSwipeDownEnabled");
    }
    BOOL wantInteraction = ((UIGestureRecognizer *)objc_getAssociatedObject(view, &TWUpKey)).enabled ||
                           ((UIGestureRecognizer *)objc_getAssociatedObject(view, &TWDownKey)).enabled;
    NSNumber *prior = objc_getAssociatedObject(view, &TWOriginalInteraction);
    if (wantInteraction) {
        if (!prior) objc_setAssociatedObject(view, &TWOriginalInteraction, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.userInteractionEnabled = YES;
    } else if (prior) {
        view.userInteractionEnabled = prior.boolValue;
        objc_setAssociatedObject(view, &TWOriginalInteraction, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static id TWSplitItem(void) {
    Class cls = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!TWResponds(cls, @"new", "OO:")) return nil;
    id item = TWGet(cls, @"new");
    // SC 0x29c60 uses KVC for these real fields. Validate setter ABIs first.
    if (!TWResponds(item, @"setType:", "vO:O") || !TWResponds(item, @"setLocalizedTitle:", "vO:O")) return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"setType:"), TWShortcutType);
    ((void (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"setLocalizedTitle:"), @"Twin 分屏");
    return item;
}
static void (*gSetItems)(id, SEL, id);
static void TWSetItems(id self, SEL cmd, id items) {
    if (![items isKindOfClass:NSArray.class] && items) { gSetItems(self, cmd, items); return; }
    NSMutableArray *out = [NSMutableArray array];
    for (id item in items) if (![TWString(TWGet(item, @"type")) isEqual:TWShortcutType]) [out addObject:item];
    if (TWAllowed() && TWOn(@"splitIconLongPressMenuEnabled") && TWIconBundle(self).length) {
        id item = TWSplitItem(); if (item) [out insertObject:item atIndex:0];
    }
    gSetItems(self, cmd, items || out.count ? out : nil);
}
static BOOL (*gActivate)(id, SEL, id, id, id);
static BOOL TWActivate(id self, SEL cmd, id item, id bundle, id view) {
    if ([TWString(TWGet(item, @"type")) isEqual:TWShortcutType] && TWOn(@"splitIconLongPressMenuEnabled") &&
        TWLaunch(TWString(bundle).length ? bundle : TWIconBundle(view))) return YES;
    return gActivate(self, cmd, item, bundle, view);
}
static BOOL (*gIsSystem)(id, SEL);
static BOOL TWIsSystem(id self, SEL cmd) {
    if (TWAllowed() && TWOn(@"splitIconLongPressMenuEnabled") && [TWString(TWGet(self, @"type")) isEqual:TWShortcutType]) return YES;
    return gIsSystem(self, cmd);
}
static NSInteger (*gSection)(id, SEL);
static NSInteger TWSection(id self, SEL cmd) {
    if (TWAllowed() && TWOn(@"splitIconLongPressMenuEnabled") && [TWString(TWGet(self, @"type")) isEqual:TWShortcutType]) return 2; // SC 0x29038
    return gSection(self, cmd);
}
static void TWRefreshIcon(id icon) {
    if (gSetItems && TWResponds(icon, @"setApplicationShortcutItems:", "vO:O"))
        TWSetItems(icon, NSSelectorFromString(@"setApplicationShortcutItems:"), TWGet(icon, @"applicationShortcutItems"));
}
static id (*gImageInit)(id, SEL, CGRect), (*gIconInit)(id, SEL, CGRect);
static id TWImageInit(id self, SEL cmd, CGRect frame) {
    id result = gImageInit(self, cmd, frame);
    if ([result isKindOfClass:UIView.class]) { [gImages addObject:result]; TWSyncImage(result); }
    return result;
}
static id TWIconInit(id self, SEL cmd, CGRect frame) {
    id result = gIconInit(self, cmd, frame);
    if (result) { [gIcons addObject:result]; TWRefreshIcon(result); }
    return result;
}

// Same class/selectors and call ordering as SC 0x4be64..0x4c838. Unlike SC's
// unbounded global latch, scopes are restored in @finally: unrelated previews
// and deferred native notifications cannot inherit a stale trigger.
static void (*gClicked)(id, SEL), (*gPreview)(id, SEL);
static void TWClicked(id self, SEL cmd) {
    NSInteger previous = gNotificationTrigger;
    if (TWAllowed()) gNotificationTrigger = 1;
    @try { gClicked(self, cmd); } @finally { gNotificationTrigger = previous; }
}
static void TWPreview(id self, SEL cmd) {
    NSInteger previous = gNotificationTrigger;
    if (TWAllowed()) gNotificationTrigger = 2;
    @try { gPreview(self, cmd); } @finally { gNotificationTrigger = previous; }
}
static NSString *TWRequestBundle(id request) {
    // SC 0x4d458: request.sectionIdentifier -> request.bulletin.sectionID.
    NSString *bundle = TWString(TWGet(request, @"sectionIdentifier"));
    if (!bundle.length) bundle = TWString(TWGet(TWGet(request, @"bulletin"), @"sectionID"));
    return bundle;
}
static void (*gStage)(id, SEL, id, NSInteger, id, id);
static void TWStage(id self, SEL cmd, id presenter, NSInteger stage, id trigger, id completion) {
    NSInteger kind = gNotificationTrigger;
    NSString *key = kind == 1 ? @"splitNotificationPullDownEnabled" : @"splitNotificationLongPressEnabled";
    // Never infer stage numbers or classify an unknown trigger as a gesture.
    if ((kind == 1 || kind == 2) && TWAllowed() && TWOn(key)) {
        id request = TWGet(presenter, @"notificationRequest");
        NSString *bundle = TWRequestBundle(request);
        if (bundle.length) {
            gNotificationTrigger = 0; // consume before opening; blocks reentrancy
            if (TWLaunch(bundle)) {
                // Original 0x4c7f4..0x4c804 is completion(NO), not completion().
                if (completion) ((void (^)(BOOL))completion)(NO);
                return;
            }
        }
    }
    gStage(self, cmd, presenter, stage, trigger, completion);
}

// Native notification taps/URL delivery already have engine consumers. Keep
// their domain and original values, but apply TWEnabled + lock guard at reads.
// Scope the hook to this exact defaults instance, never Settings/global defaults.
static id (*gDefaultsInit)(id, SEL, id);
static id TWDefaultsInit(id self, SEL cmd, id suite) {
    id result = gDefaultsInit(self, cmd, suite);
    if ([TWString(suite) isEqual:@"com.moxuan.parallelx"] && result)
        objc_setAssociatedObject(result, &TWEngineDefaults, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
static BOOL (*gDefaultsBool)(id, SEL, id);
static BOOL TWDefaultsBool(id self, SEL cmd, id key) {
    BOOL value = gDefaultsBool(self, cmd, key);
    if (objc_getAssociatedObject(self, &TWEngineDefaults) &&
        ([key isEqual:@"notificationSplitEnabled"] || [key isEqual:@"urlSplitEnabled"])) return value && TWAllowed();
    return value;
}

// SC 0x36244 / 0x36894: evaluate only Ended, after normal move handling.
// SC 0x9a00 converts 1..100 -> 800+(n-1)*2200/99; n=100 -> 3000.
// Adaptation: reuse PX's REAL move recognizer; no overlays or fake gestures.
// Region is a qualification strip inside the existing PXHostCard. It does not
// enlarge PX's native hit area (external SC corner/bottom regions remain a gap).
static void (*gMoveHost)(id, SEL, id);
static void TWMoveHost(id self, SEL cmd, id sender) {
    BOOL close = NO;
    if ([sender isKindOfClass:UIPanGestureRecognizer.class] && TWAllowed() &&
        [TWPrefs.shared boolForKey:@"splitBottomSwipeUpCloseEnabled" defaultValue:YES] &&
        ((UIPanGestureRecognizer *)sender).state == UIGestureRecognizerStateEnded) {
        UIPanGestureRecognizer *pan = sender;
        Class cardClass = NSClassFromString(@"_TtC9ParallelXP33_0DBF5CFAFFA6A5591ECA11E7E8FF46AE10PXHostCard");
        UIView *card = pan.view;
        while (card && (!cardClass || ![card isKindOfClass:cardClass])) card = card.superview;
        if (card && card.window && TWResponds(self, @"closeTapped", "vO:")) {
            CGPoint delta = [pan translationInView:card];
            CGPoint velocity = [pan velocityInView:card];
            CGPoint end = [pan locationInView:card];
            CGPoint start = CGPointMake(end.x - delta.x, end.y - delta.y);
            CGFloat region = [TWPrefs.shared floatForKey:@"splitGestureRegionSize" defaultValue:18];
            CGFloat threshold = [TWPrefs.shared floatForKey:@"splitBottomSwipeUpCloseThreshold" defaultValue:37];
            region = isfinite(region) ? MIN(44, MAX(8, region)) : 18;
            threshold = isfinite(threshold) ? MIN(100, MAX(1, threshold)) : 37;
            CGFloat speed = 800 + (threshold - 1) * 2200 / 99;
            CGRect strip = CGRectMake(CGRectGetMinX(card.bounds), CGRectGetMaxY(card.bounds) - region,
                                      CGRectGetWidth(card.bounds), region);
            close = CGRectContainsPoint(strip, start) && delta.y <= -24 &&
                    -velocity.y >= speed && -velocity.y >= fabs(velocity.x) * 1.35;
        }
    }
    gMoveHost(self, cmd, sender); // always preserve PX's drag cleanup/geometry commit
    if (close && TWAllowed() && TWResponds(self, @"closeTapped", "vO:"))
        ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"closeTapped"));
}

static BOOL TWHook(Class cls, NSString *name, IMP replacement, IMP *original, const char *abi) {
    if (*original) return YES;
    SEL sel = NSSelectorFromString(name);
    if (!cls || !TWABI(class_getInstanceMethod(cls, sel), abi)) {
        TWRuntimeLog(@"[split] skip %@ %@: unavailable/ABI mismatch", NSStringFromClass(cls), name);
        return NO;
    }
    gHook(cls, sel, replacement, original);
    return *original != NULL;
}
static BOOL TWRectInitABI(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(initWithFrame:));
    if (!m || method_getNumberOfArguments(m) != 3) return NO;
    char *r = method_copyReturnType(m), *t = method_copyArgumentType(m, 2);
    BOOL ok = TWType(r)[0] == '@' && t && strcmp(TWType(t), @encode(CGRect)) == 0;
    free(r); free(t); return ok;
}
static void TWRefresh(CFNotificationCenterRef c, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [TWPrefs.shared reload];
        for (UIView *view in gImages.allObjects) TWSyncImage(view);
        for (id view in gIcons.allObjects) TWRefreshIcon(view);
    });
}
void TWSplitFeaturesStart(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ TWSplitFeaturesStart(); }); return; }
    gSpringBoard = YES;
    if (!gHook) gHook = (void (*)(Class, SEL, IMP, IMP *))dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!gHook) { TWRuntimeLog(@"[split] hook provider unavailable"); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTarget = [TWSplitGestureTarget new];
        gImages = [NSHashTable weakObjectsHashTable]; gIcons = [NSHashTable weakObjectsHashTable];
        // Use the same canonical notification as the preference writer.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TWRefresh,
            (__bridge CFStringRef)[NSString stringWithUTF8String:TWPrefsChangedNotification], NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            TWRefresh(NULL, NULL, NULL, NULL, NULL);
        }];
    });
    TWHook(NSClassFromString(@"PXPanelEntry"), @"moveHost:", (IMP)TWMoveHost, (IMP *)&gMoveHost, "vO:O");
    Class image = NSClassFromString(@"SBIconImageView"), icon = NSClassFromString(@"SBIconView");
    // CGRect initializer has a struct ABI; never reduce it to object arguments.
    if (!gImageInit && TWRectInitABI(image)) gHook(image, @selector(initWithFrame:), (IMP)TWImageInit, (IMP *)&gImageInit);
    if (!gIconInit && TWRectInitABI(icon)) gHook(icon, @selector(initWithFrame:), (IMP)TWIconInit, (IMP *)&gIconInit);
    TWHook(icon, @"setApplicationShortcutItems:", (IMP)TWSetItems, (IMP *)&gSetItems, "vO:O");
    TWHook(object_getClass(icon), @"activateShortcut:withBundleIdentifier:forIconView:", (IMP)TWActivate, (IMP *)&gActivate, "bO:OOO");
    Class item = NSClassFromString(@"SBSApplicationShortcutItem");
    TWHook(item, @"sbh_isSystemShortcut", (IMP)TWIsSystem, (IMP *)&gIsSystem, "bO:");
    TWHook(item, @"sbh_shortcutSection", (IMP)TWSection, (IMP *)&gSection, "iO:");
    Class click = NSClassFromString(@"_UIClickPresentationInteraction");
    TWHook(click, @"_driverClickedUp", (IMP)TWClicked, (IMP *)&gClicked, "vO:");
    TWHook(click, @"_performPreviewPresentation", (IMP)TWPreview, (IMP *)&gPreview, "vO:");
    TWHook(NSClassFromString(@"SBNotificationBannerDestination"),
        @"notificationRequestPresenter:shouldTransitionToStage:forTrigger:completionBlock:",
        (IMP)TWStage, (IMP *)&gStage, "vO:OiOK");
    TWHook(NSUserDefaults.class, @"initWithSuiteName:", (IMP)TWDefaultsInit, (IMP *)&gDefaultsInit, "OO:O");
    TWHook(NSUserDefaults.class, @"boolForKey:", (IMP)TWDefaultsBool, (IMP *)&gDefaultsBool, "bO:O");
    TWRuntimeLog(@"[split] image=%d icon=%d menu=%d notifications=%d nativeGate=%d", !!gImageInit, !!gIconInit, !!gActivate, !!gStage, !!gDefaultsBool);
}
