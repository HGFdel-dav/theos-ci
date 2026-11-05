#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"

typedef struct { const char *getter; const char *setter; LocalCleanStatusFeature feature; } LCSEntryMap;
static const LCSEntryMap lcsEntries[] = {
    {"airplaneModeEntry", "setAirplaneModeEntry:", LocalCleanStatusAirplane},
    {"alarmEntry", "setAlarmEntry:", LocalCleanStatusAlarm},
    {"bluetoothEntry", "setBluetoothEntry:", LocalCleanStatusBluetooth},
    {"assistantEntry", "setAssistantEntry:", LocalCleanStatusSiri},
    {"carPlayEntry", "setCarPlayEntry:", LocalCleanStatusCarPlay},
    {"quietModeEntry", "setQuietModeEntry:", LocalCleanStatusFocus},
    {"locationEntry", "setLocationEntry:", LocalCleanStatusLocation},
    {"rotationLockEntry", "setRotationLockEntry:", LocalCleanStatusRotationLock},
    {"cellularEntry", "setCellularEntry:", LocalCleanStatusCellular},
    {"secondaryCellularEntry", "setSecondaryCellularEntry:", LocalCleanStatusCellular},
    {"vpnEntry", "setVpnEntry:", LocalCleanStatusVPN},
    {"wifiEntry", "setWifiEntry:", LocalCleanStatusWiFi}
};
static char lcsNativeDataKey;
static NSHashTable<UIView *> *lcsStatusBars;
static void (*lcsOriginalUpdate)(id,SEL,id,BOOL);

static id local_cleanstatus_dataForDisplay(id source, uint32_t flags) {
    if (!source || !(flags & ((1u << 11)-1)) || ![source conformsToProtocol:@protocol(NSCopying)]) return source;
    id display = [source copy];
    if (!display || display == source) return source;
    const char *objectArg[] = { @encode(id) };
    const char *boolArg[] = { @encode(BOOL) };
    for (unsigned i=0; i < sizeof(lcsEntries)/sizeof(lcsEntries[0]); i++) {
        LCSEntryMap map = lcsEntries[i];
        if (!local_cleanstatus_hasFeature(flags,map.feature)) continue;
        SEL setter = sel_registerName(map.setter);
        if (!local_cleanstatus_methodMatches(object_getClass(display),setter,@encode(void),1,objectArg)) continue;
        id entry = local_cleanstatus_object(source,map.getter);
        if (![entry conformsToProtocol:@protocol(NSCopying)]) continue;
        id filtered = [entry copy];
        SEL setEnabled = sel_registerName("setEnabled:");
        if (!filtered || filtered == entry ||
            !local_cleanstatus_methodMatches(object_getClass(filtered),setEnabled,@encode(void),1,boolArg)) continue;
        ((void(*)(id,SEL,BOOL))objc_msgSend)(filtered,setEnabled,NO);
        ((void(*)(id,SEL,id))objc_msgSend)(display,setter,filtered);
    }
    return display;
}

static void local_cleanstatus_update(id self, SEL command, id data, BOOL force) {
    if (!NSThread.isMainThread) {
        // Do not introduce UIKit work off-main. Preserve the original call unchanged.
        lcsOriginalUpdate(self,command,data,force); return;
    }
    [lcsStatusBars addObject:self];
    if (data && [data conformsToProtocol:@protocol(NSCopying)]) {
        objc_setAssociatedObject(self,&lcsNativeDataKey,[data copy],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    lcsOriginalUpdate(self,command,local_cleanstatus_dataForDisplay(data,local_cleanstatus_currentFlags()),force);
}

static char lcsFirstRefreshKey;
static void (*lcsOriginalStatusLayout)(id,SEL);
static void local_cleanstatus_statusLayout(UIView *self,SEL command) {
    lcsOriginalStatusLayout(self,command);
    if (!NSThread.isMainThread || objc_getAssociatedObject(self,&lcsFirstRefreshKey)) return;
    objc_setAssociatedObject(self,&lcsFirstRefreshKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [lcsStatusBars addObject:self];
    __weak UIView *weakView=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view=weakView;
        SEL selector=sel_registerName("forceUpdateData:");
        const char *args[]={@encode(BOOL)};
        if (view && local_cleanstatus_methodMatches(object_getClass(view),selector,@encode(void),1,args))
            ((void(*)(id,SEL,BOOL))objc_msgSend)(view,selector,YES);
    });
}

void local_cleanstatus_installStatusHooks(void) {
    Class cls = NSClassFromString(@"UIStatusBar_Modern");
    SEL selector = sel_registerName("_updateWithData:force:");
    const char *args[] = { @encode(id), @encode(BOOL) };
    if (!local_cleanstatus_methodMatches(cls,selector,@encode(void),2,args)) return;
    lcsStatusBars = [NSHashTable weakObjectsHashTable];
    MSHookMessageEx(cls,selector,(IMP)local_cleanstatus_update,(IMP *)&lcsOriginalUpdate);
    if (local_cleanstatus_methodMatches(cls,@selector(layoutSubviews),@encode(void),0,NULL))
        MSHookMessageEx(cls,@selector(layoutSubviews),(IMP)local_cleanstatus_statusLayout,(IMP *)&lcsOriginalStatusLayout);
}
void local_cleanstatus_refreshStatusBars(void) {
    if (!NSThread.isMainThread || !lcsOriginalUpdate) return;
    for (UIView *view in lcsStatusBars.allObjects) {
        id native = objc_getAssociatedObject(view,&lcsNativeDataKey);
        if (native) lcsOriginalUpdate(view,sel_registerName("_updateWithData:force:"),
            local_cleanstatus_dataForDisplay(native,local_cleanstatus_currentFlags()),YES);
        [view setNeedsLayout];
    }
}
