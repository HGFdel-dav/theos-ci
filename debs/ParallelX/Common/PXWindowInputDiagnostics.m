#import "PXWindowInputDiagnostics.h"
#import "PXWindowInputPolicy.h"
#import "PXWindowMemoryStore.h"
#import "PXCloneRuntime.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface PXInputContext : NSObject {
@public
    PXInputRate rate;
    PXInputRate stateRate;
    PXInputRate transitionRate;
}
@property(nonatomic,weak) id bridge;
@property(nonatomic,weak) UIView *canvas;
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,weak) id lastScene;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic) uint64_t serial;
@property(nonatomic) uint64_t launchToken;
@property(nonatomic) uint64_t sceneSerial;
@property(nonatomic) BOOL registered;
@property(nonatomic) double openedAt;
@property(nonatomic) double lastSample;
@property(nonatomic,strong) NSDictionary *lastState;
@property(nonatomic) unsigned sampled;
@property(nonatomic) unsigned totalEvents;
@property(nonatomic) unsigned exceptions;
@end
@implementation PXInputContext @end

static const void *PXInputContextKey=&PXInputContextKey;
static const void *PXInputTransactionKey=&PXInputTransactionKey;
void PXWindowInputDiagnosticsLinkTransaction(id bridge,uint64_t token) {
    @try { if(NSThread.isMainThread && bridge) {
        objc_setAssociatedObject(bridge,PXInputTransactionKey,@(token),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } } @catch(__unused NSException *exception) { }
}
static NSHashTable<PXInputContext *> *PXInputContexts;
static uint64_t PXInputNextScene;
static void (*PXInputOriginalSendEvent)(id,SEL,id);
static void (*PXInputOriginalInteraction)(id,SEL,BOOL);
static BOOL (*PXInputOriginalForeground)(id,SEL,id);
static void (*PXInputOriginalSceneUpdate)(id,SEL,id,id,id,id);

static BOOL PXInputEnabled(void) {
    return [PXWindowMemoryStore.shared.snapshot[@"diagnostics"] boolValue];
}
static BOOL PXInputTarget(NSString *bundle) {
    return [bundle isEqual:@"com.tencent.xin"] || [bundle isEqual:@"com.tencent.mqq"] ||
        [bundle isEqual:@"com.crossutility.quantumult-x"];
}
static id PXInputObject(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    return PXCloneInstanceMethodMatches(object,sel,@encode(id),@[]) ? PXCloneSendId(object,sel) : nil;
}
/* -1=not measured/unsupported. Never turn a missing getter into false. */
static NSInteger PXInputBool(id object,NSString *name) {
    SEL sel=NSSelectorFromString(name);
    @try {
        if(PXCloneInstanceMethodMatches(object,sel,@encode(BOOL),@[]))
            return ((BOOL(*)(id,SEL))objc_msgSend)(object,sel) ? 1 : 0;
        if(PXCloneInstanceMethodMatches(object,sel,@encode(signed char),@[]))
            return ((signed char(*)(id,SEL))objc_msgSend)(object,sel) ? 1 : 0;
    } @catch(__unused NSException *exception) { }
    return -1;
}
static NSInteger PXInputPID(id scene) {
    id process=PXInputObject(scene,@"clientProcess");SEL sel=NSSelectorFromString(@"pid");
    @try {
        if(PXCloneInstanceMethodMatches(process,sel,@encode(NSInteger),@[]))
            return ((NSInteger(*)(id,SEL))objc_msgSend)(process,sel);
        if(PXCloneInstanceMethodMatches(process,sel,@encode(int),@[]))
            return ((int(*)(id,SEL))objc_msgSend)(process,sel);
    } @catch(__unused NSException *exception) { }
    return -1;
}
static BOOL PXInputCurrent(PXInputContext *c) {
    return c && PXInputScopeCurrent(c.registered,c.window && c.canvas.window==c.window,
        PXInputObject(c.bridge,@"canvas")==c.canvas,[PXInputObject(c.bridge,@"bundleID") isEqual:c.bundle],
        c.serial,((PXInputContext *)objc_getAssociatedObject(c.bridge,PXInputContextKey)).serial);
}
static void PXInputRecord(PXInputContext *c,NSString *event,NSDictionary *details) {
    if(!NSThread.isMainThread || !c || !PXInputEnabled())return;
    NSMutableDictionary *state=[details mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"appHash"]=@(PXWMIdentifierHash(c.bundle.UTF8String));state[@"openSerial"]=@(c.serial);
    state[@"launchToken"]=@(c.launchToken); // Zero means ordinary native open, not a missing plugin route.
    state[@"inputSchema"]=@1;state[@"elapsedMs"]=@(PXInputMilliseconds(c.openedAt,CACurrentMediaTime()));
    state[@"remoteReceiptKnown"]=@NO;state[@"appResponsivenessKnown"]=@NO;
    state[@"hostPhaseKnown"]=@NO; // Private Swift storage is never read via guessed offsets.
    [PXWindowMemoryStore.shared diagnostic:event details:state];
}
static NSDictionary *PXInputReadState(PXInputContext *c) {
    id bridge=c.bridge,scene=PXInputObject(bridge,@"scene");
    id settings=PXInputObject(scene,@"settings");
    UIView *host=PXInputObject(bridge,@"hostView");
    if(![host isKindOfClass:UIView.class])host=nil;
    if(scene && scene!=c.lastScene) { c.lastScene=scene;c.sceneSerial=++PXInputNextScene; }
    unsigned ignored=0,depth=0;
    for(UIView *v=host;v && depth<64;v=v.superview,++depth)
        if(!v.userInteractionEnabled || v.hidden || v.alpha<=0.01)ignored++;
    return @{@"scenePresent":@(scene!=nil),@"sceneSerial":@(scene?c.sceneSerial:0),@"appPID":@(PXInputPID(scene)),
        @"surface":@(PXInputBool(bridge,@"hasHostedSurface")),@"suppressSelection":@(PXInputBool(bridge,@"suppressSelection")),
        @"sceneAllowsSelection":@(PXInputBool(settings,@"allowsSelection")),
        @"sceneForeground":@(PXInputBool(settings,@"isForeground")),@"sceneBackgrounded":@(PXInputBool(settings,@"isBackgrounded")),
        @"canvasInteractive":@(c.canvas ? (NSInteger)c.canvas.userInteractionEnabled : -1),
        @"hostPresent":@(host!=nil),@"hostInteractive":@(host ? (NSInteger)host.userInteractionEnabled : -1),
        @"hostUnderCanvas":@(host && [host isDescendantOfView:c.canvas]),@"hostWindowMatches":@(host && host.window==c.window),
        @"ignoredAncestors":@(ignored),@"ancestorDepth":@(depth),@"hierarchyTruncated":@(depth==64),
        @"windowHidden":@(c.window ? (NSInteger)c.window.hidden : -1),@"windowInteractive":@(c.window ? (NSInteger)c.window.userInteractionEnabled : -1),
        @"windowKey":@(c.window ? (NSInteger)c.window.isKeyWindow : -1),
        @"bundleMatch":@([PXInputObject(bridge,@"bundleID") isEqual:c.bundle]),@"canvasMatch":@(PXInputObject(bridge,@"canvas")==c.canvas)};
}
static void PXInputObserveContext(PXInputContext *c,unsigned stage,BOOL force) {
    if(!NSThread.isMainThread || !c || !c.registered || !PXInputEnabled())return;
    if(c.canvas.window && c.canvas.window!=c.window &&
        PXInputObject(c.bridge,@"canvas")==c.canvas && [PXInputObject(c.bridge,@"bundleID") isEqual:c.bundle])
        c.window=c.canvas.window;
    double now=CACurrentMediaTime();
    if(!force && now-c.lastSample<0.25)return;
    c.lastSample=now;
    NSDictionary *state=PXInputReadState(c);
    if(!force && [state isEqual:c.lastState])return;
    if(!PXInputRateTake(&c->stateRate,now))return;
    if(c.sampled<UINT32_MAX)c.sampled++;c.lastState=state;
    NSMutableDictionary *details=[state mutableCopy];details[@"stage"]=@(stage);
    details[@"stateSamples"]=@(c.sampled);details[@"stateSuppressed"]=@(c->stateRate.suppressed);
    details[@"currentBinding"]=@(PXInputCurrent(c));
    PXInputRecord(c,@"input_state",details);
}
void PXWindowInputDiagnosticsObserve(id bridge,unsigned stage) {
    @try { PXInputObserveContext(objc_getAssociatedObject(bridge,PXInputContextKey),stage,NO); }
    @catch(__unused NSException *exception) { }
}

void PXWindowInputDiagnosticsBind(id bridge,UIView *canvas,NSString *bundle,uint64_t serial,double openedAt) {
    @try {
        if(!NSThread.isMainThread || !bridge || ![canvas isKindOfClass:UIView.class] ||
            !PXInputTarget(bundle) || !serial)return;
        PXInputContext *old=objc_getAssociatedObject(bridge,PXInputContextKey);
        if(old && old.serial==serial && old.canvas==canvas)return;
        if(old) {
            old.registered=NO;
            @try { PXInputRecord(old,@"input_superseded",@{}); }
            @catch(__unused NSException *exception) { }
        }
        PXInputContext *c=[PXInputContext new];c.bridge=bridge;c.canvas=canvas;c.window=canvas.window;
        c.bundle=bundle;c.serial=serial;c.openedAt=openedAt;c.registered=YES;
        c.launchToken=[objc_getAssociatedObject(bridge,PXInputTransactionKey) unsignedLongLongValue];
        objc_setAssociatedObject(bridge,PXInputContextKey,c,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(!PXInputContexts)PXInputContexts=[NSHashTable weakObjectsHashTable];
        [PXInputContexts addObject:c];
        @try { PXInputObserveContext(c,1,YES); }
        @catch(__unused NSException *exception) { if(c.exceptions<65535)c.exceptions++; }
        const double delays[]={0.25,1,3,8,15};
        __weak PXInputContext *weakContext=c;
        for(unsigned i=0;i<5;i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delays[i]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                PXInputContext *current=weakContext;
                if(!PXInputSameGeneration(serial,current.serial,current.registered))return;
                @try { PXInputObserveContext(current,2,YES); }
                @catch(__unused NSException *exception) { }
            });
        }
    } @catch(__unused NSException *exception) { }
}
void PXWindowInputDiagnosticsClose(id bridge) {
    @try {
        if(!NSThread.isMainThread)return;
        PXInputContext *c=objc_getAssociatedObject(bridge,PXInputContextKey);if(!c)return;
        c.registered=NO;
        objc_setAssociatedObject(bridge,PXInputContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PXInputRecord(c,@"input_closed",@{@"eventsObserved":@(c.totalEvents),@"suppressed":@(c->rate.suppressed),@"observerExceptions":@(c.exceptions)});
    } @catch(__unused NSException *exception) { }
}

static PXInputContext *PXInputContextForWindow(id window) {
    if(!NSThread.isMainThread || !PXInputContexts || !PXInputEnabled())return nil;
    PXInputContext *found=nil;
    for(PXInputContext *c in PXInputContexts) {
        if(!c.registered || !c.window || c.window!=window)continue;
        if(found)return nil; // Ambiguous ownership is not silently guessed.
        found=c;
    }
    return found;
}
static NSDictionary *PXInputTouchSnapshot(PXInputContext *c,UIEvent *event) {
    if(![event isKindOfClass:UIEvent.class] || event.type!=UIEventTypeTouches)return nil;
    if(!PXInputCurrent(c)) { PXInputObserveContext(c,7,NO);return nil; }
    UIView *host=PXInputObject(c.bridge,@"hostView"),*keyboard=PXInputObject(c.bridge,@"keyboardOverlay");
    if(![host isKindOfClass:UIView.class])host=nil;
    if(![keyboard isKindOfClass:UIView.class])keyboard=nil;
    unsigned count=0,phases=0,categories=0;BOOL truncated=NO;
    for(UITouch *touch in event.allTouches) {
        if(![touch isKindOfClass:UITouch.class] || touch.window!=c.window)continue;
        if(++count>8) { truncated=YES;break; }
        NSInteger phase=touch.phase;
        if(phase<0 || phase>UITouchPhaseCancelled)continue;
        if(phase==UITouchPhaseStationary)continue;
        phases|=1u<<(unsigned)phase;
        // Observe touch.view exactly as it exists at this boundary. It may
        // still be nil before dispatch; do not call hitTest or inspect coordinates.
        UIView *view=touch.view;
        unsigned category= !view ? 0 : keyboard && [view isDescendantOfView:keyboard] ? 3 :
            host && [view isDescendantOfView:host] ? 1 : [view isDescendantOfView:c.canvas] ? 2 : 4;
        categories|=1u<<category;
    }
    if(!phases)return nil;
    if(c.totalEvents<UINT32_MAX)c.totalEvents++;
    if(!PXInputRateTake(&c->rate,CACurrentMediaTime()))return nil;
    NSDictionary *state=PXInputReadState(c);NSMutableDictionary *note=[state mutableCopy];
    note[@"phaseMask"]=@(phases);note[@"receiverMask"]=@(categories);note[@"touchCount"]=@(MIN(count,8u));
    note[@"touchesTruncated"]=@(truncated);note[@"eventsObserved"]=@(c.totalEvents);note[@"suppressed"]=@(c->rate.suppressed);
    c->rate.suppressed=0;
    // This means a real host event met a CLOSED host-side input gate. It is
    // not proof of app-thread deadlock, nor of a remote receipt.
    note[@"hostGateClosed"]=@([state[@"hostPresent"] boolValue] &&
        ([state[@"canvasInteractive"] integerValue]==0 || [state[@"hostInteractive"] integerValue]==0 ||
         [state[@"sceneAllowsSelection"] integerValue]==0 || [state[@"ignoredAncestors"] unsignedIntValue]>0));
    // Preserve a bounded input trace even when all host switches look healthy:
    // the remote app may still be stalled. This is an observation, not a fault verdict.
    note[@"diagIncident"]=@YES;note[@"observationOnly"]=@YES;
    return note;
}
static NSDictionary *PXInputAfterDispatch(PXInputContext *c,UIEvent *event) {
    if(!PXInputCurrent(c))return @{@"receiverAfterKnown":@NO};
    UIView *host=PXInputObject(c.bridge,@"hostView"),*keyboard=PXInputObject(c.bridge,@"keyboardOverlay");
    if(![host isKindOfClass:UIView.class])host=nil;
    if(![keyboard isKindOfClass:UIView.class])keyboard=nil;
    unsigned receivers=0,count=0;
    for(UITouch *touch in event.allTouches) {
        if(![touch isKindOfClass:UITouch.class] || touch.window!=c.window)continue;
        if(++count>8)break;
        UIView *view=touch.view;
        unsigned category=!view ? 0 : keyboard && [view isDescendantOfView:keyboard] ? 3 :
            host && [view isDescendantOfView:host] ? 1 : [view isDescendantOfView:c.canvas] ? 2 : 4;
        receivers|=1u<<category;
    }
    return @{@"receiverAfterKnown":@YES,@"receiverAfterMask":@(receivers)};
}
static void PXInputSendEvent(id self,SEL command,id event) {
    PXInputContext *c=nil;NSDictionary *note=nil;double start=0;BOOL returned=NO;
    @try {
        c=PXInputContextForWindow(self);if(c)note=PXInputTouchSnapshot(c,event);
        if(note) { PXInputRecord(c,@"input_host_arrived",note);start=CACurrentMediaTime(); }
    }
    @catch(__unused NSException *exception) { if(c && c.exceptions<65535)c.exceptions++;note=nil; }
    @try {
        if(PXInputOriginalSendEvent)PXInputOriginalSendEvent(self,command,event);
        returned=PXInputOriginalSendEvent!=NULL;
    } @finally {
        // Never swallow an exception from the ORIGINAL. Only observation
        // failures are isolated, and arguments are forwarded exactly once.
        @try {
            if(note) {
                NSMutableDictionary *done=[note mutableCopy];done[@"dispatchReturned"]=@(returned);
                done[@"dispatchMs"]=@(PXInputMilliseconds(start,CACurrentMediaTime()));
                done[@"bindingCurrentAfter"]=@(PXInputCurrent(c));
                done[@"receiverAfterKnown"]=@NO;
                @try { if(returned && PXInputEnabled()) [done addEntriesFromDictionary:PXInputAfterDispatch(c,event)]; }
                @catch(__unused NSException *exception) { }
                PXInputRecord(c,@"input_host_dispatch",done);
            }
        } @catch(__unused NSException *exception) { }
    }
}
static void PXInputInteraction(id self,SEL command,BOOL enabled) {
    if(PXInputOriginalInteraction)PXInputOriginalInteraction(self,command,enabled);
    if(!NSThread.isMainThread)return;
    @try {
        PXInputContext *c=objc_getAssociatedObject(self,PXInputContextKey);
        if(c && PXInputEnabled() && PXInputRateTake(&c->transitionRate,CACurrentMediaTime())) {
            PXInputRecord(c,@"input_native_interaction",@{@"requestedEnabled":@(enabled)});PXInputObserveContext(c,3,YES);
        }
    } @catch(__unused NSException *exception) { }
}
static BOOL PXInputForeground(id self,SEL command,id scene) {
    BOOL result=PXInputOriginalForeground ? PXInputOriginalForeground(self,command,scene) : NO;
    if(!NSThread.isMainThread)return result;
    @try {
        PXInputContext *c=objc_getAssociatedObject(self,PXInputContextKey);
        if(c && PXInputEnabled() && PXInputRateTake(&c->transitionRate,CACurrentMediaTime())) {
            PXInputRecord(c,@"input_native_foreground",@{@"nativeResult":@(result)});PXInputObserveContext(c,4,YES);
        }
    } @catch(__unused NSException *exception) { }
    return result;
}
static void PXInputSceneUpdate(id self,SEL command,id scene,id diff,id old,id transition) {
    if(PXInputOriginalSceneUpdate)PXInputOriginalSceneUpdate(self,command,scene,diff,old,transition);
    PXWindowInputDiagnosticsObserve(self,5);
}
BOOL PXWindowInputDiagnosticsInstall(Class bridgeClass) {
    @try {
    if(!NSThread.isMainThread || !bridgeClass)return NO;
    NSArray *object=@[@"@"];
#define PXINPUT_HOOK(cls,sel,ret,args,replacement,storage,type) \
    do { if(!(storage) && PXCloneClassInstanceMethodMatches(cls,sel,ret,args)) { \
        IMP original=NULL; if(PXCloneHookMessage(cls,sel,(IMP)replacement,&original))storage=(type)original; \
    } } while(0)
    PXINPUT_HOOK(UIWindow.class,@selector(sendEvent:),@encode(void),object,PXInputSendEvent,PXInputOriginalSendEvent,void (*)(id,SEL,id));
    PXINPUT_HOOK(bridgeClass,NSSelectorFromString(@"setHostedInteractionEnabled:"),@encode(void),
        (@[[NSString stringWithUTF8String:@encode(BOOL)]]),PXInputInteraction,PXInputOriginalInteraction,void (*)(id,SEL,BOOL));
    PXINPUT_HOOK(bridgeClass,NSSelectorFromString(@"foregroundScene:"),@encode(BOOL),object,
        PXInputForeground,PXInputOriginalForeground,BOOL (*)(id,SEL,id));
    PXINPUT_HOOK(bridgeClass,NSSelectorFromString(@"scene:didUpdateClientSettingsWithDiff:oldClientSettings:transitionContext:"),
        @encode(void),(@[@"@",@"@",@"@",@"@"]),PXInputSceneUpdate,PXInputOriginalSceneUpdate,void (*)(id,SEL,id,id,id,id));
#undef PXINPUT_HOOK
    [PXWindowMemoryStore.shared diagnostic:@"input_observer_hooks" details:@{
        @"hostDispatch":@(PXInputOriginalSendEvent!=NULL),@"interaction":@(PXInputOriginalInteraction!=NULL),
        @"foreground":@(PXInputOriginalForeground!=NULL),@"sceneUpdate":@(PXInputOriginalSceneUpdate!=NULL),
        @"remoteReceiptKnown":@NO,@"appResponsivenessKnown":@NO}];
    return PXInputOriginalSendEvent && PXInputOriginalInteraction && PXInputOriginalForeground;
    } @catch(__unused NSException *exception) { return NO; }
}
