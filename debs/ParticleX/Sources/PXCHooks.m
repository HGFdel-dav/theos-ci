#import "PXCSettings.h"
#import "PXCNotifications.h"
#import "PXCAppDeletion.h"
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
extern void PXCAppGroupingInstallHooks(void);

// Header evidence is stored in reference/, all private calls are typed and
// preflighted at runtime. A mismatched/new method is skipped, never guessed.
static const char *PXCType(const char *t) {
    while (t && *t && strchr("rnNoORV",*t)) t++;
    return t;
}
static BOOL PXCMethod(Class cls,SEL sel,const char *result,const char *args) {
    Method m=class_getInstanceMethod(cls,sel);
    if (!m || method_getNumberOfArguments(m)!=strlen(args)+2) return NO;
    char t[128]={0};method_getReturnType(m,t,sizeof(t));
    if (!*PXCType(t) || !strchr(result,*PXCType(t))) return NO;
    for (unsigned i=0;i<strlen(args);i++) {
        method_getArgumentType(m,i+2,t,sizeof(t));
        const char *a=PXCType(t);
        if (args[i]=='b') { if (*a!='B' && *a!='c') return NO; }
        else if (args[i]=='k') { if (a[0]!='@' || a[1]!='?') return NO; }
        else if (*a!=args[i]) return NO;
    }
    return YES;
}
static id PXCObject(id object,NSString *name) {
    SEL s=NSSelectorFromString(name);
    if (!object || !PXCMethod(object_getClass(object),s,"@","")) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,s);
}
static BOOL PXCBool(id object,NSString *name) {
    SEL s=NSSelectorFromString(name);
    if (!object || !PXCMethod(object_getClass(object),s,"Bc","")) return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(object,s);
}
static BOOL PXCReady(BOOL widget) {
    if (!NSThread.isMainThread || UIAccessibilityIsReduceMotionEnabled()) return NO;
    PXCSettings s=PXCSettingsGet();return s.enabled && (widget ? s.widgets : s.notifications);
}
static BOOL PXCVisible(UIView *v) {
    if (!v.window || v.hidden || v.alpha<0.05 || v.window.hidden) return NO;
    for (UIView *p=v.superview;p;p=p.superview) if (p.hidden || p.alpha<0.05) return NO;
    CGRect r=[v convertRect:v.bounds toView:v.window];
    return !CGRectIsEmpty(CGRectIntersection(r,v.window.bounds));
}
static void PXCSnapshot(UIView *v) {
    if (![v isKindOfClass:UIView.class] || !PXCVisible(v)) return;
    // Deduplicate nested cell/controller clear routes in a single user action.
    static const void *key=&key;
    NSNumber *last=objc_getAssociatedObject(v,key);
    double now=CACurrentMediaTime();
    if (last && now-last.doubleValue<0.35) return;
    @try {
        if (PXCDisintegrateViewDirection(v,PXCSettingsGet().widgetDirection)) objc_setAssociatedObject(v,key,@(now),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) { PXCLog([@"snapshot failed safely: " stringByAppendingString:e.name]); }
}
static NSArray *PXCArray(id objects) {
    if ([objects isKindOfClass:NSArray.class]) return objects;
    if ([objects isKindOfClass:NSSet.class]) return [objects allObjects];
    if ([objects isKindOfClass:NSOrderedSet.class]) return [objects array];
    return @[];
}
static void (*PXCOrigCellClear)(id,SEL);
static void PXCCellClear(id self,SEL cmd) {
    PXCNotificationCaptureCell(self,@"cell-clear");
    PXCOrigCellClear(self,cmd);
}
static void (*PXCOrigRequests)(id,SEL,id,id);
static void PXCRequests(id self,SEL cmd,id component,id requests) {
    PXCNotificationCapture(self,requests,nil,NO,@"controller-requests");
    PXCOrigRequests(self,cmd,component,requests);
}
static void (*PXCOrigSections)(id,SEL,id,id);
static void PXCSections(id self,SEL cmd,id component,id sections) {
    PXCNotificationCapture(self,nil,sections,NO,@"controller-sections");
    PXCOrigSections(self,cmd,component,sections);
}
static void (*PXCOrigAll)(id,SEL,id);
static void PXCAll(id self,SEL cmd,id component) {
    PXCNotificationCapture(self,nil,nil,YES,@"controller-all");
    PXCOrigAll(self,cmd,component);
}
static void (*PXCOrigWidgetRemove)(id,SEL,id,unsigned long long,id);
static void PXCWidgetRemove(id self,SEL cmd,id icon,unsigned long long options,id completion) {
    if (PXCReady(YES) && (PXCBool(icon,@"isWidgetIcon") || PXCBool(icon,@"isWidgetStackIcon"))) {
        // Search already-mounted icon views by identity, not iconViewForIcon:
        // which can allocate/relocate views. No arbitrary window snapshots.
        Class iconView=NSClassFromString(@"SBIconView");
        NSMutableOrderedSet<UIWindow *> *windows=[NSMutableOrderedSet orderedSet];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        // SpringBoard can own legacy windows outside UIWindowScene on 15.5.
        // Public object getter is ABI-checked and used only as a fallback.
        if (!windows.count) [windows addObjectsFromArray:PXCArray(PXCObject(UIApplication.sharedApplication,@"windows"))];
        for (UIWindow *window in windows) {
            if (window.hidden || window.alpha<0.05) continue;
            NSMutableArray *queue=[NSMutableArray arrayWithObject:window];
            for (NSUInteger i=0;i<queue.count && i<2400;i++) {
                UIView *v=queue[i];
                if (iconView && [v isKindOfClass:iconView] && PXCObject(v,@"icon")==icon) { PXCSnapshot(v);break; }
                if (queue.count<2400) [queue addObjectsFromArray:v.subviews];
            }
        }
    }
    // Exact block passed through untouched, no casting/invoking of its unknown ABI.
    PXCOrigWidgetRemove(self,cmd,icon,options,completion);
}
static void (*PXCOrigSliderGesture)(id,SEL,id);
static void PXCSliderGesture(id self,SEL cmd,id gesture) {
    PXCOrigSliderGesture(self,cmd,gesture);
    if (!NSThread.isMainThread || ![self isKindOfClass:UIView.class] || ![gesture isKindOfClass:UIGestureRecognizer.class]) return;
    UIGestureRecognizerState state=[(UIGestureRecognizer *)gesture state];
    if (object_getClass(self)==NSClassFromString(@"CCUIContinuousSliderView"))
        PXCSliderSetTracking(self,state==UIGestureRecognizerStateBegan || state==UIGestureRecognizerStateChanged);
    if (state==UIGestureRecognizerStateCancelled || state==UIGestureRecognizerStateFailed) { PXCSliderStop(self);return; }
    SEL value=@selector(value);
    if ((state==UIGestureRecognizerStateBegan || state==UIGestureRecognizerStateChanged || state==UIGestureRecognizerStateEnded)
        && PXCMethod(object_getClass(self),value,"f","")) {
        float v=((float(*)(id,SEL))objc_msgSend)(self,value);
        PXCSliderObserve(self,v);
    }
}
static void PXCBrightnessRead(id slider) {
    if (!NSThread.isMainThread || object_getClass(slider)!=NSClassFromString(@"CCUIContinuousSliderView")) return;
    SEL sel=@selector(value);
    if (PXCMethod(object_getClass(slider),sel,"f","")) PXCSliderObserve(slider,((float(*)(id,SEL))objc_msgSend)(slider,sel));
}
static void (*PXCOrigSliderBegin)(id,SEL,id);
static void PXCSliderBegin(id self,SEL cmd,id gesture) {
    PXCOrigSliderBegin(self,cmd,gesture);
    PXCSliderSetTracking(self,YES);PXCBrightnessRead(self);
}
static void (*PXCOrigSliderContinue)(id,SEL,id);
static void PXCSliderContinue(id self,SEL cmd,id gesture) {
    PXCOrigSliderContinue(self,cmd,gesture);
    PXCSliderSetTracking(self,YES);PXCBrightnessRead(self);
}
static void (*PXCOrigSliderEnd)(id,SEL,id);
static void PXCSliderEnd(id self,SEL cmd,id gesture) {
    PXCOrigSliderEnd(self,cmd,gesture);
    PXCSliderSetTracking(self,NO);PXCBrightnessRead(self);
}
static void (*PXCOrigSliderSetValue)(id,SEL,float);
static void PXCSliderSetValue(id self,SEL cmd,float value) {
    PXCOrigSliderSetValue(self,cmd,value);
    if (NSThread.isMainThread && PXCSliderIsTracking(self)) PXCBrightnessRead(self);
}
static void (*PXCOrigSliderLayout)(id,SEL);
static void PXCSliderLayoutHook(id self,SEL cmd) {
    PXCOrigSliderLayout(self,cmd);
    PXCSliderLayout(self);
}
static BOOL PXCHook(const char *name,const char *selector,const char *result,const char *args,IMP hook,IMP *original) {
    if (*original) return YES;
    Class cls=objc_getClass(name);SEL sel=sel_registerName(selector);
    if (!cls) return NO;
    if (!PXCMethod(cls,sel,result,args)) {
        static NSMutableSet *reported;
        if (!reported) reported=[NSMutableSet set];
        NSString *key=[NSString stringWithFormat:@"%s %s",name,selector];
        if (![reported containsObject:key]) { [reported addObject:key];PXCLog([@"ABI skipped " stringByAppendingString:key]); }
        return NO;
    }
    MSHookMessageEx(cls,sel,hook,original);
    PXCLog([NSString stringWithFormat:@"hook installed %s %s",name,selector]);
    return *original!=NULL;
}
void PXCInstallHooks(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCInstallHooks(); });return; }
    PXCNotificationInstallHooks();
    PXCAppGroupingInstallHooks();
    PXCAppDeletionInstallHooks();
    PXCHook("NCNotificationListCell","_executeClearAction","v","",(IMP)PXCCellClear,(IMP *)&PXCOrigCellClear);
    PXCHook("NCNotificationStructuredListViewController","notificationListComponent:requestsClearingNotificationRequests:","v","@@",(IMP)PXCRequests,(IMP *)&PXCOrigRequests);
    PXCHook("NCNotificationStructuredListViewController","notificationListComponent:requestsClearingNotificationRequestsInSections:","v","@@",(IMP)PXCSections,(IMP *)&PXCOrigSections);
    PXCHook("NCNotificationStructuredListViewController","notificationListComponentRequestsClearingAllNotificationRequests:","v","@",(IMP)PXCAll,(IMP *)&PXCOrigAll);
    PXCHook("SBHIconManager","removeIcon:options:completion:","v","@Qk",(IMP)PXCWidgetRemove,(IMP *)&PXCOrigWidgetRemove);
    PXCHook("CCUIContinuousSliderView","_handleValueChangeGestureRecognizer:","v","@",(IMP)PXCSliderGesture,(IMP *)&PXCOrigSliderGesture);
    PXCHook("CCUIContinuousSliderView","_beginTrackingWithGestureRecognizer:","v","@",(IMP)PXCSliderBegin,(IMP *)&PXCOrigSliderBegin);
    PXCHook("CCUIContinuousSliderView","_continueTrackingWithGestureRecognizer:","v","@",(IMP)PXCSliderContinue,(IMP *)&PXCOrigSliderContinue);
    PXCHook("CCUIContinuousSliderView","_endTrackingWithGestureRecognizer:","v","@",(IMP)PXCSliderEnd,(IMP *)&PXCOrigSliderEnd);
    PXCHook("CCUIBaseSliderView","setValue:","v","f",(IMP)PXCSliderSetValue,(IMP *)&PXCOrigSliderSetValue);
    PXCHook("CCUIContinuousSliderView","layoutSubviews","v","",(IMP)PXCSliderLayoutHook,(IMP *)&PXCOrigSliderLayout);
}
static atomic_bool PXCInstallPending;
static void PXCImageAdded(const struct mach_header *header,intptr_t slide) {
    if (atomic_exchange(&PXCInstallPending,true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&PXCInstallPending,false);
        PXCInstallHooks();
    });
}
__attribute__((constructor)) static void PXCEntry(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        PXCSettingsStart();
        PXCLog(@"ParticleX 0.1.0dev4 loaded; no notification data persisted");
        PXCInstallHooks();
        _dyld_register_func_for_add_image(PXCImageAdded);
    });
}
