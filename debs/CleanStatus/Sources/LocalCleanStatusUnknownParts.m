#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"

// Reimplementation of the three NoPreferencesTips behaviors: hide the
// non-genuine battery health warning, remove unknown-part rows from About,
// and clear the Settings app badge. Hooks are installed loosely (instance or
// class method, no strict encoding gate) because system encodings vary; every
// attempt is logged so the result can be confirmed on device. When the toggle
// is off every hook forwards to the original implementation.

static BOOL local_cleanstatus_unknownParts(void) {
    return local_cleanstatus_hasFeature(local_cleanstatus_currentFlags(), LocalCleanStatusUnknownParts);
}

static NSInteger (*lcsOriginalManagementState)(id,SEL);
static BOOL (*lcsOriginalGenuineBattery)(id,SEL);
static NSInteger (*lcsOriginalHealthServiceState)(id,SEL);
static BOOL (*lcsOriginalSupportsFixedLimit)(id,SEL);
static BOOL (*lcsOriginalShouldShowCharging)(id,SEL);
static BOOL (*lcsOriginalIsPhone)(id,SEL);

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

static id (*lcsOriginalSystemHealthSpecifiers)(id,SEL);
static BOOL (*lcsOriginalValidCAA)(id,SEL,id);
static id (*lcsOriginalNonGenuineSpecifier)(id,SEL,id);
static id (*lcsOriginalBadgeValue)(id,SEL);
static void (*lcsOriginalUpdateBadge)(id,SEL,id,id);

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

// /var/mobile/Library/Caches is readable from the device and never part of the
// tweak's preference storage. One line per hook attempt keeps the diagnosis
// possible without a debugger.
static void local_cleanstatus_logLine(NSString *line) {
    static NSString * const path = @"/var/mobile/Library/Caches/local-cleanstatus-hooks.log";
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once,^{ formatter=[[NSDateFormatter alloc] init];
        formatter.dateFormat=@"HH:mm:ss"; });
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

static void local_cleanstatus_logHook(NSString *cls, NSString *selector, Method method,
                                      BOOL hooked, NSString *note) {
    NSString *type = @"-";
    if (method) {
        char *value = method_copyReturnType(method);
        type = value ? [NSString stringWithUTF8String:value] : @"?";
        if (value) free(value);
    }
    local_cleanstatus_logLine([NSString stringWithFormat:@"%@ %@ ret=%@ %@ %@",
        cls, selector, type, hooked ? @"HOOKED" : @"skipped", note ?: @""]);
}

#pragma mark - loose hooking

static BOOL local_cleanstatus_hookLoose(Class cls, const char *name, IMP replacement,
                                        IMP *original, NSString *note) {
    NSString *className = cls ? NSStringFromClass(cls) : [NSString stringWithUTF8String:name];
    if (!cls) {
        local_cleanstatus_logHook(className, [NSString stringWithUTF8String:name], NULL, NO, @"class missing");
        return NO;
    }
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(cls,selector);
    if (method) {
        MSHookMessageEx(cls, selector, replacement, original);
        local_cleanstatus_logHook(className, [NSString stringWithUTF8String:name], method, YES, note);
        return YES;
    }
    Class meta = object_getClass(cls);
    method = class_getClassMethod(cls,selector);
    if (method) {
        MSHookMessageEx(meta, selector, replacement, original);
        local_cleanstatus_logHook([@"+" stringByAppendingString:className],
            [NSString stringWithUTF8String:name], method, YES, note);
        return YES;
    }
    local_cleanstatus_logHook(className, [NSString stringWithUTF8String:name], NULL, NO, @"selector missing");
    return NO;
}

void local_cleanstatus_installUnknownPartsHooks(void) {
    local_cleanstatus_logLine([NSString stringWithFormat:@"install begin enabled=%d bundle=%@",
        local_cleanstatus_unknownParts(), NSBundle.mainBundle.bundleIdentifier ?: @"?"]);

    local_cleanstatus_hookLoose(NSClassFromString(@"PLBatteryUIBackendModel"),
        "supportsChargingFixedLimit",(IMP)local_cleanstatus_supportsFixedLimit,
        (IMP *)&lcsOriginalSupportsFixedLimit,@"battery backend");
    local_cleanstatus_hookLoose(NSClassFromString(@"PLBatteryUIBackendModel"),
        "shouldShowChargingController",(IMP)local_cleanstatus_shouldShowCharging,
        (IMP *)&lcsOriginalShouldShowCharging,@"battery backend");

    local_cleanstatus_hookLoose(NSClassFromString(@"PLModelingUtilities"),
        "isPhone",(IMP)local_cleanstatus_isPhone,(IMP *)&lcsOriginalIsPhone,@"modeling");

    Class resource = NSClassFromString(@"BatteryUIResourceClass");
    local_cleanstatus_hookLoose(resource,"getManagementState",(IMP)local_cleanstatus_managementState,
        (IMP *)&lcsOriginalManagementState,@"battery resource");
    local_cleanstatus_hookLoose(resource,"genuineBatteryStatus",(IMP)local_cleanstatus_genuineBattery,
        (IMP *)&lcsOriginalGenuineBattery,@"battery resource");
    local_cleanstatus_hookLoose(resource,"getBatteryHealthServiceState",
        (IMP)local_cleanstatus_healthServiceState,(IMP *)&lcsOriginalHealthServiceState,@"battery resource");

    Class health = NSClassFromString(@"SystemHealthUI");
    local_cleanstatus_hookLoose(health,"getCurrentSystemHealthInfoSpecifiers",
        (IMP)local_cleanstatus_systemHealthSpecifiers,(IMP *)&lcsOriginalSystemHealthSpecifiers,@"system health");
    local_cleanstatus_hookLoose(health,"isVaildCAA:",(IMP)local_cleanstatus_validCAA,
        (IMP *)&lcsOriginalValidCAA,@"system health");

    local_cleanstatus_hookLoose(NSClassFromString(@"PSGAboutDataSource"),
        "nonGenuineComponentSpecifierForComponent:",(IMP)local_cleanstatus_nonGenuineSpecifier,
        (IMP *)&lcsOriginalNonGenuineSpecifier,@"about page");

    local_cleanstatus_hookLoose(NSClassFromString(@"SBApplication"),"badgeValue",
        (IMP)local_cleanstatus_badgeValue,(IMP *)&lcsOriginalBadgeValue,@"badge");
    local_cleanstatus_hookLoose(NSClassFromString(@"BSUIBadgeController"),
        "updateBadgeValue:forBundleID:",(IMP)local_cleanstatus_updateBadge,
        (IMP *)&lcsOriginalUpdateBadge,@"badge");

    local_cleanstatus_logLine(@"install end");
}
