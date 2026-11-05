#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"

// Reimplementation of the three NoPreferencesTips behaviors.
//
// The battery/about classes live in lazily loaded preference bundles, so
// hooking them from the constructor is too early. The original tweak waits for
// NSBundleDidLoadNotification and then hooks. We do the same, plus a short
// retry schedule and an app-active retry, and log every attempt so the result
// can be confirmed on device.

static BOOL local_cleanstatus_unknownParts(void) {
    return local_cleanstatus_hasFeature(local_cleanstatus_currentFlags(), LocalCleanStatusUnknownParts);
}

static NSInteger (*lcsOriginalManagementState)(id,SEL);
static BOOL (*lcsOriginalGenuineBattery)(id,SEL);
static NSInteger (*lcsOriginalHealthServiceState)(id,SEL);
static BOOL (*lcsOriginalSupportsFixedLimit)(id,SEL);
static BOOL (*lcsOriginalShouldShowCharging)(id,SEL);
static BOOL (*lcsOriginalIsPhone)(id,SEL);
static id (*lcsOriginalSystemHealthSpecifiers)(id,SEL);
static BOOL (*lcsOriginalValidCAA)(id,SEL,id);
static id (*lcsOriginalNonGenuineSpecifier)(id,SEL,id);
static id (*lcsOriginalBadgeValue)(id,SEL);
static void (*lcsOriginalUpdateBadge)(id,SEL,id,id);

static NSInteger local_cleanstatus_managementState(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? 2 : lcsOriginalManagementState(self,command);
}
static BOOL local_cleanstatus_genuineBattery(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? YES : lcsOriginalGenuineBattery(self,command);
}
static NSInteger local_cleanstatus_healthServiceState(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? 0 : lcsOriginalHealthServiceState(self,command);
}
static BOOL local_cleanstatus_supportsFixedLimit(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? NO : lcsOriginalSupportsFixedLimit(self,command);
}
static BOOL local_cleanstatus_shouldShowCharging(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? YES : lcsOriginalShouldShowCharging(self,command);
}
static BOOL local_cleanstatus_isPhone(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? YES : lcsOriginalIsPhone(self,command);
}
static id local_cleanstatus_systemHealthSpecifiers(id self, SEL command) {
    return local_cleanstatus_unknownParts() ? nil : lcsOriginalSystemHealthSpecifiers(self,command);
}
static BOOL local_cleanstatus_validCAA(id self, SEL command, id value) {
    return local_cleanstatus_unknownParts() ? YES : lcsOriginalValidCAA(self,command,value);
}
static id local_cleanstatus_nonGenuineSpecifier(id self, SEL command, id component) {
    return local_cleanstatus_unknownParts() ? nil : lcsOriginalNonGenuineSpecifier(self,command,component);
}
static BOOL local_cleanstatus_settingsBundle(id self) {
    id bundle = local_cleanstatus_object(self,"bundleIdentifier");
    return [bundle isKindOfClass:NSString.class] && [bundle isEqualToString:@"com.apple.Preferences"];
}
static id local_cleanstatus_badgeValue(id self, SEL command) {
    if (local_cleanstatus_unknownParts() && local_cleanstatus_settingsBundle(self)) return @0;
    return lcsOriginalBadgeValue(self,command);
}
static void local_cleanstatus_updateBadge(id self, SEL command, id value, id bundleID) {
    if (local_cleanstatus_unknownParts() && [bundleID isKindOfClass:NSString.class] &&
        [bundleID isEqualToString:@"com.apple.Preferences"]) value = nil;
    lcsOriginalUpdateBadge(self,command,value,bundleID);
}

#pragma mark - diagnostics

static void local_cleanstatus_logLine(NSString *line) {
    static NSString * const path = @"/var/mobile/Library/Caches/local-cleanstatus-hooks.log";
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once,^{ formatter=[[NSDateFormatter alloc] init]; formatter.dateFormat=@"HH:mm:ss"; });
    NSString *row = [NSString stringWithFormat:@"%@ %@\n",[formatter stringFromDate:NSDate.date],line];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - loose hooking

static BOOL lcsDone[11];
static id lcsBundleObserver, lcsActiveObserver;
static int lcsAttempts;
static BOOL lcsReached12;

static BOOL local_cleanstatus_hookOnce(int slot, Class cls, const char *name, IMP replacement,
                                       IMP *original, NSString *note) {
    if (lcsDone[slot]) return YES;
    NSString *selectorName = [NSString stringWithUTF8String:name];
    if (!cls) {
        if (lcsAttempts <= 1)
            local_cleanstatus_logLine([NSString stringWithFormat:@"%@ class not loaded yet",selectorName]);
        return NO;
    }
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls,selector);
    Class target = cls;
    if (!method) {
        method = class_getClassMethod(cls,selector);
        target = object_getClass(cls);
    }
    if (!method) {
        local_cleanstatus_logLine([NSString stringWithFormat:@"%@ %@ selector missing",
            NSStringFromClass(cls),selectorName]);
        return NO;
    }
    MSHookMessageEx(target, selector, replacement, original);
    lcsDone[slot] = YES;
    local_cleanstatus_logLine([NSString stringWithFormat:@"%@ %@ HOOKED %@",
        NSStringFromClass(cls),selectorName,note ?: @""]);
    return YES;
}

