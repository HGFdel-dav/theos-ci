#import "PXWindowMemory.h"
#import "PXWindowMemoryStore.h"
#import "PXCloneRuntime.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

@interface PXWMContext : NSObject
@property(nonatomic, weak) id bridge;
@property(nonatomic, weak) UIView *canvas;
@property(nonatomic, weak) UIView *card;
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL interacting;
@property(nonatomic) BOOL savePending;
@property(nonatomic) BOOL restoring;
@property(nonatomic) BOOL resolved;
@property(nonatomic) BOOL keyKnown;
@property(nonatomic) unsigned key;
@property(nonatomic) CFTimeInterval created;
@end
@implementation PXWMContext
@end

@interface PXWMGesture : NSObject
@property(nonatomic, weak) PXWMContext *context;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) uint64_t epoch;
@property(nonatomic) unsigned orientation;
@property(nonatomic) BOOL orientationKnown;
@end
@implementation PXWMGesture
@end

static const void *PXWMContextKey = &PXWMContextKey;
static const void *PXWMGestureKey = &PXWMGestureKey;
static NSHashTable<PXWMContext *> *PXWMContexts;
static Class PXWMCardClass;
static BOOL PXWMNotifying;
static void (*PXWMOriginalOpen)(id, SEL, id, id, id, void (^)(BOOL));
static void (*PXWMOriginalClose)(id, SEL);
static void (*PXWMOriginalLayout)(id, SEL);
static void (*PXWMOriginalMove)(id, SEL, id);
static void (*PXWMOriginalResize)(id, SEL, id);
static void (*PXWMOriginalControllerLayout)(id, SEL);

