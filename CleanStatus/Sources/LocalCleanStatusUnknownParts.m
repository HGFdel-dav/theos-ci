#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"

// Reimplementation of the three NoPreferencesTips behaviors: hide the
// non-genuine battery health warning, remove unknown-part rows from About,
// and clear the Settings app badge. All hooks fail closed when a class or
// selector is absent and call the original when the toggle is off.

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

static void local_cleanstatus_hook(Class cls, const char *name, const char *type, int count,
                                   const char *args[], IMP replacement, IMP *original) {
    SEL selector = sel_registerName(name);
    if (local_cleanstatus_methodMatches(cls,selector,type,count,args))
        MSHookMessageEx(cls,selector,replacement,original);
}

void local_cleanstatus_installUnknownPartsHooks(void) {
    const char *none[] = {};
    const char *oneObject[] = { @encode(id) };
    Class cls = NSClassFromString(@"PLBatteryUIBackendModel");
    local_cleanstatus_hook(cls,"supportsChargingFixedLimit",@encode(BOOL),0,none,
        (IMP)local_cleanstatus_supportsFixedLimit,(IMP *)&lcsOriginalSupportsFixedLimit);
    local_cleanstatus_hook(cls,"shouldShowChargingController",@encode(BOOL),0,none,
        (IMP)local_cleanstatus_shouldShowCharging,(IMP *)&lcsOriginalShouldShowCharging);

    cls = NSClassFromString(@"PLModelingUtilities");
    local_cleanstatus_hook(cls,"isPhone",@encode(BOOL),0,none,
        (IMP)local_cleanstatus_isPhone,(IMP *)&lcsOriginalIsPhone);

    cls = NSClassFromString(@"BatteryUIResourceClass");
    local_cleanstatus_hook(cls,"getManagementState",@encode(NSInteger),0,none,
        (IMP)local_cleanstatus_managementState,(IMP *)&lcsOriginalManagementState);
    local_cleanstatus_hook(cls,"genuineBatteryStatus",@encode(BOOL),0,none,
        (IMP)local_cleanstatus_genuineBattery,(IMP *)&lcsOriginalGenuineBattery);
    local_cleanstatus_hook(cls,"getBatteryHealthServiceState",@encode(NSInteger),0,none,
        (IMP)local_cleanstatus_healthServiceState,(IMP *)&lcsOriginalHealthServiceState);

    cls = NSClassFromString(@"SystemHealthUI");
    local_cleanstatus_hook(cls,"getCurrentSystemHealthInfoSpecifiers",@encode(id),0,none,
        (IMP)local_cleanstatus_systemHealthSpecifiers,(IMP *)&lcsOriginalSystemHealthSpecifiers);
    local_cleanstatus_hook(cls,"isVaildCAA:",@encode(BOOL),1,oneObject,
        (IMP)local_cleanstatus_validCAA,(IMP *)&lcsOriginalValidCAA);

    cls = NSClassFromString(@"PSGAboutDataSource");
    local_cleanstatus_hook(cls,"nonGenuineComponentSpecifierForComponent:",@encode(id),1,oneObject,
        (IMP)local_cleanstatus_nonGenuineSpecifier,(IMP *)&lcsOriginalNonGenuineSpecifier);

    cls = NSClassFromString(@"SBApplication");
    local_cleanstatus_hook(cls,"badgeValue",@encode(id),0,none,
        (IMP)local_cleanstatus_badgeValue,(IMP *)&lcsOriginalBadgeValue);

    cls = NSClassFromString(@"BSUIBadgeController");
    const char *twoObjects[] = { @encode(id), @encode(id) };
    local_cleanstatus_hook(cls,"updateBadgeValue:forBundleID:",@encode(void),2,twoObjects,
        (IMP)local_cleanstatus_updateBadge,(IMP *)&lcsOriginalUpdateBadge);
}
