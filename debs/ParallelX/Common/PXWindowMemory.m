#import "PXWindowMemory.h"
#import "PXWindowMemoryStore.h"
#import "PXCloneRuntime.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

typedef NS_ENUM(unsigned, PXWMGeometryGate) {
    PXWMGateUnknown = 0, PXWMGateBinding, PXWMGateView, PXWMGateScene,
    PXWMGateTransient, PXWMGateReference, PXWMGateReady,
};

@interface PXWMContext : NSObject {
@public
    PXWMNativeLifecycle native;
}
@property(nonatomic, weak) id bridge;
@property(nonatomic, weak) UIView *canvas;
@property(nonatomic, weak) UIView *card;
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL interacting;
@property(nonatomic) BOOL savePending;
@property(nonatomic) PXWMRect initialTarget;
@property(nonatomic) PXWMRect initialNativeFrame;
@property(nonatomic) BOOL initialTargetActive;
@property(nonatomic) unsigned initialTargetKey;
@property(nonatomic) uint64_t initialTargetEpoch;
@property(nonatomic) CFTimeInterval initialTargetDeadline;
@property(nonatomic) BOOL initialContentRefreshed;
@property(nonatomic) BOOL initialFrameSubstituted;
@property(nonatomic) BOOL restoring;
@property(nonatomic) BOOL resolved;
@property(nonatomic) BOOL keyKnown;
@property(nonatomic) unsigned key;
@property(nonatomic) unsigned geometryGate;
@property(nonatomic) NSUInteger restoreRetryAttempts;
@property(nonatomic) BOOL restoreRetryScheduled;
@property(nonatomic) unsigned restoreRetryLoggedGate;
@property(nonatomic) CFTimeInterval openedAt;
@end
@implementation PXWMContext
@end

@interface PXWMGesture : NSObject
@property(nonatomic, weak) PXWMContext *context;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger samples;
@property(nonatomic) uint64_t epoch;
@property(nonatomic) unsigned orientation;
@property(nonatomic) BOOL orientationKnown;
@end
@implementation PXWMGesture
@end

static const void *PXWMContextKey = &PXWMContextKey;
static const void *PXWMOpenTicketKey = &PXWMOpenTicketKey;
static const void *PXWMGestureKey = &PXWMGestureKey;
static uint64_t PXWMNextSerial;
static NSHashTable<PXWMContext *> *PXWMContexts;
static Class PXWMCardClass;
static BOOL PXWMForegroundNotifying;
static BOOL PXWMLoadNotifying;
static void (*PXWMOriginalOpen)(id, SEL, id, id, id, void (^)(BOOL));
static void (*PXWMOriginalClose)(id, SEL);
static void (*PXWMOriginalLayout)(id, SEL);
static void (*PXWMOriginalMove)(id, SEL, id);
static void (*PXWMOriginalResize)(id, SEL, id);
static void (*PXWMOriginalControllerLayout)(id, SEL);
static void (*PXWMOriginalCardSetFrame)(id, SEL, CGRect);
static void PXWMScheduleRestore(PXWMContext *context);
static void PXWMScheduleInitialSettle(PXWMContext *context);

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
        state[@"openSerial"] = @(context->native.serial);
        state[@"orientation"] = @(context.key);
        if (context.openedAt > 0)
            state[@"elapsedMs"] = @((unsigned long long)(1000 * (CACurrentMediaTime() - context.openedAt)));
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

static BOOL PXWMBindingIsActive(PXWMContext *context) {
    id bridge = context.bridge;
    return context && bridge && objc_getAssociatedObject(bridge, PXWMContextKey) == context &&
           !objc_getAssociatedObject(bridge, PXWMOpenTicketKey) &&
           PXWMNativeBindingActive(&context->native, context->native.serial);
}

/* The host UIWindow covers the display; native resizing changes its inner
 * PXHostCard, not the display-filling window or the hosted content transform. */