static id PXWMObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return PXCloneInstanceMethodMatches(target, selector, @encode(id), @[]) ? PXCloneSendId(target, selector) : nil;
}
static BOOL PXWMBool(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return PXCloneInstanceMethodMatches(target, selector, @encode(BOOL), @[]) && PXCloneSendBool(target, selector);
}
static unsigned long long PXWMAppHash(NSString *bundle) {
    return PXWMIdentifierHash(bundle.UTF8String);
}
static void PXWMLog(PXWMContext *context, NSString *event, NSDictionary *details) {
    NSMutableDictionary *state = [details mutableCopy] ?: [NSMutableDictionary dictionary];
    if (context) {
        state[@"appHash"] = @(PXWMAppHash(context.bundle));
        state[@"generation"] = @(context.generation);
        state[@"orientation"] = @(context.key);
    }
    [PXWindowMemoryStore.shared diagnostic:event details:state];
}
static PXWMRect PXWMFromRect(CGRect rect) {
    return (PXWMRect){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}
static CGRect PXWMToRect(PXWMRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}
static UIView *PXWMFindCard(UIView *canvas) {
    for (UIView *view = canvas; view; view = view.superview)
        if (PXWMCardClass && [view isKindOfClass:PXWMCardClass]) return view;
    return nil;
}

/* The host UIWindow covers the display; its inner PXHostCard is what native
 * resizeHost:/applyResizePreview actually changes (alpha391 0x40ff0). */
static BOOL PXWMNormalGeometry(PXWMContext *context, PXWMGeometry *out, unsigned *key) {
    UIView *canvas = context.canvas;
    UIView *card = PXWMFindCard(canvas);
    UIWindow *window = card.window;
    if (!card || !canvas || !window || !card.superview || window.screen != UIScreen.mainScreen ||
        window.hidden || window.alpha <= 0.1 || !canvas.userInteractionEnabled ||
        !CGAffineTransformIsIdentity(card.transform) ||
        PXWMObject(context.bridge, @"canvas") != canvas ||
        ![PXWMObject(context.bridge, @"bundleID") isEqual:context.bundle] ||
        !PXWMObject(context.bridge, @"scene") || !PXWMBool(context.bridge, @"hasHostedSurface") ||
        PXWMBool(context.bridge, @"fullscreenHandoff") || PXWMBool(context.bridge, @"isHostedKeyboardVisible")) return NO;
    for (UIView *view = card; view; view = view.superview)
        if (view.hidden || view.alpha <= 0.1) return NO;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGSize host = window.bounds.size;
    /* Reject separate dock/icon windows. Rotation can exchange the axes. */
    if (fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
        fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3) return NO;
    CGRect reference = CGRectIntersection(card.superview.bounds,
                        [window convertRect:window.bounds toView:card.superview]);
    /* Native root controllers can rotate their coordinate space while the
     * UIWindow stays portrait. Use the card's reference axes, not screen axes. */
    CGSize content = canvas.bounds.size;
    SEL source = NSSelectorFromString(@"hostedSourceSize");
    if (PXCloneInstanceMethodMatches(context.bridge, source, @encode(CGSize), @[])) {
        @try { content = ((CGSize (*)(id,SEL))objc_msgSend)(context.bridge, source); }
        @catch (__unused NSException *exception) { return NO; }
    }
    if (!isfinite(content.width) || !isfinite(content.height) || content.width <= 0 || content.height <= 0) return NO;
    PXWMGeometry geometry = {PXWMFromRect(card.frame), PXWMFromRect(reference)};
    if (!PXWMValidGeometry(geometry)) return NO;
    context.card = card;
    if (out) *out = geometry;
    if (key) *key = PXWMOrientationKey(reference.size.width > reference.size.height,
                                      content.width > content.height);
    return YES;
}

static void PXWMTryRestore(PXWMContext *context) {
    if (!context || context.restoring || context.interacting || context.savePending ||
        !PXWindowMemoryStore.shared.isLoaded) return;
    PXWMGeometry native;
    unsigned key = 0;
    if (!PXWMNormalGeometry(context, &native, &key)) return;
    BOOL shouldRestore = PXWMMayRestoreLayout(context.resolved, context.keyKnown,
                                            context.key, key, context.interacting, context.savePending);
    context.keyKnown = YES; context.key = key;
    if (!shouldRestore) return;
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    context.resolved = YES;
    if (![snapshot[@"enabled"] boolValue]) {
        PXWMLog(context, @"restore_disabled", @{}); return;
    }
    PXWMGeometry saved;
    if (!PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved)) {
        PXWMLog(context, @"restore_native_default", @{}); return;
    }
    PXWMRect restored;
    if (!PXWMRestore(saved, native.reference, native.frame, &restored)) {
        PXWMLog(context, @"restore_rejected_geometry", @{}); return;
    }
    UIView *card = context.card;
    CGRect requested = PXWMToRect(restored);
    context.restoring = YES;
    [UIView performWithoutAnimation:^{
        card.frame = requested;
        [card setNeedsLayout]; [card layoutIfNeeded];
        [card.window.rootViewController.view setNeedsLayout];
        [card.window.rootViewController.view layoutIfNeeded];
        SEL layout = NSSelectorFromString(@"layoutHost");
        if (PXCloneInstanceMethodMatches(context.bridge, layout, @encode(void), @[]))
            PXCloneSendVoid(context.bridge, layout);
    }];
    context.restoring = NO;
    CGRect actual = card.frame;
    BOOL matched = fabs(actual.origin.x-requested.origin.x)<1 && fabs(actual.origin.y-requested.origin.y)<1 &&
                   fabs(actual.size.width-requested.size.width)<1 && fabs(actual.size.height-requested.size.height)<1;
    PXWMLog(context, matched ? @"restore_geometry_applied" : @"restore_native_layout_changed",
            @{ @"x": @(actual.origin.x), @"y": @(actual.origin.y), @"w": @(actual.size.width),
               @"h": @(actual.size.height), @"expectedW":@(requested.size.width), @"expectedH":@(requested.size.height),
               @"revision":snapshot[@"revision"] ?: @0, @"surface":@(PXWMBool(context.bridge,@"hasHostedSurface")) });
    NSUInteger expectedGeneration = context.generation;
    __weak PXWMContext *weakContext = context;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        PXWMContext *check = weakContext;
        if (!check || check.generation != expectedGeneration || check.interacting || check.key != key) return;
        PXWMGeometry later;
        unsigned laterKey = 0;
        BOOL normal = PXWMNormalGeometry(check, &later, &laterKey);
        BOOL stable = normal && laterKey == key && fabs(later.frame.x-restored.x)<1 &&
            fabs(later.frame.y-restored.y)<1 && fabs(later.frame.width-restored.width)<1 &&
            fabs(later.frame.height-restored.height)<1;
        PXWMLog(check, stable ? @"restore_postlayout_geometry_verified" : @"restore_postlayout_geometry_changed",
                @{@"normal":@(normal),@"matches":@(stable)});
    });
}

