#import "TWURLRouting.h"
#import "TWPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <string.h>

// SC arm64: coordinator 0x49770, core URL 0x49460, workspace 0x4ec8c.
// See twin-url-evidence.md for exact filters, PX substitutions and limits.
static BOOL gSpringBoard;
static void (*gHook)(Class, SEL, IMP, IMP *);
static __thread unsigned gDelivery, gRequestDepth;
static __thread BOOL gBackground, gClosing;
static char gPXDefaults;
static NSString *gOutboundSource, *gOutboundTarget;
static NSTimeInterval gOutboundTime;

static const char *TWUType(const char *t) {
    while (t && *t && strchr("rnNoORV", *t)) ++t;
    return t ?: "";
}
// O = non-block object, K = block, b = BOOL; other characters exact ABI.
static BOOL TWUABI(Method m, const char *p) {
    if (!m || method_getNumberOfArguments(m) != strlen(p)-1) return NO;
    for (NSUInteger i=0; i<strlen(p); ++i) {
        char *raw = i ? method_copyArgumentType(m, (unsigned)i-1) : method_copyReturnType(m);
        const char *t = TWUType(raw);
        BOOL ok = p[i]=='O' ? t[0]=='@' && t[1]!='?' :
                  p[i]=='K' ? t[0]=='@' && t[1]=='?' :
                  p[i]=='b' ? t[0]=='B' || t[0]=='c' : t[0]==p[i];
        free(raw); if (!ok) return NO;
    }
    return YES;
}
static BOOL TWUHas(id obj, NSString *name, const char *abi) {
    return obj && TWUABI(class_getInstanceMethod(object_getClass(obj), NSSelectorFromString(name)), abi);
}
static id TWUGet(id obj, NSString *name) {
    if (!TWUHas(obj, name, "OO:")) return nil;
    @try { return ((id (*)(id,SEL))objc_msgSend)(obj, NSSelectorFromString(name)); }
    @catch (__unused NSException *e) { return nil; }
}
static NSString *TWUStr(id obj) { return [obj isKindOfClass:NSString.class] && [obj length] ? obj : nil; }
static BOOL TWUOn(NSString *key) { return [TWPrefs.shared boolForKey:key defaultValue:NO]; }
static BOOL TWUAllowed(void) {
    if (!gSpringBoard || !NSThread.isMainThread || ![TWPrefs.shared boolForKey:TWKeyEnabled defaultValue:YES]) return NO;
    id lock = TWUGet(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
    if (!TWUHas(lock, @"isUILocked", "bO:")) return NO;
    @try { return !((BOOL (*)(id,SEL))objc_msgSend)(lock, NSSelectorFromString(@"isUILocked")); }
    @catch (__unused NSException *e) { return NO; }
}
static id TWUPXValue(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.moxuan.parallelx")));
}
static BOOL TWUMaster(void) {
    id value = TWUPXValue(@"urlSplitEnabled");
    // PX 0x7dd8 -> 0x7e04: absent key means YES, not NO.
    return !value || ([value respondsToSelector:@selector(boolValue)] && [value boolValue]);
}
static NSDictionary *TWUDictionary(id options) {
    id value = [options isKindOfClass:NSDictionary.class] ? options : TWUGet(options, @"dictionary");
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static id TWUOption(id options, NSString *key) {
    NSDictionary *d = TWUDictionary(options);
    id value = d[key]; // SC 0x4b328: outer dictionary first, then payload.
    if (value) return value;
    id payload = d[@"__PayloadOptions"];
    return [payload isKindOfClass:NSDictionary.class] ? payload[key] : nil;
}
static NSString *TWUDirectBundle(id obj) {
    NSString *bundle = TWUStr(obj); if (bundle) return bundle;
    for (NSString *key in @[@"bundleIdentifier", @"identifier", @"embeddedApplicationIdentifier"]) {
        bundle = TWUStr(TWUGet(obj, key)); if (bundle) return bundle;
    }
    return nil;
}
static NSString *TWUBundle(id obj) {
    NSString *bundle = TWUDirectBundle(obj); if (bundle) return bundle;
    // SC constant array 0x94f80, in original order; no recursive guessing.
    for (NSString *key in @[@"application", @"_application", @"targetApplication", @"clientApplication",
        @"scene", @"_scene", @"mainScene", @"workspaceScene", @"applicationScene", @"clientProcess",
        @"process", @"_process", @"originatingProcess", @"requestingProcess", @"processIdentity", @"identity"]) {
        bundle = TWUDirectBundle(TWUGet(obj, key)); if (bundle) return bundle;
    }
    return nil;
}
static NSString *TWUSource(id options, id origin) {
    id payload = TWUDictionary(options)[@"__PayloadOptions"];
    NSString *bundle = [payload isKindOfClass:NSDictionary.class] ? TWUStr(payload[@"UIApplicationLaunchOptionsSourceApplicationKey"]) : nil;
    return bundle ?: TWUBundle(origin);
}
static NSString *TWUURL(id value) {
    return TWUStr([value isKindOfClass:NSURL.class] ? [value absoluteString] : value);
}
static BOOL TWUPayload(id options) {
    if (TWUURL(TWUOption(options, @"__PayloadURL"))) return YES;
    id actions = TWUOption(options, @"__Actions");
    if (!actions || actions == NSNull.null) return NO;
    if ([actions isKindOfClass:NSArray.class] || [actions isKindOfClass:NSSet.class] || [actions isKindOfClass:NSDictionary.class]) return [actions count] > 0;
    return YES; // original 0x4a8ac treats other non-null objects as payload.
}
static BOOL TWUOne(id options, NSString *key) {
    id value = TWUOption(options, key);
    return [value respondsToSelector:@selector(integerValue)] && [value integerValue] == 1;
}
static BOOL TWUNotification(NSString *origin) {
    return [@[@"BulletinDestinationBanner", @"SBSLaunchOriginBulletinDestinationBanner",
        @"BulletinDestinationCoverSheet", @"SBSLaunchOriginBulletinDestinationCoverSheet"] containsObject:origin ?: @""];
}
static BOOL TWUSuspended(id options) {
    for (NSString *key in @[@"__ActivateSuspended", @"FBSOpenApplicationOptionKeyActivateSuspended", @"_FBSOpenApplicationOptionKeyActivateSuspended"]) {
        id value = TWUOption(options,key);
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) return YES;
    }
    return NO;
}
static BOOL TWUPXBool(NSString *selector, NSString *bundle) {
    Class px = NSClassFromString(@"PXPanelEntry");
    if (!bundle.length || !TWUHas(px, selector, "bO:O")) return NO;
    return ((BOOL (*)(id,SEL,id))objc_msgSend)(px,NSSelectorFromString(selector),bundle);
}
static NSString *TWUFrontmost(void) {
    return TWUStr(TWUGet(TWUGet(NSClassFromString(@"PXSceneBridge"), @"sharedBridge"), @"frontmostBundleID"));
}
static BOOL TWUEligible(NSString *bundle) {
    if (!TWUAllowed() || !TWUMaster() || !bundle.length ||
        [@[@"com.apple.springboard", @"com.apple.InCallService"] containsObject:bundle]) return NO;
    id excluded = TWUPXValue(@"urlSplitExcluded");
    if ([excluded isKindOfClass:NSArray.class] && [excluded containsObject:bundle]) return NO;
    // SC 0x4a394 rejects the fullscreen foreground target.
    NSString *front = TWUFrontmost();
    if (!front || [front isEqual:bundle]) return NO;
    id controller = TWUGet(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    if (!TWUHas(controller, @"applicationWithBundleIdentifier:", "OO:O")) return NO;
    id app = ((id (*)(id,SEL,id))objc_msgSend)(controller,NSSelectorFromString(@"applicationWithBundleIdentifier:"),bundle);
    return [TWUStr(TWUGet(app,@"bundleIdentifier")) isEqual:bundle];
}
static void TWUResetCallback(void) { gOutboundSource=nil; gOutboundTarget=nil; gOutboundTime=0; }
// SC 0x4a104: observe BEFORE opening or forwarding, exact reversed pair, 120s.
static BOOL TWUObserve(NSString *source, NSString *target) {
    if (!TWUAllowed() || !TWUMaster() || !TWUOn(@"splitCallbackAutoCloseFloatingEnabled")) { TWUResetCallback(); return NO; }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (gOutboundTime <= 0 || now-gOutboundTime > 120) TWUResetCallback();
    if (source.length && target.length && [source isEqual:gOutboundTarget] && [target isEqual:gOutboundSource]) {
        Class px=NSClassFromString(@"PXPanelEntry");
        id window=nil;
        if (TWUHas(px,@"hostedURLReturnWindowForSource:target:","OO:OO"))
            window=((id (*)(id,SEL,id,id))objc_msgSend)(px,NSSelectorFromString(@"hostedURLReturnWindowForSource:target:"),source,target);
        TWUResetCallback();
        if ([window isKindOfClass:UIWindow.class] && TWUHas(px,@"completeURLReturnFromSource:window:","vO:OO")) {
            BOOL previous=gClosing; gClosing=YES;
            @try { ((void (*)(id,SEL,id,id))objc_msgSend)(px,NSSelectorFromString(@"completeURLReturnFromSource:window:"),source,window); }
            @finally { gClosing=previous; }
        }
        return YES; // callback must continue natively, never open its target again.
    }
    if (source.length && target.length && ![source isEqual:target] && [source isEqual:TWUFrontmost()] &&
        !TWUPXBool(@"isInteractiveHostedURLSource:",target)) {
        gOutboundSource=[source copy]; gOutboundTarget=[target copy]; gOutboundTime=now;
    }
    return NO;
}
static void TWUDeliver(void (^forward)(void), BOOL background) {
    BOOL previous=gBackground; ++gDelivery; gBackground=previous || background;
    @try { forward(); } @finally { gBackground=previous; --gDelivery; }
}
static BOOL TWUOpen(NSString *bundle) {
    Class px=NSClassFromString(@"PXPanelEntry");
    if (!TWUEligible(bundle) || !TWUHas(px,@"applicationActivated:","vO:O")) return NO;
    if (!TWUPXBool(@"isInteractiveHostedURLSource:",bundle))
        TWUDeliver(^{ ((void (*)(id,SEL,id))objc_msgSend)(px,NSSelectorFromString(@"applicationActivated:"),bundle); },NO);
    // PX API is void; this means the verified entry was called, not a success receipt.
    return YES;
}
static void TWUHome(void) {
    id springBoard=TWUGet(NSClassFromString(@"SpringBoard"),@"sharedApplication");
    if (TWUHas(springBoard,@"_handleGotoHomeScreenShortcut:","vO:O"))
        ((void (*)(id,SEL,id))objc_msgSend)(springBoard,NSSelectorFromString(@"_handleGotoHomeScreenShortcut:"),nil);
}

static NSString *TWUSymbolKey(const char *plain, const char *underscored, NSString *fallback) {
    for (NSUInteger i=0;i<2;++i) {
        void *address=dlsym(RTLD_DEFAULT,i ? underscored : plain);
        if (!address) continue;
        id value=*(__unsafe_unretained id *)address;
        if (TWUStr(value)) return value;
    }
    return fallback;
}
static id TWUSuspendedOptions(id options) {
    NSDictionary *dictionary=TWUDictionary(options);
    if (!dictionary) return nil;
    NSMutableDictionary *updated=[dictionary mutableCopy];
    updated[TWUSymbolKey("FBSOpenApplicationOptionKeyActivateSuspended","_FBSOpenApplicationOptionKeyActivateSuspended",@"FBSOpenApplicationOptionKeyActivateSuspended")]=@YES;
    if ([options isKindOfClass:NSDictionary.class]) return [updated copy];
    if (![options conformsToProtocol:@protocol(NSCopying)]) return nil;
    id copy=[options copy];
    if (copy==options || !TWUHas(copy,@"setDictionary:","vO:O")) return nil;
    ((void (*)(id,SEL,id))objc_msgSend)(copy,NSSelectorFromString(@"setDictionary:"),[updated copy]);
    return copy;
}
// SC 0x49770 coordinator is called only by 0x4ec8c generic workspace request.
// Trusted/untrusted entry points are deliberately not used as alternate routes.
static void (*gRequest)(id,SEL,id,id,id,id,id);
static void TWURequest(id self, SEL cmd, id app, id options, id activation, id origin, id completion) {
    void (^original)(id)=^(id newOptions) { gRequest(self,cmd,app,newOptions,activation,origin,completion); };
    if (gDelivery || gRequestDepth || !TWUAllowed()) { original(options); return; }
    ++gRequestDepth;
    @try {
        NSString *target=TWUStr(app); // exact 0x4fab8: generic target must be NSString
        NSString *source=TWUSource(options,origin);
        if (TWUObserve(source,target)) {
            TWUDeliver(^{ original(options); },NO); return;
        }
        if (!TWUEligible(target)) { original(options); return; }
        NSString *launch=TWUStr(TWUOption(options,@"__LaunchOrigin"));
        BOOL system=TWUOn(@"splitSystemURLRoutingEnabled");
        BOOL spotlight=system && [source isEqual:@"com.apple.Spotlight"] && [launch isEqual:@"SBSLaunchOriginSpotlight"];
        NSString *actionsKey=TWUSymbolKey("FBSOpenApplicationOptionKeyActions","_FBSOpenApplicationOptionKeyActions",@"FBSOpenApplicationOptionKeyActions");
        id actions=TWUOption(options,actionsKey);
        spotlight=spotlight && (!actions || actions==NSNull.null || ([actions respondsToSelector:@selector(count)] && [actions count]==0));
        BOOL url=TWUURL(TWUGet(options,@"url")).length || TWUURL(TWUOption(options,@"__PayloadURL")).length;
        BOOL payload=TWUPayload(options);
        BOOL shortcut=TWUOn(@"splitShortcutFloatingEnabled") && [source isEqual:@"com.apple.WorkflowKit.BackgroundShortcutRunner"] &&
            !url && !payload && TWUOne(options,@"__PromptUnlockDevice") && TWUOne(options,@"__UnlockDevice");
        BOOL fromSpringBoard=[source isEqual:@"com.apple.springboard"];
        BOOL systemRequest=fromSpringBoard && !url && system &&
            ([launch isEqual:@"SBSLaunchOriginShortcutItem"] || TWUOne(options,@"__PromptUnlockDevice"));
        // SC rejects all four notification launch origins and already-suspended
        // requests before source qualification. Unknown sources stay native.
        if (TWUNotification(launch) || TWUSuspended(options) || (!spotlight && !shortcut && !systemRequest)) {
            original(options); return;
        }
        if (systemRequest && ![launch isEqual:@"SBSLaunchOriginShortcutItem"] && !payload && !shortcut) {
            original(options); return;
        }
        id routed=TWUSuspendedOptions(options);
        // Prepare the forwarding object BEFORE opening. A shape we cannot copy
        // losslessly must not leave a new window with an undelivered request.
        BOOL existing=TWUPXBool(@"isInteractiveHostedURLSource:",target);
        if (!routed || !TWUOpen(target)) { original(options); return; }
        if (spotlight || (fromSpringBoard && TWUOne(options,@"__PromptUnlockDevice") && TWUOne(options,@"__UnlockDevice"))) TWUHome();
        // Original 0x4a074 immediate if an existing scene, otherwise 0.5 seconds.
        // PX does not expose a route-success/existing-scene receipt. Use its
        // verified hosted-source predicate; otherwise retain the original delay.
        void (^deliver)(void)=^{
            if (TWUAllowed() && TWUMaster()) TWUDeliver(^{ original(routed); },NO);
            else TWUDeliver(^{ original(options); },NO);
        };
        if (existing) deliver();
        else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),deliver);
    } @finally { --gRequestDepth; }
}