static BOOL PXWMReadGeometry(PXWMContext *context, BOOL preparingInitialLayout,
                             PXWMGeometry *out, unsigned *key) {
    BOOL active = PXWMBindingIsActive(context);
    BOOL currentTicket = context && context.bridge &&
        objc_getAssociatedObject(context.bridge, PXWMOpenTicketKey) == context;
    BOOL entering = currentTicket && context->native.entering &&
        context->native.initialCleanupSeen && !context->native.cancelled;
    if (!active && !(preparingInitialLayout && entering)) {
        context.geometryGate = PXWMGateBinding; return NO;
    }
    UIView *canvas = context.canvas;
    UIView *card = PXWMFindCard(canvas);
    UIWindow *window = card.window;
    context.geometryGate = PXWMGateView;
    if (!card || !canvas || !window || !card.superview || window.screen != UIScreen.mainScreen) return NO;
    // A new host has valid geometry while its window is still hidden. Requiring
    // visibility here used to postpone memory until AFTER the default appeared.
    if (!preparingInitialLayout) {
        if (window.hidden || window.alpha <= 0.1) return NO;
        for (UIView *view = card; view; view = view.superview)
            if (view.hidden || view.alpha <= 0.1) return NO;
    }
    context.geometryGate = PXWMGateScene;
    if (PXWMObject(context.bridge, @"canvas") != canvas ||
        ![PXWMObject(context.bridge, @"bundleID") isEqual:context.bundle]) return NO;
    if (!preparingInitialLayout && (!canvas.userInteractionEnabled ||
        !PXWMObject(context.bridge, @"scene") || !PXWMBool(context.bridge, @"hasHostedSurface"))) return NO;
    context.geometryGate = PXWMGateTransient;
    if (!CGAffineTransformIsIdentity(card.transform) || PXWMBool(context.bridge, @"fullscreenHandoff") ||
        PXWMBool(context.bridge, @"isHostedKeyboardVisible")) return NO;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGSize host = window.bounds.size;
    context.geometryGate = PXWMGateReference;
    /* Reject separate dock/icon windows. Rotation can exchange the axes. */
    if (fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
        fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3) return NO;
    CGRect reference = CGRectIntersection(card.superview.bounds,
                        [window convertRect:window.bounds toView:card.superview]);
    /* Native root controllers can rotate their coordinate space while the
     * UIWindow stays portrait. Use the card's reference axes, not screen axes. */
    CGSize content = CGSizeZero;
    SEL source = NSSelectorFromString(@"hostedSourceSize");
    if (PXCloneInstanceMethodMatches(context.bridge, source, @encode(CGSize), @[])) {
        @try { content = ((CGSize (*)(id,SEL))objc_msgSend)(context.bridge, source); }
        @catch (__unused NSException *exception) { return NO; }
    } else if (!preparingInitialLayout) {
        content = canvas.bounds.size;
    }
    // Initial restore never guesses content axes from a still-default canvas.
    // alpha437's hostedSourceSize forwards to its real sourceSize, cleared by close.
    if (!isfinite(content.width) || !isfinite(content.height) || content.width <= 0 || content.height <= 0) return NO;
    PXWMGeometry geometry = {PXWMFromRect(card.frame), PXWMFromRect(reference)};
    if (!PXWMValidGeometry(geometry)) return NO;
    context.geometryGate = PXWMGateReady;
    context.card = card;
    if (out) *out = geometry;
    if (key) *key = PXWMOrientationKey(reference.size.width > reference.size.height,
                                      content.width > content.height);
    return YES;
}

static BOOL PXWMNormalGeometry(PXWMContext *context, PXWMGeometry *out, unsigned *key) {
    return PXWMReadGeometry(context, NO, out, key);
}

static void PXWMVerifyRestore(PXWMContext *context, PXWMRect restored, unsigned key, uint64_t epoch) {
    NSUInteger expectedGeneration = context.generation;
    __weak PXWMContext *weakContext = context;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        PXWMContext *check = weakContext;
        if (!PXWMBindingIsActive(check) || check.generation != expectedGeneration ||
            check.interacting || check.savePending || check.key != key ||
            [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue] != epoch) return;
        PXWMGeometry later;
        unsigned laterKey = 0;
        BOOL normal = PXWMNormalGeometry(check, &later, &laterKey);
        BOOL stable = normal && laterKey == key && fabs(later.frame.x-restored.x)<1 &&
            fabs(later.frame.y-restored.y)<1 && fabs(later.frame.width-restored.width)<1 &&
            fabs(later.frame.height-restored.height)<1;
        PXWMLog(check, !normal ? @"restore_postlayout_geometry_pending" :
                (stable ? @"restore_postlayout_geometry_verified" : @"restore_postlayout_geometry_changed"),
                @{@"normal":@(normal),@"matches":@(stable),@"gate":@(check.geometryGate)});
    });
}