static PXWMContext *PXWMContextForGesture(UIGestureRecognizer *gesture) {
    UIWindow *window = gesture.view.window;
    for (PXWMContext *context in PXWMContexts.allObjects)
        if (window && context.canvas.window == window && PXWMFindCard(context.canvas)) return context;
    return nil;
}

static void PXWMSettleSave(PXWMGesture *stamp, NSUInteger attempt) {
    PXWMContext *context = stamp.context;
    if (!context || stamp.generation != context.generation || context.interacting) return;
    PXWMGeometry geometry;
    unsigned key = 0;
    UIView *card = PXWMFindCard(context.canvas);
    BOOL animation = card.layer.animationKeys.count || card.superview.layer.animationKeys.count;
    if (animation && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            PXWMSettleSave(stamp, attempt+1);
        }); return;
    }
    BOOL normal = PXWMNormalGeometry(context, &geometry, &key);
    context.savePending = NO;
    if (!PXWMMayCommitGesture(stamp.orientationKnown, stamp.orientation, key,
                             stamp.generation, context.generation)) {
        PXWMLog(context, @"save_skipped_direction_change", @{});
        PXWMTryRestore(context); return;
    }
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (!PXWMMaySave([snapshot[@"enabled"] boolValue], stamp.epoch,
                    [snapshot[@"epoch"] unsignedLongLongValue], !animation, normal, YES)) {
        PXWMLog(context, @"save_skipped_non_normal_or_reset", @{@"normal":@(normal),@"animation":@(animation)}); return;
    }
    context.key = key; context.keyKnown = YES; context.resolved = YES;
    PXWMLog(context, @"save_user_geometry", @{@"x":@(geometry.frame.x),@"y":@(geometry.frame.y),
              @"w":@(geometry.frame.width),@"h":@(geometry.frame.height)});
    [PXWindowMemoryStore.shared saveGeometry:geometry bundle:context.bundle orientation:key observedEpoch:stamp.epoch];
}