static void (*gCoreURL)(id,SEL,id,id,BOOL,id,id,id);
static void (*gSetBackground)(id,SEL,BOOL), (*gSetAnimation)(id,SEL,BOOL);
static void TWUCoreURL(id self,SEL cmd,id url,id display,BOOL animating,id activation,id origin,id completion) {
    void (^original)(void)=^{ gCoreURL(self,cmd,url,display,animating,activation,origin,completion); };
    if (gDelivery || gRequestDepth || !TWUAllowed() || !TWUURL(url).length) { original(); return; }
    NSString *source=TWUBundle(origin), *target=TWUBundle(display);
    if (TWUObserve(source,target)) { TWUDeliver(original,NO); return; }
    // SC 0x495a8 -> eligibility -> split -> 0.5s -> original under background
    // transition scope. General app URL delivery remains PX-owned. This added
    // core branch requires the exact confirmed SpringBoard source and target.
    if (!gSetBackground || !gSetAnimation || !TWUOn(@"splitSystemURLRoutingEnabled") ||
        ![source isEqual:@"com.apple.springboard"] || !TWUOpen(target)) { original(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        TWUDeliver(original,TWUAllowed() && TWUMaster());
    });
}
static void TWUSetBackground(id self,SEL cmd,BOOL value) { gSetBackground(self,cmd,gBackground ? YES : value); }
static void TWUSetAnimation(id self,SEL cmd,BOOL value) { gSetAnimation(self,cmd,gBackground ? YES : value); }