static void local_cleanstatus_installUnknownPartsNow(void) {
    lcsAttempts++;
    local_cleanstatus_hookOnce(0,NSClassFromString(@"PLBatteryUIBackendModel"),
        "supportsChargingFixedLimit",(IMP)local_cleanstatus_supportsFixedLimit,
        (IMP *)&lcsOriginalSupportsFixedLimit,@"battery backend");
    local_cleanstatus_hookOnce(1,NSClassFromString(@"PLBatteryUIBackendModel"),
        "shouldShowChargingController",(IMP)local_cleanstatus_shouldShowCharging,
        (IMP *)&lcsOriginalShouldShowCharging,@"battery backend");
    local_cleanstatus_hookOnce(2,NSClassFromString(@"PLModelingUtilities"),
        "isPhone",(IMP)local_cleanstatus_isPhone,(IMP *)&lcsOriginalIsPhone,@"modeling");
    Class resource = NSClassFromString(@"BatteryUIResourceClass");
    local_cleanstatus_hookOnce(3,resource,"getManagementState",(IMP)local_cleanstatus_managementState,
        (IMP *)&lcsOriginalManagementState,@"battery resource");
    local_cleanstatus_hookOnce(4,resource,"genuineBatteryStatus",(IMP)local_cleanstatus_genuineBattery,
        (IMP *)&lcsOriginalGenuineBattery,@"battery resource");
    local_cleanstatus_hookOnce(5,resource,"getBatteryHealthServiceState",
        (IMP)local_cleanstatus_healthServiceState,(IMP *)&lcsOriginalHealthServiceState,@"battery resource");
    Class health = NSClassFromString(@"SystemHealthUI");
    local_cleanstatus_hookOnce(6,health,"getCurrentSystemHealthInfoSpecifiers",
        (IMP)local_cleanstatus_systemHealthSpecifiers,(IMP *)&lcsOriginalSystemHealthSpecifiers,@"system health");
    local_cleanstatus_hookOnce(7,health,"isVaildCAA:",(IMP)local_cleanstatus_validCAA,
        (IMP *)&lcsOriginalValidCAA,@"system health");
    local_cleanstatus_hookOnce(8,NSClassFromString(@"PSGAboutDataSource"),
        "nonGenuineComponentSpecifierForComponent:",(IMP)local_cleanstatus_nonGenuineSpecifier,
        (IMP *)&lcsOriginalNonGenuineSpecifier,@"about page");
    local_cleanstatus_hookOnce(9,NSClassFromString(@"SBApplication"),"badgeValue",
        (IMP)local_cleanstatus_badgeValue,(IMP *)&lcsOriginalBadgeValue,@"badge");
    local_cleanstatus_hookOnce(10,NSClassFromString(@"BSUIBadgeController"),
        "updateBadgeValue:forBundleID:",(IMP)local_cleanstatus_updateBadge,
        (IMP *)&lcsOriginalUpdateBadge,@"badge");

    int hooked = 0; for (int i=0;i<11;i++) if (lcsDone[i]) hooked++;
    if (hooked == 11 || lcsAttempts == 6 || lcsAttempts == 12) {
        if (hooked == 11 && !lcsReached12) { lcsReached12 = YES; }
        local_cleanstatus_logLine([NSString stringWithFormat:@"install attempt %d hooked %d/11",lcsAttempts,hooked]);
    }
}

void local_cleanstatus_installUnknownPartsHooks(void) {
    if (lcsAttempts == 0) {
        local_cleanstatus_logLine([NSString stringWithFormat:@"install begin enabled=%d bundle=%@",
            local_cleanstatus_unknownParts(), NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
        // The battery and About bundles are loaded on demand; the original
        // tweak hooks after NSBundleDidLoadNotification, so do the same.
        lcsBundleObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:@"NSBundleDidLoadNotification" object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                NSBundle *bundle = [notification.object isKindOfClass:NSBundle.class] ? notification.object : nil;
                NSString *path = bundle.bundlePath ?: @"";
                if ([path containsString:@"BatteryUsageUI"] || [path containsString:@"BatteryUI"] ||
                    [path containsString:@"About"])
                    local_cleanstatus_installUnknownPartsNow();
            }];
        lcsActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                local_cleanstatus_installUnknownPartsNow();
            }];
        for (NSNumber *delay in @[@0.5,@2,@5,@10,@20,@40]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{ local_cleanstatus_installUnknownPartsNow(); });
        }
    }
    local_cleanstatus_installUnknownPartsNow();
}