/* The vendor's open sequence assigns hostCard's default frame again inside its
 * reveal animation, after our first prepare. Redirect only that opening write
 * to the remembered frame, so the first visible frame is already the saved one.
 * Bounded by a 2s deadline and cleared on user touch, close, or a key change. */
static void PXWMCardSetFrame(id self, SEL command, CGRect frame) {
    if (PXWMOriginalCardSetFrame) {
        if (NSThread.isMainThread && PXWMContexts) {
            PXWMContext *context = nil;
            for (PXWMContext *candidate in PXWMContexts.allObjects) {
                if (candidate.card == (UIView *)self) { context = candidate; break; }
            }
            if (context && context.initialTargetActive && !context.restoring && !context.interacting &&
                !context.savePending && CACurrentMediaTime() < context.initialTargetDeadline) {
                CGRect target = PXWMToRect(context.initialTarget);
                CGRect native = PXWMToRect(context.initialNativeFrame);
                BOOL sameNative = fabs(frame.origin.x-native.origin.x)<0.5 &&
                    fabs(frame.origin.y-native.origin.y)<0.5 && fabs(frame.size.width-native.size.width)<0.5 &&
                    fabs(frame.size.height-native.size.height)<0.5;
                BOOL same = fabs(frame.origin.x-target.origin.x)<0.5 && fabs(frame.origin.y-target.origin.y)<0.5 &&
                    fabs(frame.size.width-target.size.width)<0.5 && fabs(frame.size.height-target.size.height)<0.5;
                if (sameNative && !same) {
                    if (!context.initialFrameSubstituted) {
                        context.initialFrameSubstituted = YES;
                        PXWMLog(context, @"restore_initial_frame_substituted",
                                @{ @"fromW":@(frame.size.width), @"fromH":@(frame.size.height),
                                   @"toW":@(target.size.width), @"toH":@(target.size.height) });
                    }
                    frame = target;
                }
            }
        }
        PXWMOriginalCardSetFrame(self, command, frame);
    }
}

/* One settle pass after the reveal animation ends: if the vendor animation still
 * forced a different frame, set the saved frame without animation; then run the
 * original layoutHost once so hosted content is measured against the real size.
 * No repeating timers, no frame polling, no content transform editing. */
static void PXWMScheduleInitialSettle(PXWMContext *context) {
    __weak PXWMContext *weakContext = context;
    unsigned key = context.initialTargetKey;
    uint64_t epoch = context.initialTargetEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,900*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        PXWMContext *current = weakContext;
        if (!current || !current.initialTargetActive) return;
        current.initialTargetActive = NO;
        if (!PXWMBindingIsActive(current) || current.interacting || current.savePending ||
            !current.keyKnown || current.key != key || !current.card) return;
        if ([PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue] != epoch) return;
        UIView *card = current.card;
        CGRect target = PXWMToRect(current.initialTarget);
        CGRect native = PXWMToRect(current.initialNativeFrame);
        CGRect actual = card.frame;
        BOOL matches = fabs(actual.origin.x-target.origin.x)<1 && fabs(actual.origin.y-target.origin.y)<1 &&
            fabs(actual.size.width-target.size.width)<1 && fabs(actual.size.height-target.size.height)<1;
        BOOL nativeDefault = fabs(actual.origin.x-native.origin.x)<1 && fabs(actual.origin.y-native.origin.y)<1 &&
            fabs(actual.size.width-native.size.width)<1 && fabs(actual.size.height-native.size.height)<1;
        if (!matches && !nativeDefault) {
            PXWMLog(current, @"restore_initial_settle_skipped_native_change",
                    @{@"actualW":@(actual.size.width), @"actualH":@(actual.size.height)});
            return;
        }
        if (!matches) {
            current.restoring = YES;
            [UIView performWithoutAnimation:^{
                card.frame = target;
                [card setNeedsLayout]; [card layoutIfNeeded];
            }];
            current.restoring = NO;
            CGRect settled = card.frame;
            PXWMLog(current, @"restore_initial_geometry_settled",
                    @{ @"fromW":@(actual.size.width), @"fromH":@(actual.size.height),
                       @"toW":@(settled.size.width), @"toH":@(settled.size.height),
                       @"substituted":@(current.initialFrameSubstituted) });
        }
        if (!current.initialContentRefreshed && current.bridge && PXWMOriginalLayout) {
            current.initialContentRefreshed = YES;
            PXWMOriginalLayout(current.bridge, NSSelectorFromString(@"layoutHost"));
            PXWMLog(current, @"restore_initial_content_refreshed",
                    @{ @"substituted":@(current.initialFrameSubstituted) });
        }
    });
}