// The exact PX defaults instance is marked at construction. Both objectForKey:
// and boolForKey: are required: PX tests object presence and otherwise defaults
// to YES (0x7dc8..0x7e08). No global or Settings defaults are changed.
static id (*gDefaultsInit)(id,SEL,id), (*gDefaultsObject)(id,SEL,id);
static BOOL (*gDefaultsBool)(id,SEL,id);
static id TWUDefaultsInit(id self,SEL cmd,id suite) {
    id result=gDefaultsInit(self,cmd,suite);
    if ([suite isEqual:@"com.moxuan.parallelx"] && result) objc_setAssociatedObject(result,&gPXDefaults,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
static BOOL TWUSuppressPXURL(id self,id key) {
    return objc_getAssociatedObject(self,&gPXDefaults) && [key isEqual:@"urlSplitEnabled"] &&
        (gDelivery || !TWUAllowed());
}
static id TWUDefaultsObject(id self,SEL cmd,id key) {
    id value=gDefaultsObject(self,cmd,key);
    return TWUSuppressPXURL(self,key) ? @NO : value;
}
static BOOL TWUDefaultsBool(id self,SEL cmd,id key) {
    BOOL value=gDefaultsBool(self,cmd,key);
    return TWUSuppressPXURL(self,key) ? NO : value;
}
static void (*gReturn)(id,SEL,id,id);
static void TWUReturn(id self,SEL cmd,id source,id window) {
    // PX has an unconditional native return closer; only the SC 120s reversed
    // pair above authorizes it. This also enforces TWEnabled + unlocked state.
    // An absent Twin preference preserves the native engine behavior. When
    // the user explicitly disables callback closing, suppress only that feature
    // while Twin is enabled; the master-off path always preserves originals.
    id configured = [TWPrefs.shared objectForKey:@"splitCallbackAutoCloseFloatingEnabled"];
    if (!TWUAllowed() || !configured || [configured boolValue] || gClosing)
        gReturn(self,cmd,source,window);
}
static BOOL TWUHook(Class cls,NSString *name,IMP replacement,IMP *original,const char *abi) {
    if (*original) return YES;
    SEL selector=NSSelectorFromString(name);
    if (!gHook || !TWUABI(class_getInstanceMethod(cls,selector),abi)) return NO;
    gHook(cls,selector,replacement,original);
    return *original!=NULL;
}
void TWURLRoutingStart(void) {
    gSpringBoard=[NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"];
    if (!gSpringBoard || !NSThread.isMainThread) return;
    gHook=(void (*)(Class,SEL,IMP,IMP *))dlsym(RTLD_DEFAULT,"MSHookMessageEx");
    Class px=NSClassFromString(@"PXPanelEntry");
    if (!gHook || !TWUHas(px,@"applicationActivated:","vO:O")) return;
    // Retry after the vendor image becomes visible. Newly allocated engine
    // defaults are marked here; pre-existing defaults remain native (no global
    // defaults mutation or guessed engine ivar access).
    TWUHook(NSUserDefaults.class,@"initWithSuiteName:",(IMP)TWUDefaultsInit,(IMP *)&gDefaultsInit,"OO:O");
    TWUHook(NSUserDefaults.class,@"objectForKey:",(IMP)TWUDefaultsObject,(IMP *)&gDefaultsObject,"OO:O");
    TWUHook(NSUserDefaults.class,@"boolForKey:",(IMP)TWUDefaultsBool,(IMP *)&gDefaultsBool,"bO:O");
    if (!gDefaultsInit || !gDefaultsObject || !gDefaultsBool) return;
    TWUHook(object_getClass(px),@"completeURLReturnFromSource:window:",(IMP)TWUReturn,(IMP *)&gReturn,"vO:OO");
    TWUHook(NSClassFromString(@"SBMainWorkspace"),@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:",
        (IMP)TWURequest,(IMP *)&gRequest,"vO:OOOOK");
    TWUHook(NSClassFromString(@"SpringBoard"),@"_openURLCore:display:animating:activationSettings:origin:withResult:",
        (IMP)TWUCoreURL,(IMP *)&gCoreURL,"vO:OObOOK");
    Class context=NSClassFromString(@"SBWorkspaceApplicationSceneTransitionContext");
    TWUHook(context,@"setBackground:",(IMP)TWUSetBackground,(IMP *)&gSetBackground,"vO:b");
    TWUHook(context,@"setAnimationDisabled:",(IMP)TWUSetAnimation,(IMP *)&gSetAnimation,"vO:b");
}
