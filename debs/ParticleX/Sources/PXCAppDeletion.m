#import "PXCAppDeletion.h"
#import "PXCSettings.h"
#import <substrate.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import <math.h>

static const void *PXCDelStamp=&PXCDelStamp;
// Only accessed on main; nested uninstall overloads must not spawn duplicates.
static NSUInteger PXCDelUninstallDepth;
static BOOL PXCDelInstallReported;
static id PXCDelObject(id o,SEL s) {
    Method m=o?class_getInstanceMethod(object_getClass(o),s):NULL;
    if (!m || method_getNumberOfArguments(m)!=2) return nil;
    char t[64];method_getReturnType(m,t,sizeof(t));
    const char *p=t;while (*p && strchr("rnNoORV",*p))p++;
    if (*p!='@')return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o,s);
}
static BOOL PXCDelBool(id o,const char *name) {
    SEL s=sel_registerName(name);Method m=o?class_getInstanceMethod(object_getClass(o),s):NULL;
    if(!m||method_getNumberOfArguments(m)!=2)return NO;char t[32];method_getReturnType(m,t,sizeof(t));
    const char *p=t;while(*p&&strchr("rnNoORV",*p))p++;if(*p!='B'&&*p!='c')return NO;
    return ((BOOL(*)(id,SEL))objc_msgSend)(o,s);
}
static NSArray *PXCDelArray(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSSet.class]) return [value allObjects];
    if ([value isKindOfClass:NSOrderedSet.class]) return [value array];
    return @[];
}
static BOOL PXCDelVisible(UIView *v) {
    if (![v isKindOfClass:UIView.class]||!v.window||v.hidden||v.alpha<0.05||v.window.hidden)return NO;
    for (UIView *p=v.superview;p;p=p.superview) if (p.hidden||p.alpha<0.05) return NO;
    CGRect r=[v convertRect:v.bounds toView:v.window];
    return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)&&!CGRectIsEmpty(CGRectIntersection(r,v.window.bounds));
}
static UIView *PXCDelFindView(id icon) {
    Class iconView=NSClassFromString(@"SBIconView");if(!iconView)return nil;
    NSMutableOrderedSet *windows=[NSMutableOrderedSet orderedSet];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if([scene isKindOfClass:UIWindowScene.class])[windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    [windows addObjectsFromArray:PXCDelArray(PXCDelObject(UIApplication.sharedApplication,sel_registerName("windows")))];
    for(UIWindow *window in windows) {
        if(window.hidden||window.alpha<0.05)continue;
        NSMutableArray *q=[NSMutableArray arrayWithObject:window];
        for(NSUInteger i=0;i<q.count&&i<3000;i++) {
            UIView *v=q[i];
            if([v isKindOfClass:iconView]&&PXCDelObject(v,sel_registerName("icon"))==icon&&PXCDelVisible(v))return v;
            if(q.count<3000)[q addObjectsFromArray:v.subviews];
        }
    }
    return nil;
}
static void PXCDelAnimate(id icon) {
    if (!NSThread.isMainThread) { PXCLog(@"app deletion skip: off-main native call");return; }
    PXCSettings s=PXCSettingsGet();
    if(!s.enabled||!s.appDeletion||UIAccessibilityIsReduceMotionEnabled())return;
    if(!PXCDelBool(icon,"isApplicationIcon")||PXCDelBool(icon,"isWidgetIcon")||PXCDelBool(icon,"isWidgetStackIcon"))return;
    UIView *view=PXCDelFindView(icon);
    if(!view) { PXCLog(@"app deletion skip: no mounted visible matching icon");return; }
    NSNumber *last=objc_getAssociatedObject(view,PXCDelStamp);double now=CACurrentMediaTime();
    if(last&&now-last.doubleValue<0.5)return;
    if(PXCDisintegrateView(view)) {
        objc_setAssociatedObject(view,PXCDelStamp,@(now),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PXCLog([NSString stringWithFormat:@"app deletion dust started=1"]);
    } else PXCLog(@"app deletion dust started=0: renderer skipped");
}
static BOOL PXCDelEnter(id icon,BOOL animated) {
    if (!NSThread.isMainThread) return NO;
    BOOL outer=PXCDelUninstallDepth==0;
    PXCDelUninstallDepth++;
    if (outer && animated) {
        @try { PXCDelAnimate(icon); }
        @catch (NSException *e) { PXCLog([@"app deletion snapshot exception " stringByAppendingString:e.name]); }
    }
    return YES;
}
static void (*PXCOrigUninstall3)(id,SEL,id,BOOL,id);
static void PXCDelUninstall3(id self,SEL cmd,id icon,BOOL animate,id completion) {
    BOOL scoped=PXCDelEnter(icon,animate);
    @try { PXCOrigUninstall3(self,cmd,icon,animate,completion); }
    @finally { if (scoped) PXCDelUninstallDepth--; }
}
static void (*PXCOrigUninstall2)(id,SEL,id,BOOL);
static void PXCDelUninstall2(id self,SEL cmd,id icon,BOOL animate) {
    BOOL scoped=PXCDelEnter(icon,animate);
    @try { PXCOrigUninstall2(self,cmd,icon,animate); }
    @finally { if (scoped) PXCDelUninstallDepth--; }
}
static void (*PXCOrigUninstall1)(id,SEL,id);
static void PXCDelUninstall1(id self,SEL cmd,id icon) {
    BOOL scoped=PXCDelEnter(icon,YES);
    @try { PXCOrigUninstall1(self,cmd,icon); }
    @finally { if (scoped) PXCDelUninstallDepth--; }
}
static BOOL PXCDelMethod(Class cls,SEL s,const char *ret,const char *args) {
    Method m=class_getInstanceMethod(cls,s);if(!m||method_getNumberOfArguments(m)!=strlen(args)+2)return NO;
    char t[64];method_getReturnType(m,t,sizeof(t));const char *p=t;while(*p&&strchr("rnNoORV",*p))p++;if(!*p||!strchr(ret,*p))return NO;
    for(unsigned i=0;i<strlen(args);i++) {
        method_getArgumentType(m,i+2,t,sizeof(t));p=t;while(*p&&strchr("rnNoORV",*p))p++;
        if (args[i]=='k') { if (p[0]!='@'||p[1]!='?') return NO; }
        else if (args[i]=='b') { if (*p!='B'&&*p!='c') return NO; }
        else if (*p!=args[i]) return NO;
    }
    return YES;
}
void PXCAppDeletionInstallHooks(void) {
    Class cls=objc_getClass("SBHIconManager");if(!cls)return;
    struct {const char *n;const char *a;IMP h;IMP *o;} defs[]={
        {"uninstallIcon:animate:completion:","@bk",(IMP)PXCDelUninstall3,(IMP *)&PXCOrigUninstall3},
        {"uninstallIcon:animate:","@b",(IMP)PXCDelUninstall2,(IMP *)&PXCOrigUninstall2},
        {"uninstallIcon:","@",(IMP)PXCDelUninstall1,(IMP *)&PXCOrigUninstall1}
    };
    BOOL available=NO;
    for(unsigned i=0;i<3;i++){
        if (*defs[i].o) { available=YES;continue; }
        SEL s=sel_registerName(defs[i].n);if(!PXCDelMethod(cls,s,"v",defs[i].a))continue;
        MSHookMessageEx(cls,s,defs[i].h,defs[i].o);
        available=YES;
        PXCLog([NSString stringWithFormat:@"app deletion hook installed %s",defs[i].n]);
    }
    if (!available && !PXCDelInstallReported) { PXCDelInstallReported=YES;PXCLog(@"app deletion unavailable: uninstall ABI did not match"); }
}