/* Native layoutHost already has the true sourceSize, before it fits hosted
 * content. Prepare its outer hostCard here, not after scene visibility. Keep
 * the original layout call and its animations; never hide a window or edit a
 * hosted content transform to disguise a late correction. */
static BOOL PXWMPrepareInitialLayout(PXWMContext *context) {
    if (!context || context.restoring) return NO;
    id bridge = context.bridge;
    BOOL currentTicket = bridge && objc_getAssociatedObject(bridge, PXWMOpenTicketKey) == context;
    BOOL matching = bridge && context.canvas && PXWMObject(bridge, @"canvas") == context.canvas &&
        [PXWMObject(bridge, @"bundleID") isEqual:context.bundle];
    PXWindowMemoryStore *store = PXWindowMemoryStore.shared;
    NSDictionary *snapshot = store.snapshot;
    if (!PXWMMayPrepareInitialLayout(PXWMBindingIsActive(context), currentTicket,
          context->native.entering, context->native.initialCleanupSeen, context->native.cancelled,
          matching, store.isLoaded, [snapshot[@"enabled"] boolValue], context.resolved,
          context.interacting, context.savePending)) return NO;
    PXWMGeometry native, saved;
    unsigned key = 0;
    if (!PXWMReadGeometry(context, YES, &native, &key) ||
        !PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved)) return NO;
    PXWMRect restored;
    if (!PXWMRestore(saved, native.reference, native.frame, &restored)) return NO;
    UIView *card = context.card;
    context.restoring = YES;
    [UIView performWithoutAnimation:^{
        card.frame = PXWMToRect(restored);
        [card setNeedsLayout]; [card layoutIfNeeded];
    }];
    context.restoring = NO;
    CGRect actual = card.frame;
    BOOL matched = fabs(actual.origin.x-restored.x)<1 && fabs(actual.origin.y-restored.y)<1 &&
        fabs(actual.size.width-restored.width)<1 && fabs(actual.size.height-restored.height)<1;
    if (matched) {
        context.key = key;
        context.keyKnown = YES;
        context.resolved = YES;
        context.initialTarget = restored;
        context.initialNativeFrame = native.frame;
        context.initialTargetKey = key;
        context.initialTargetEpoch = [snapshot[@"epoch"] unsignedLongLongValue];
        context.initialTargetDeadline = CACurrentMediaTime() + 2.0;
        context.initialTargetActive = YES;
        context.initialContentRefreshed = NO;
        context.initialFrameSubstituted = NO;
        PXWMScheduleInitialSettle(context);
    }
    PXWMLog(context, matched ? @"restore_initial_geometry_prepared" : @"restore_initial_geometry_rejected",
            @{@"x":@(actual.origin.x),@"y":@(actual.origin.y),@"w":@(actual.size.width),@"h":@(actual.size.height),
              @"beforeW":@(native.frame.width),@"beforeH":@(native.frame.height),
              @"expectedW":@(restored.width),@"expectedH":@(restored.height),
              @"windowHidden":@(card.window.hidden),@"surface":@(PXWMBool(bridge,@"hasHostedSurface")),
              @"nativeEntering":@(context->native.entering),@"revision":snapshot[@"revision"] ?: @0});
    if (matched) PXWMVerifyRestore(context, restored, key, [snapshot[@"epoch"] unsignedLongLongValue]);
    return matched;
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
               @"beforeW":@(native.frame.width), @"beforeH":@(native.frame.height),
               @"windowHidden":@(card.window.hidden),
               @"revision":snapshot[@"revision"] ?: @0, @"surface":@(PXWMBool(context.bridge,@"hasHostedSurface")) });
    PXWMVerifyRestore(context, restored, key, [snapshot[@"epoch"] unsignedLongLongValue]);
}

/* Geometry may not have a live scene/hostedSurface at the instant the user
 * begins resizing the just-opened window. Direction is a weaker fact than
 * permission to save: derive only host/content axes from the visible view tree,
 * then the normal full gate revalidates those axes and the frame at gesture end. */