static void PXWMGestureAction(id panel, SEL command, UIGestureRecognizer *gesture,
                             void (*original)(id,SEL,id)) {
    if (!NSThread.isMainThread || ![gesture isKindOfClass:UIGestureRecognizer.class]) {
        if (original) original(panel,command,gesture); return;
    }
    UIGestureRecognizerState phase = gesture.state;
    if (phase == UIGestureRecognizerStateBegan) {
        PXWMContext *context = PXWMContextForGesture(gesture);
        if (context) {
            context.generation++; context.interacting = YES; context.resolved = YES; context.savePending = NO;
            PXWMGesture *stamp = [PXWMGesture new];
            stamp.context = context; stamp.generation = context.generation;
            stamp.epoch = [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue];
            PXWMGeometry startingGeometry;
            unsigned startingKey = 0;
            stamp.orientationKnown = PXWMNormalGeometry(context, &startingGeometry, &startingKey);
            stamp.orientation = startingKey;
            if (stamp.orientationKnown) { context.keyKnown = YES; context.key = startingKey; }
            objc_setAssociatedObject(gesture,PXWMGestureKey,stamp,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PXWMLog(context,@"gesture_begin",@{@"resize":@(command==NSSelectorFromString(@"resizeHost:"))});
        }
    }
    if (original) original(panel,command,gesture);
    if (phase == UIGestureRecognizerStateEnded || phase == UIGestureRecognizerStateCancelled ||
        phase == UIGestureRecognizerStateFailed) {
        PXWMGesture *stamp = objc_getAssociatedObject(gesture,PXWMGestureKey);
        PXWMContext *context = stamp.context;
        if (stamp && context.generation == stamp.generation) {
            context.interacting = NO;
            if (phase == UIGestureRecognizerStateEnded) {
                context.savePending = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ PXWMSettleSave(stamp,0); });
            } else {
                context.savePending = NO;
                context.generation++;
                PXWMLog(context,@"gesture_cancel_no_save",@{});
            }
        }
        objc_setAssociatedObject(gesture,PXWMGestureKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static void PXWMMove(id self,SEL command,id gesture) {
    PXWMGestureAction(self,command,gesture,PXWMOriginalMove);
}
static void PXWMResize(id self,SEL command,id gesture) {
    PXWMGestureAction(self,command,gesture,PXWMOriginalResize);
}
static void PXWMOpen(id self,SEL command,id bundle,id canvas,id overlay,void (^completion)(BOOL)) {
    if (NSThread.isMainThread && [bundle isKindOfClass:NSString.class] &&
        [canvas isKindOfClass:UIView.class]) {
        PXWMContext *previous = objc_getAssociatedObject(self,PXWMContextKey);
        previous.generation++;
        PXWMContext *context = [PXWMContext new];
        context.bridge = self; context.canvas = canvas; context.bundle = bundle;
        context.generation = previous.generation + 1; context.created = CACurrentMediaTime();
        objc_setAssociatedObject(self,PXWMContextKey,context,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [PXWMContexts addObject:context];
        PXWMLog(context,@"native_open_observed",@{});
    }
    /* Preserve the original exact canvas, overlay and completion. No rerouting,
     * waiting, process termination, extra open or cancellation is introduced. */
    if (PXWMOriginalOpen) PXWMOriginalOpen(self,command,bundle,canvas,overlay,completion);
    if (NSThread.isMainThread) {
        PXWMContext *context = objc_getAssociatedObject(self,PXWMContextKey);
        PXWMTryRestore(context);
        __weak PXWMContext *weakContext = context;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
            PXWMContext *pending = weakContext;
            if (pending && !pending.resolved && !pending.interacting)
                PXWMLog(pending,@"restore_waiting_native_geometry",@{});
        });
    }
}
static void PXWMLayout(id self,SEL command) {
    if (PXWMOriginalLayout) PXWMOriginalLayout(self,command);
    if (NSThread.isMainThread) PXWMTryRestore(objc_getAssociatedObject(self,PXWMContextKey));
}
static void PXWMClose(id self,SEL command) {
    if (NSThread.isMainThread) {
        PXWMContext *context = objc_getAssociatedObject(self,PXWMContextKey);
        context.generation++; context.resolved = YES;
        PXWMLog(context,@"native_close_no_transient_save",@{});
        objc_setAssociatedObject(self,PXWMContextKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (PXWMOriginalClose) PXWMOriginalClose(self,command);
}
static void PXWMControllerLayout(id self,SEL command) {
    if (PXWMOriginalControllerLayout) PXWMOriginalControllerLayout(self,command);
    if (!NSThread.isMainThread) return;
    UIWindow *window = [self isKindOfClass:UIViewController.class] ? [(UIViewController *)self view].window : nil;
    for (PXWMContext *context in PXWMContexts.allObjects)
        if (window && context.canvas.window == window) PXWMTryRestore(context);
}
static Class PXWMVendorClass(NSString *suffix) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    Class found = Nil;
    for (unsigned i=0; i<count; ++i) {
        const char *image = class_getImageName(classes[i]);
        if (image && [[NSString stringWithUTF8String:image].lastPathComponent isEqual:@"ParallelX.dylib"] &&
            [NSStringFromClass(classes[i]) hasSuffix:suffix]) { found = classes[i]; break; }
    }
    free(classes); return found;
}
BOOL PXWindowMemoryInstall(Class panel,Class bridge,Class hostController) {
    if (!NSThread.isMainThread) return NO;
    if (PXWMOriginalOpen && PXWMOriginalMove && PXWMOriginalResize && PXWMOriginalLayout &&
        PXWMOriginalClose && PXWMOriginalControllerLayout) return YES;
    PXWindowMemoryStore *store = PXWindowMemoryStore.shared;
    PXWMCardClass = PXWMVendorClass(@"PXHostCard");
    if (!hostController) hostController = PXWMVendorClass(@"PXHostViewController");
    NSArray *objects = @[@"@"];
    SEL move = NSSelectorFromString(@"moveHost:");
    SEL resize = NSSelectorFromString(@"resizeHost:");
    SEL open = NSSelectorFromString(@"openApplication:inView:keyboardOverlay:completion:");
    SEL layout = NSSelectorFromString(@"layoutHost");
    SEL close = NSSelectorFromString(@"close");
    SEL controllerLayout = @selector(viewDidLayoutSubviews);
    if (!PXWMCardClass || !PXCloneClassInstanceMethodMatches(panel,move,@encode(void),objects) ||
        !PXCloneClassInstanceMethodMatches(panel,resize,@encode(void),objects) ||
        !PXCloneClassInstanceMethodMatches(bridge,open,@encode(void),@[@"@",@"@",@"@",@"@?"]) ||
        !PXCloneClassInstanceMethodMatches(bridge,layout,@encode(void),@[]) ||
        !PXCloneClassInstanceMethodMatches(bridge,close,@encode(void),@[]) ||
        !PXCloneClassInstanceMethodMatches(hostController,controllerLayout,@encode(void),@[])) return NO;
    if (!PXWMContexts) PXWMContexts = [NSHashTable weakObjectsHashTable];
#define PXWM_HOOK(klass,selector,replacement,target,type) \
    do { if (!(target)) { IMP saved = NULL; \
        if (PXCloneHookMessage(klass,selector,(IMP)replacement,&saved)) target = (type)saved; } } while(0)
    PXWM_HOOK(panel,move,PXWMMove,PXWMOriginalMove,void (*)(id,SEL,id));
    PXWM_HOOK(panel,resize,PXWMResize,PXWMOriginalResize,void (*)(id,SEL,id));
    PXWM_HOOK(bridge,open,PXWMOpen,PXWMOriginalOpen,void (*)(id,SEL,id,id,id,void (^)(BOOL)));
    PXWM_HOOK(bridge,layout,PXWMLayout,PXWMOriginalLayout,void (*)(id,SEL));
    PXWM_HOOK(bridge,close,PXWMClose,PXWMOriginalClose,void (*)(id,SEL));
    PXWM_HOOK(hostController,controllerLayout,PXWMControllerLayout,PXWMOriginalControllerLayout,void (*)(id,SEL));
#undef PXWM_HOOK
    if (!PXWMNotifying) {
        PXWMNotifying = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:PXWindowMemoryDidLoadNotification object:store
              queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            [store diagnostic:@"runtime_snapshot_received" details:@{@"loaded":@(store.isLoaded),
                       @"revision":store.snapshot[@"revision"] ?: @0}];
            for (PXWMContext *context in PXWMContexts.allObjects) PXWMTryRestore(context);
        }];
    }
    BOOL ready = PXWMOriginalOpen && PXWMOriginalMove && PXWMOriginalResize && PXWMOriginalLayout &&
                 PXWMOriginalClose && PXWMOriginalControllerLayout;
    [store diagnostic:@"hook_status" details:@{@"ready":@(ready)}];
    return ready;
}
