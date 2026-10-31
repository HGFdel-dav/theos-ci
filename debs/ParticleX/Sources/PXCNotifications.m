#import "PXCSettings.h"
#import "PXCNotifications.h"
#import "PXCClearAppearance.h"
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import <math.h>

static NSHashTable<UIViewController *> *PXCNotificationControllers;
static double PXCNotificationBatchUntil;
static const void *PXCCellStamp=&PXCCellStamp;
static const void *PXCButtonKey=&PXCButtonKey;
static const void *PXCButtonActiveKey=&PXCButtonActiveKey;
static const void *PXCSessionKey=&PXCSessionKey;

static const char *PXCNType(const char *t) { while (t && *t && strchr("rnNoORV",*t)) t++;return t; }
static BOOL PXCNMethod(id object,SEL sel,const char *ret,const char *args) {
    Method m=object ? class_getInstanceMethod(object_getClass(object),sel) : NULL;
    if (!m || method_getNumberOfArguments(m)!=strlen(args)+2) return NO;
    char t[128];method_getReturnType(m,t,sizeof(t));if (!*PXCNType(t) || !strchr(ret,*PXCNType(t))) return NO;
    for (unsigned i=0;i<strlen(args);i++) {
        method_getArgumentType(m,i+2,t,sizeof(t));const char *a=PXCNType(t);
        if (args[i]=='k') { if (a[0]!='@' || a[1]!='?') return NO; }
        else if (args[i]=='b') { if (*a!='B' && *a!='c') return NO; }
        else if (*a!=args[i]) return NO;
    }
    return YES;
}
static id PXCNObject(id object,NSString *name) {
    SEL s=NSSelectorFromString(name);if (!PXCNMethod(object,s,"@","")) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(object,s);
}
static NSArray *PXCNArray(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    if ([value isKindOfClass:NSOrderedSet.class]) return [value array];
    return @[];
}
static BOOL PXCNEnabled(void) {
    PXCSettings s=PXCSettingsGet();return NSThread.isMainThread && s.enabled && s.notifications && !UIAccessibilityIsReduceMotionEnabled();
}
static BOOL PXCNVisible(UIView *v) {
    if (![v isKindOfClass:UIView.class] || !v.window || v.window.hidden) return NO;
    for (UIView *p=v;p;p=p.superview) if (p.hidden || p.alpha<0.02) return NO;
    CGRect r=[v convertRect:v.bounds toView:v.window];
    if (!isfinite(r.origin.x) || !isfinite(r.origin.y) || !isfinite(r.size.width) || !isfinite(r.size.height)) return NO;
    return !CGRectIsEmpty(CGRectIntersection(r,v.window.bounds));
}
static NSArray<UIWindow *> *PXCNWindows(void) {
    NSMutableOrderedSet *w=[NSMutableOrderedSet orderedSet];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) [w addObjectsFromArray:((UIWindowScene *)scene).windows];
    // SpringBoard owns legacy windows that may be absent from UIWindowScene.
    [w addObjectsFromArray:PXCNArray(PXCNObject(UIApplication.sharedApplication,@"windows"))];
    return w.array;
}
static NSArray<UIView *> *PXCNCellsInRoots(NSArray<UIView *> *roots) {
    Class cellClass=NSClassFromString(@"NCNotificationListCell");
    if (!cellClass) return @[];
    NSMutableArray *queue=[roots mutableCopy],*cells=[NSMutableArray array];
    NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (NSUInteger i=0;i<queue.count && i<5000;i++) {
        UIView *v=queue[i];if (![v isKindOfClass:UIView.class] || [seen containsObject:v]) continue;[seen addObject:v];
        if ([v isKindOfClass:cellClass]) { if (PXCNVisible(v)) [cells addObject:v];continue; }
        if (queue.count<5000) [queue addObjectsFromArray:v.subviews];
        // NCNotificationListView virtualizes entries; include its authoritative
        // visible cache without creating offscreen cells.
        id visible=PXCNObject(v,@"visibleViews");
        if ([visible isKindOfClass:NSDictionary.class] && queue.count<5000) [queue addObjectsFromArray:[visible allValues]];
    }
    return cells;
}
static NSArray<UIView *> *PXCNFindCells(id owner) {
    NSMutableArray *roots=[NSMutableArray array];
    for (NSString *getter in @[@"masterListView",@"sectionListView",@"groupListView"]) {
        id v=PXCNObject(owner,getter);if ([v isKindOfClass:UIView.class]) [roots addObject:v];
    }
    if ([owner isKindOfClass:UIViewController.class] && [owner isViewLoaded]) [roots addObject:[owner view]];
    NSArray *cells=PXCNCellsInRoots(roots);
    if (!cells.count) cells=PXCNCellsInRoots(PXCNWindows());
    return cells;
}
static UIView *PXCNContent(UIView *cell) {
    // Sampling a swiped cell's outer container can include transparent action
    // buttons or a zero-width clipping wrapper. Prefer its actual platter.
    id vc=PXCNObject(cell,@"contentViewController");
    UIView *v=([vc isKindOfClass:UIViewController.class] && [vc isViewLoaded]) ? [vc view] : nil;
    if (!PXCNVisible(v)) v=PXCNObject(cell,@"contentView");
    return PXCNVisible(v) ? v : cell;
}
static id PXCNRequestForCell(UIView *cell) {
    id vc=PXCNObject(cell,@"contentViewController");
    id request=PXCNObject(vc,@"notificationRequest");
    if (!request) request=PXCNObject(cell,@"notificationRequest");
    return request;
}
static UIView *PXCNCellForRequest(id owner,id request) {
    if (!owner || !request) return nil;
    SEL selector=NSSelectorFromString(@"_currentCellForNotificationRequest:");
    if (!PXCNMethod(owner,selector,"@","@")) return nil;
    id cell=((id(*)(id,SEL,id))objc_msgSend)(owner,selector,request);
    return [cell isKindOfClass:UIView.class] && PXCNVisible(cell) ? cell : nil;
}
static BOOL PXCNRequestMatch(id a,id b) {
    if (!a || !b) return NO;
    if (a==b || [a isEqual:b]) return YES;
    SEL matches=NSSelectorFromString(@"matchesRequest:");
    if (PXCNMethod(a,matches,"Bc","@") && ((BOOL(*)(id,SEL,id))objc_msgSend)(a,matches,b)) return YES;
    if (PXCNMethod(b,matches,"Bc","@") && ((BOOL(*)(id,SEL,id))objc_msgSend)(b,matches,a)) return YES;
    id ai=PXCNObject(a,@"notificationIdentifier"),bi=PXCNObject(b,@"notificationIdentifier");
    id as=PXCNObject(a,@"sectionIdentifier"),bs=PXCNObject(b,@"sectionIdentifier");
    BOOL ids=[ai isKindOfClass:NSString.class] && [bi isKindOfClass:NSString.class] && [ai isEqual:bi];
    BOOL sections=(!as || !bs) || ([(id)as isKindOfClass:NSString.class] && [(id)bs isKindOfClass:NSString.class] && [as isEqual:bs]);
    if (ids && sections) return YES;
    id au=PXCNObject(a,@"uuid"),bu=PXCNObject(b,@"uuid");
    if (au && bu && [au isEqual:bu]) return YES;
    id at=PXCNObject(a,@"uniqueThreadIdentifier"),bt=PXCNObject(b,@"uniqueThreadIdentifier");
    return at && bt && [at isEqual:bt] && !ai && !bi;
}
static BOOL PXCNAnimateCells(NSArray<UIView *> *cells,NSString *route,BOOL urgent) {
    if (!PXCNEnabled() || CACurrentMediaTime()<PXCNotificationBatchUntil) return NO;
    NSMutableArray *sources=[NSMutableArray array],*chosen=[NSMutableArray array];
    double now=CACurrentMediaTime();
    for (UIView *cell in cells) {
        NSNumber *stamp=objc_getAssociatedObject(cell,PXCCellStamp);
        if (stamp && now-stamp.doubleValue<(urgent?0.12:0.35)) continue;
        UIView *source=PXCNContent(cell);
        NSNumber *sourceStamp=objc_getAssociatedObject(source,PXCCellStamp);
        if (sourceStamp && now-sourceStamp.doubleValue<(urgent?0.12:0.35)) continue;
        if (PXCNVisible(source) && ![sources containsObject:source]) { [sources addObject:source];[chosen addObject:cell]; }
    }
    BOOL started=NO;
    @try { if (sources.count) started=PXCDisintegrateNotificationViews(sources,urgent); }
    @catch (NSException *e) { PXCLog([@"notification snapshot exception " stringByAppendingString:e.name]); }
    if (started) {
        for (UIView *cell in chosen) objc_setAssociatedObject(cell,PXCCellStamp,@(now),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *source in sources) objc_setAssociatedObject(source,PXCCellStamp,@(now),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    PXCLog([NSString stringWithFormat:@"notification route=%@ cells=%lu sources=%lu started=%d urgent=%d",route,(unsigned long)cells.count,(unsigned long)sources.count,started,urgent]);
    return started;
}
void PXCNotificationCaptureCell(UIView *cell,NSString *route,BOOL urgent) {
    if (!NSThread.isMainThread) { PXCLog([@"notification off-main skipped " stringByAppendingString:route]);return; }
    if ([cell isKindOfClass:UIView.class]) PXCNAnimateCells(@[cell],route,urgent);
}
void PXCNotificationCapture(id owner,id requests,id sections,BOOL all,NSString *route) {
    if (!PXCNEnabled()) { PXCLog([@"notification disabled/off-main " stringByAppendingString:route]);return; }
    if (CACurrentMediaTime()<PXCNotificationBatchUntil) return;
    NSArray *req=PXCNArray(requests),*sec=PXCNArray(sections),*cells=PXCNFindCells(owner);
    NSMutableOrderedSet *matchedSet=[NSMutableOrderedSet orderedSet];
    NSUInteger direct=0;
    for (id r in req) {
        UIView *cell=PXCNCellForRequest(owner,r);
        if (cell) { [matchedSet addObject:cell];direct++; }
    }
    for (UIView *cell in cells) {
        id request=PXCNRequestForCell(cell);
        BOOL match=all;
        for (id r in req) if (PXCNRequestMatch(request,r)) { match=YES;break; }
        if (!match && sec.count) {
            id section=PXCNObject(request,@"sectionIdentifier");
            for (id s in sec) {
                id candidate=[s isKindOfClass:NSString.class] ? s : PXCNObject(s,@"sectionIdentifier");
                if (candidate && [candidate isEqual:section]) { match=YES;break; }
            }
        }
        if (match) [matchedSet addObject:cell];
    }
    NSArray *matched=matchedSet.array;
    PXCLog([NSString stringWithFormat:@"notification event=%@ owner=%@ payload=%@/%@ scanned=%lu matched=%lu direct=%lu",route,NSStringFromClass([owner class]),requests?NSStringFromClass([requests class]):@"-",sections?NSStringFromClass([sections class]):@"-",(unsigned long)cells.count,(unsigned long)matched.count,(unsigned long)direct]);
    PXCNAnimateCells(matched,route,all || [route isEqualToString:@"one-key-clear"]);
}

@interface PXCClearButtonTarget : NSObject
@property(nonatomic,weak) UIViewController *controller;
- (void)pressed:(UIButton *)button;
@end
@implementation PXCClearButtonTarget
- (void)pressed:(UIButton *)button {
    UIViewController *vc=self.controller;
    if (!vc || !vc.view.window || !PXCSettingsGet().enabled || !PXCSettingsGet().clearAllButton || !button.enabled) return;
    id master=PXCNObject(vc,@"masterList");
    SEL clear=NSSelectorFromString(@"clearAllNotificationRequests");
    NSMutableOrderedSet *lists=[NSMutableOrderedSet orderedSet];
    for (NSString *name in @[@"incomingSectionList",@"historySectionList",@"missedSectionList"]) {
        id list=PXCNObject(master,name);
        if (PXCNMethod(list,clear,"v","")) [lists addObject:list];
    }
    if (!lists.count) { PXCLog(@"notification clear button unavailable: native section clear ABI missing");return; }
    button.enabled=NO;
    // Same native section operations used by Clear All. Never call the master
    // forwarding method with master as its own component: that can recurse.
    PXCNotificationCapture(vc,nil,nil,YES,@"one-key-clear");
    PXCNotificationBatchUntil=CACurrentMediaTime()+0.18;
    PXCLog([NSString stringWithFormat:@"notification one-key-clear native sections=%lu",(unsigned long)lists.count]);
    for (id list in lists) ((void(*)(id,SEL))objc_msgSend)(list,clear);
    __weak UIButton *weak=button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.65*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ weak.enabled=YES; });
}
@end
static const void *PXCClearTargetKey=&PXCClearTargetKey;
static void PXCNUpdateButton(UIViewController *vc) {
    if (!NSThread.isMainThread || !vc.isViewLoaded) return;
    PXCClearGlassButton *button=objc_getAssociatedObject(vc,PXCButtonKey);
    PXCSettings s=PXCSettingsGet();
    if (!s.enabled || !s.clearAllButton) {
        [button removeFromSuperview];
        objc_setAssociatedObject(vc,PXCButtonKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (![objc_getAssociatedObject(vc,PXCButtonActiveKey) boolValue]) { button.hidden=YES;return; }
    if (!button) {
        button=[[PXCClearGlassButton alloc] initWithFrame:CGRectZero];
        button.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
        button.translatesAutoresizingMaskIntoConstraints=YES;
        PXCClearButtonTarget *target=[PXCClearButtonTarget new];target.controller=vc;
        [button addTarget:target action:@selector(pressed:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button,PXCClearTargetKey,target,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc,PXCButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [vc.view addSubview:button];
        PXCLog(@"notification one-key-clear button attached");
    }
    PXCClearAppearancePlace(button,vc.view);
    if (vc.view.subviews.lastObject!=button) [vc.view bringSubviewToFront:button];
}
void PXCNotificationSettingsChanged(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCNotificationSettingsChanged(); });return; }
    for (UIViewController *vc in PXCNotificationControllers.allObjects) PXCNUpdateButton(vc);
}

static void (*PXCNOrigAppear)(id,SEL,BOOL);
static void PXCNAppear(id self,SEL cmd,BOOL animated) {
    PXCNOrigAppear(self,cmd,animated);
    if (!NSThread.isMainThread || ![self isKindOfClass:UIViewController.class]) return;
    if (!PXCNotificationControllers) PXCNotificationControllers=[NSHashTable weakObjectsHashTable];
    [PXCNotificationControllers addObject:self];
    objc_setAssociatedObject(self,PXCButtonActiveKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![objc_getAssociatedObject(self,PXCSessionKey) boolValue]) {
        objc_setAssociatedObject(self,PXCSessionKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);PXCDustBeginSession();
    }
    PXCNUpdateButton(self);
}
static void (*PXCNOrigWillDisappear)(id,SEL,BOOL);
static void PXCNWillDisappear(id self,SEL cmd,BOOL animated) {
    PXCNOrigWillDisappear(self,cmd,animated);
    if (!NSThread.isMainThread) return;
    objc_setAssociatedObject(self,PXCButtonActiveKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([objc_getAssociatedObject(self,PXCSessionKey) boolValue]) {
        objc_setAssociatedObject(self,PXCSessionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);PXCDustEndSession();
    }
    UIButton *button=objc_getAssociatedObject(self,PXCButtonKey);button.hidden=YES;
}
static void (*PXCNOrigLayout)(id,SEL);
static void PXCNLayout(id self,SEL cmd) {
    PXCNOrigLayout(self,cmd);
    if (NSThread.isMainThread && [self isKindOfClass:UIViewController.class]) PXCNUpdateButton(self);
}
/* dismiss 的 self 是 NCNotificationGroupList，并非 UIViewController，
 * 不能直接发 -view。沿响应链找真正承载它的窗口。 */
static UIWindow *PXCNHostWindow(id object) {
    if ([object isKindOfClass:UIViewController.class]) {
        UIViewController *vc=object;return vc.isViewLoaded ? vc.view.window : nil;
    }
    if ([object isKindOfClass:UIView.class]) return ((UIView *)object).window;
    UIResponder *r=[object isKindOfClass:UIResponder.class] ? object : nil;
    for (;r;r=r.nextResponder) {
        if ([r isKindOfClass:UIWindow.class]) return (UIWindow *)r;
        if ([r isKindOfClass:UIViewController.class]) {
            UIViewController *vc=(UIViewController *)r;return vc.isViewLoaded ? vc.view.window : nil;
        }
    }
    return nil;
}
static void (*PXCNOrigDismiss)(id,SEL,id,id);
static void PXCNDismiss(id self,SEL cmd,id cell,id completion) {
    if (self && ![objc_getAssociatedObject(self,PXCSessionKey) boolValue]) {
        // Covers a missed viewDidAppear. The key keeps appear/disappear and this
        // timeout from double-incrementing the same controller session.
        objc_setAssociatedObject(self,PXCSessionKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PXCDustBeginSession();
        __weak id weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
            id s=weakSelf;
            if (s && [objc_getAssociatedObject(s,PXCSessionKey) boolValue] && !PXCNHostWindow(s)) {
                objc_setAssociatedObject(s,PXCSessionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                PXCDustEndSession();
            }
        });
    }
    PXCNotificationCaptureCell(cell,@"group-dismiss-cell",YES);
    PXCNOrigDismiss(self,cmd,cell,completion);
}
static void (*PXCNOrigClearRequest)(id,SEL,id,id);
static void PXCNClearRequest(id self,SEL cmd,id request,id completion) {
    PXCNotificationCapture(self,request ? @[request] : @[],nil,NO,@"group-clear-request");
    PXCNOrigClearRequest(self,cmd,request,completion);
}
static void (*PXCNOrigGroupClearAll)(id,SEL,id);
static void PXCNGroupClearAll(id self,SEL cmd,id handler) {
    // This grouped footer is a user clear-all event, not expansion/restacking.
    NSArray *cells=PXCNCellsInRoots(@[PXCNObject(self,@"groupListView") ?: [UIView new]]);
    PXCNAnimateCells(cells,@"group-footer-clear-all",YES);
    PXCNOrigGroupClearAll(self,cmd,handler);
}
static void (*PXCNOrigSectionAll)(id,SEL);
static void PXCNSectionAll(id self,SEL cmd) {
    NSArray *cells=PXCNCellsInRoots(@[PXCNObject(self,@"sectionListView") ?: [UIView new]]);
    PXCNAnimateCells(cells,@"section-clear-all",YES);
    PXCNOrigSectionAll(self,cmd);
}
static void (*PXCNOrigMasterAll)(id,SEL,id);
static void PXCNMasterAll(id self,SEL cmd,id component) {
    NSMutableArray *roots=[NSMutableArray array];
    for (NSString *name in @[@"groupListView",@"sectionListView",@"masterListView"]) {
        id root=PXCNObject(component,name);if ([root isKindOfClass:UIView.class]) [roots addObject:root];
    }
    PXCNAnimateCells(PXCNCellsInRoots(roots),@"master-component-clear-all",YES);
    PXCNOrigMasterAll(self,cmd,component);
}
static void (*PXCNOrigControllerClear)(id,SEL,BOOL);
static void PXCNControllerClear(id self,SEL cmd,BOOL userAction) {
    if ([self isKindOfClass:UIViewController.class] && [self isViewLoaded]) {
        UIView *view=[self view];
        PXCNotificationCaptureCell(view,@"view-controller-clear",YES);
    }
    PXCNOrigControllerClear(self,cmd,userAction);
}
static void PXCNHook(const char *clsName,const char *selector,const char *ret,const char *args,IMP hook,IMP *original) {
    if (*original) return;
    Class cls=objc_getClass(clsName);SEL s=sel_registerName(selector);
    if (!cls) return;
    Method m=class_getInstanceMethod(cls,s);
    if (!m) return;
    char t[128];method_getReturnType(m,t,sizeof(t));BOOL valid=(*PXCNType(t) && strchr(ret,*PXCNType(t))) && method_getNumberOfArguments(m)==strlen(args)+2;
    for (unsigned i=0;valid && i<strlen(args);i++) {
        method_getArgumentType(m,i+2,t,sizeof(t));const char *a=PXCNType(t);
        valid=args[i]=='k' ? (a[0]=='@' && a[1]=='?') : args[i]=='b' ? (*a=='B' || *a=='c') : (*a==args[i]);
    }
    if (!valid) { PXCLog([NSString stringWithFormat:@"notification ABI skipped %s %s",clsName,selector]);return; }
    MSHookMessageEx(cls,s,hook,original);
    PXCLog([NSString stringWithFormat:@"notification hook installed %s %s",clsName,selector]);
}
void PXCNotificationInstallHooks(void) {
    PXCClearAppearanceInstallHooks();
    PXCNHook("NCNotificationStructuredListViewController","viewWillDisappear:","v","b",(IMP)PXCNWillDisappear,(IMP *)&PXCNOrigWillDisappear);
    PXCNHook("NCNotificationStructuredListViewController","viewDidLayoutSubviews","v","",(IMP)PXCNLayout,(IMP *)&PXCNOrigLayout);
    PXCNHook("NCNotificationGroupList","notificationListCellRequestsDismissAction:completion:","v","@k",(IMP)PXCNDismiss,(IMP *)&PXCNOrigDismiss);
    PXCNHook("NCNotificationGroupList","_clearNotificationRequest:withCompletion:","v","@k",(IMP)PXCNClearRequest,(IMP *)&PXCNOrigClearRequest);
    PXCNHook("NCNotificationGroupList","notificationListCoalescingControlsHandlerRequestsClearingAllNotifications:","v","@",(IMP)PXCNGroupClearAll,(IMP *)&PXCNOrigGroupClearAll);
    PXCNHook("NCNotificationStructuredSectionList","clearAllNotificationRequests","v","",(IMP)PXCNSectionAll,(IMP *)&PXCNOrigSectionAll);
    PXCNHook("NCNotificationMasterList","notificationListComponentRequestsClearingAllNotificationRequests:","v","@",(IMP)PXCNMasterAll,(IMP *)&PXCNOrigMasterAll);
    PXCNHook("NCNotificationViewController","_executeClearAction:","v","b",(IMP)PXCNControllerClear,(IMP *)&PXCNOrigControllerClear);
    PXCNHook("NCNotificationStructuredListViewController","viewDidAppear:","v","b",(IMP)PXCNAppear,(IMP *)&PXCNOrigAppear);
}