static BOOL PXWMCaptureGestureOrientation(PXWMContext *context, unsigned *key) {
    if (!PXWMBindingIsActive(context) || !context.canvas.userInteractionEnabled) return NO;
    UIView *canvas = context.canvas;
    UIView *card = PXWMFindCard(canvas);
    UIWindow *window = canvas.window;
    if (!card || !window || !card.superview || window.screen != UIScreen.mainScreen ||
        window.hidden || window.alpha <= 0.1 || !CGAffineTransformIsIdentity(card.transform)) return NO;
    for (UIView *view = card; view; view = view.superview)
        if (view.hidden || view.alpha <= 0.1) return NO;
    UIView *parent = card.superview;
    CGRect visibleHost = CGRectIntersection(parent.bounds, [window convertRect:window.bounds toView:parent]);
    if (CGRectIsEmpty(visibleHost) || CGRectIsNull(visibleHost)) return NO;
    CGSize content = canvas.bounds.size;
    SEL source = NSSelectorFromString(@"hostedSourceSize");
    if (PXCloneInstanceMethodMatches(context.bridge, source, @encode(CGSize), @[])) {
        @try { content = ((CGSize (*)(id, SEL))objc_msgSend)(context.bridge, source); }
        @catch (__unused NSException *exception) { return NO; }
    }
    if (!isfinite(content.width) || !isfinite(content.height) || content.width <= 0 || content.height <= 0) return NO;
    if (key) *key = PXWMOrientationKey(visibleHost.size.width > visibleHost.size.height,
                                      content.width > content.height);
    return YES;
}

static PXWMContext *PXWMContextForGesture(UIGestureRecognizer *gesture) {
    UIWindow *window = gesture.view.window;
    if (!window) return nil;
    PXWMContext *match = nil;
    for (PXWMContext *context in PXWMContexts.allObjects) {
        if (!PXWMBindingIsActive(context) || context.canvas.window != window || !PXWMFindCard(context.canvas)) continue;
        if (match) return nil; // Never write one panel's geometry to an ambiguous window.
        match = context;
    }
    return match;
}

static void PXWMSettleSave(PXWMGesture *stamp, NSUInteger attempt) {
    PXWMContext *context = stamp.context;
    if (!PXWMBindingIsActive(context) || stamp.generation != context.generation || context.interacting) return;
    PXWMGeometry geometry;
    unsigned key = 0;
    UIView *card = PXWMFindCard(context.canvas);
    // A geometry animation may still be showing a preview. Unrelated opacity
    // and shadow animations do not prevent reading the settled frame.
    CALayer *presentation = card.layer.presentationLayer;
    CGRect modelFrame = card.layer.frame;
    CGRect shownFrame = presentation ? presentation.frame : modelFrame;
    BOOL animation = presentation && card.layer.animationKeys.count > 0 &&
        (fabs(modelFrame.origin.x - shownFrame.origin.x) >= 1 ||
         fabs(modelFrame.origin.y - shownFrame.origin.y) >= 1 ||
         fabs(modelFrame.size.width - shownFrame.size.width) >= 1 ||
         fabs(modelFrame.size.height - shownFrame.size.height) >= 1);
    if (animation && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            PXWMSettleSave(stamp, attempt+1);
        }); return;
    }
    BOOL normal = PXWMNormalGeometry(context, &geometry, &key);
    if (PXWMMayWaitForGestureGeometry(normal, stamp.samples, 30)) {
        stamp.samples++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            PXWMSettleSave(stamp,attempt);
        });
        return; // keep savePending set so a late restore cannot overwrite the user
    }
    if (!normal) {
        context.savePending = NO;
        PXWMLog(context, @"save_skipped_non_normal_or_reset", @{ @"gate":@(context.geometryGate), @"samples":@(stamp.samples) });
        return;
    }
    BOOL orientationKnown = stamp.orientationKnown;
    unsigned orientation = stamp.orientation;
    BOOL orientationResolved = PXWMResolveGestureOrientation(YES, &orientationKnown, &orientation, key);
    stamp.orientationKnown = orientationKnown;
    stamp.orientation = orientation;
    if (!orientationResolved) {
        context.savePending = NO;
        PXWMLog(context, @"save_skipped_direction_change", @{ @"known":@(orientationKnown), @"started":@(orientation), @"current":@(key) });
        return;
    }
    if (!PXWMMayStoreGesture(stamp.orientationKnown, stamp.orientation, key,
                              stamp.generation, context.generation, NO) ||
        !PXWMMayCommitGesture(stamp.orientationKnown, stamp.orientation, key,
                              stamp.generation, context.generation)) {
        context.savePending = NO;
        PXWMLog(context, @"save_skipped_direction_change", @{ @"known":@(stamp.orientationKnown),
                   @"started":@(stamp.orientation), @"current":@(key), @"samples":@(stamp.samples) });
        return;
    }
    context.savePending = NO;
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (!PXWMMaySave([snapshot[@"enabled"] boolValue], stamp.epoch,
                    [snapshot[@"epoch"] unsignedLongLongValue], !animation, normal, YES)) {
        PXWMLog(context, @"save_skipped_non_normal_or_reset", @{@"gate":@(context.geometryGate),
                   @"normal":@(normal), @"animation":@(animation), @"epoch":@(stamp.epoch),
                   @"currentEpoch":snapshot[@"epoch"] ?: @0}); return;
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
            context.initialTargetActive = NO;
            PXWMGesture *stamp = [PXWMGesture new];
            stamp.context = context; stamp.generation = context.generation;
            stamp.epoch = [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue];
            unsigned startingKey = 0;
            stamp.orientationKnown = PXWMCaptureGestureOrientation(context, &startingKey);
            stamp.orientation = startingKey;
            if (stamp.orientationKnown) { context.keyKnown = YES; context.key = startingKey; }
            objc_setAssociatedObject(gesture,PXWMGestureKey,stamp,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PXWMLog(context, @"gesture_begin", @{@"resize":@(command == NSSelectorFromString(@"resizeHost:")),
                     @"geometryKnown":@(stamp.orientationKnown), @"gate":@(context.geometryGate)});
        } else {
            PXWMLog(nil, @"gesture_no_bound_window", @{@"resize":@(command == NSSelectorFromString(@"resizeHost:"))});
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
static PXWMContext *PXWMDetachBinding(id bridge) {
    PXWMContext *context = objc_getAssociatedObject(bridge, PXWMContextKey);
    if (context) {
        PXWMNativeClose(&context->native);
        context.generation++;
        context.initialTargetActive = NO;
        objc_setAssociatedObject(bridge, PXWMContextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return context;
}

static void PXWMOpen(id self,SEL command,id bundle,id canvas,id overlay,void (^completion)(BOOL)) {
    if (!PXWMOriginalOpen) return;
    if (!NSThread.isMainThread) {
        PXWMOriginalOpen(self,command,bundle,canvas,overlay,completion);
        return;
    }
    // The bridge closes the previous scene synchronously before assigning the
    // incoming canvas. Until the native call returns, track only a ticket.
    // If native rejects the request without closing, leave the old binding alone.
    PXWMContext *superseded = objc_getAssociatedObject(self, PXWMOpenTicketKey);
    if (superseded) superseded->native.cancelled = true;
    PXWMContext *ticket = nil;
    if ([bundle isKindOfClass:NSString.class] && [bundle length] && [canvas isKindOfClass:UIView.class]) {
        ticket = [PXWMContext new];
        ticket.openedAt = CACurrentMediaTime();
        ticket.bridge = self; ticket.canvas = canvas; ticket.bundle = bundle;
        if (++PXWMNextSerial == 0) ++PXWMNextSerial;
        PXWMNativeBegin(&ticket->native, PXWMNextSerial);
        PXWMLog(ticket, @"native_open_observed", @{});
    }
    objc_setAssociatedObject(self, PXWMOpenTicketKey, ticket, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (^forwardCompletion)(BOOL) = completion;
    if (ticket && completion) {
        void (^nativeCompletion)(BOOL) = [completion copy];
        forwardCompletion = ^(BOOL ok) {
            @try {
                PXWMContext *current = objc_getAssociatedObject(self, PXWMContextKey) ?: ticket;
                if (NSThread.isMainThread) {
                    PXWMPrepareInitialLayout(current);
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{ PXWMPrepareInitialLayout(current); });
                }
            } @catch (__unused NSException *exception) {
                PXWMLog(ticket, @"restore_initial_geometry_exception", @{});
            }
            nativeCompletion(ok);
        };
    }
    BOOL returnedNormally = NO;
    @try {
        PXWMOriginalOpen(self,command,bundle,canvas,overlay,forwardCompletion);
        returnedNormally = YES;
    } @finally {
        if (ticket) {
            BOOL current = objc_getAssociatedObject(self, PXWMOpenTicketKey) == ticket;
            if (current) objc_setAssociatedObject(self, PXWMOpenTicketKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL matches = returnedNormally && current && PXWMObject(self, @"canvas") == canvas &&
                           [PXWMObject(self, @"bundleID") isEqual:ticket.bundle];
            if (PXWMNativeReturned(&ticket->native, current, matches, returnedNormally)) {
                objc_setAssociatedObject(self, PXWMContextKey, ticket, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [PXWMContexts addObject:ticket];
                PXWMLog(ticket, @"native_window_bound", @{});
            } else {
                PXWMLog(ticket, @"native_window_not_bound", @{@"current":@(current), @"matches":@(matches),
                        @"returned":@(returnedNormally), @"initialCleanup":@(ticket->native.initialCleanupSeen)});
            }
        }
    }
    BOOL knownSize = NO;
    if (ticket.bundle.length) {
        NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
        PXWMGeometry savedGeometry;
        knownSize = PXWindowMemoryGeometry(snapshot, ticket.bundle, 0, &savedGeometry) ||
                    PXWindowMemoryGeometry(snapshot, ticket.bundle, 1, &savedGeometry) ||
                    PXWindowMemoryGeometry(snapshot, ticket.bundle, 2, &savedGeometry) ||
                    PXWindowMemoryGeometry(snapshot, ticket.bundle, 3, &savedGeometry);
    }
    PXWMLog(ticket, knownSize ? @"native_window_bound_with_memory" : @"native_window_bound_default",
            @{@"memoryLoaded":@(PXWindowMemoryStore.shared.isLoaded)});
    BOOL geometryReady = PXWMNormalGeometry(ticket, NULL, NULL);
    if (!ticket.resolved) {
        if (geometryReady) PXWMTryRestore(ticket);
        if (!ticket.resolved) PXWMScheduleRestore(ticket);
    }
    __weak PXWMContext *weakContext = ticket;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        PXWMContext *pending = weakContext;
        if (PXWMBindingIsActive(pending) && !pending.resolved && !pending.interacting)
            PXWMLog(pending, @"restore_waiting_native_geometry", @{@"gate":@(pending.geometryGate),
                     @"attempts":@(pending.restoreRetryAttempts), @"loaded":@(PXWindowMemoryStore.shared.isLoaded)});
    });
}
static void PXWMLayout(id self,SEL command) {
    PXWMContext *context = nil;
    if (NSThread.isMainThread) {
        // The synchronous initial close must still run. Only the current
        // post-cleanup ticket can prepare geometry inside native open.
        context = objc_getAssociatedObject(self,PXWMOpenTicketKey) ?: objc_getAssociatedObject(self,PXWMContextKey);
        PXWMPrepareInitialLayout(context);
    }
    if (PXWMOriginalLayout) PXWMOriginalLayout(self,command);
    if (NSThread.isMainThread) {
        // Native layout establishes hostCard's default geometry and sourceSize.
        // Apply saved geometry now, before alpha437 returns to its reveal/centering
        // completion; otherwise the first visible frame can still be the default.
        if (context && context->native.entering)
            PXWMPrepareInitialLayout(context);
        PXWMTryRestore(context);
        if (context && !context.resolved) PXWMScheduleRestore(context);
    }
}
static void PXWMClose(id self,SEL command) {
    if (NSThread.isMainThread) {
        PXWMContext *ticket = objc_getAssociatedObject(self, PXWMOpenTicketKey);
        PXWMContext *context = PXWMDetachBinding(self);
        BOOL initial = ticket && PXWMNativeClose(&ticket->native);
        if (initial) PXWMLog(ticket, @"native_initial_cleanup_preserved", @{});
        else if (context || ticket)
            PXWMLog(context ?: ticket, @"native_close_no_transient_save", @{});
    }
    if (PXWMOriginalClose) PXWMOriginalClose(self,command);
}
static void PXWMControllerLayout(id self,SEL command) {
    if (PXWMOriginalControllerLayout) PXWMOriginalControllerLayout(self,command);
    if (!NSThread.isMainThread) return;
    UIWindow *window = [self isKindOfClass:UIViewController.class] ? [(UIViewController *)self view].window : nil;
    for (PXWMContext *context in PXWMContexts.allObjects) {
        if (!window || context.canvas.window != window) continue;
        PXWMTryRestore(context);
        if (!context.resolved) PXWMScheduleRestore(context);
    }
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
    PXWindowMemoryStore *store = PXWindowMemoryStore.shared;
    if (!PXWMForegroundNotifying) {
        PXWMForegroundNotifying = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            [store reload];
            [store diagnostic:@"springboard_foreground_reload" details:@{}];
        }];
    }
    if (PXWMOriginalOpen && PXWMOriginalMove && PXWMOriginalResize && PXWMOriginalLayout &&
        PXWMOriginalClose && PXWMOriginalControllerLayout) return YES;
    [store reload];
    PXWMCardClass = PXWMVendorClass(@"PXHostCard");
    if (!hostController) hostController = PXWMVendorClass(@"PXHostViewController");
    NSArray *objects = @[@"@"];
    SEL move = NSSelectorFromString(@"moveHost:");
    SEL resize = NSSelectorFromString(@"resizeHost:");
    SEL open = NSSelectorFromString(@"openApplication:inView:keyboardOverlay:completion:");
    SEL layout = NSSelectorFromString(@"layoutHost");
    SEL close = NSSelectorFromString(@"close");
    SEL controllerLayout = @selector(viewDidLayoutSubviews);
    SEL cardFrame = @selector(setFrame:);
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
    PXWM_HOOK(PXWMCardClass,cardFrame,PXWMCardSetFrame,PXWMOriginalCardSetFrame,void (*)(id,SEL,CGRect));
#undef PXWM_HOOK
    if (!PXWMLoadNotifying) {
        PXWMLoadNotifying = YES;
        [NSNotificationCenter.defaultCenter addObserverForName:PXWindowMemoryDidLoadNotification
              object:store
              queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            [store diagnostic:@"runtime_snapshot_received" details:@{@"loaded":@(store.isLoaded),
                       @"revision":store.snapshot[@"revision"] ?: @0}];
            for (PXWMContext *context in PXWMContexts.allObjects) {
                PXWMTryRestore(context);
                if (context && !context.resolved) PXWMScheduleRestore(context);
            }
        }];
    }
    BOOL ready = PXWMOriginalOpen && PXWMOriginalMove && PXWMOriginalResize && PXWMOriginalLayout &&
                 PXWMOriginalClose && PXWMOriginalControllerLayout;
    [store diagnostic:@"hook_status" details:@{@"ready":@(ready)}];
    return ready;
}

/* alpha437 can bind a valid app window before its source geometry is ready.
 * Retry only this geometry read for a bounded 10 seconds; no reopen, no
 * process termination, no window-frame polling loop and no user action is sent. */
static void PXWMScheduleRestore(PXWMContext *context) {
    const NSUInteger maxAttempts = 100;
    if (!context || !PXWMBindingIsActive(context) || context.resolved || context.interacting ||
        context.restoreRetryScheduled || context.restoreRetryAttempts >= maxAttempts ||
        !PXWindowMemoryStore.shared.isLoaded) return;
    context.restoreRetryAttempts++;
    NSUInteger attempt = context.restoreRetryAttempts;
    NSUInteger generation = context.generation;
    unsigned observedKey = context.key;
    BOOL keyKnown = context.keyKnown;
    context.restoreRetryScheduled = YES;
    if (PXWMShouldLogRestoreWait((unsigned)attempt, context.geometryGate, context.restoreRetryLoggedGate)) {
        context.restoreRetryLoggedGate = context.geometryGate;
        PXWMLog(context, @"restore_retry_scheduled", @{@"attempt":@(attempt),@"gate":@(context.geometryGate)});
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        context.restoreRetryScheduled = NO;
        if (!PXWMBindingIsActive(context) || context.generation != generation ||
            context.interacting || context.savePending || context.resolved) return;
        PXWMGeometry geometry;
        unsigned key = 0;
        if (!PXWMNormalGeometry(context,&geometry,&key)) {
            if (context.restoreRetryAttempts >= maxAttempts)
                PXWMLog(context,@"restore_retry_limit",@{@"attempt":@(attempt),@"gate":@(context.geometryGate)});
            else PXWMScheduleRestore(context);
            return;
        }
        if (keyKnown && key != observedKey) {
            context.key = key;
            context.keyKnown = YES;
            context.resolved = YES;
            PXWMLog(context,@"restore_retry_direction_changed",@{@"from":@(observedKey),@"to":@(key)});
            return;
        }
        context.key = key;
        context.keyKnown = YES;
        PXWMLog(context,@"restore_geometry_ready",@{@"attempt":@(attempt)});
        PXWMTryRestore(context);
    });
}
