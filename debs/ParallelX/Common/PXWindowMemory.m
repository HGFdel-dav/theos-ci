#import "PXWindowMemory.h"
#import "PXWindowMemoryStore.h"
#import "PXWindowContinuity.h"
#import "PXWindowDiagnosticPolicy.h"
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

@class PXWMGesture;
@interface PXWMContext : NSObject {
@public
    PXWMNativeLifecycle native;
    PXWMDiagnosticGate diagnosticGate;
    PXWMDiagnosticGate diagnosticIncidentGate;
}
@property(nonatomic, weak) id bridge;
@property(nonatomic, weak) UIView *canvas;
@property(nonatomic, weak) UIView *card;
@property(nonatomic, copy) NSString *bundle;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL interacting;
@property(nonatomic) BOOL savePending;
@property(nonatomic, strong) PXWMGesture *pendingGesture;
@property(nonatomic) PXWMRect initialTarget;
@property(nonatomic) PXWMRect initialNativeFrame;
@property(nonatomic) BOOL initialTargetAppliedAtBind;
@property(nonatomic, copy) NSString *probeSignature;
@property(nonatomic) CFTimeInterval diagnosticProbeTime;
@property(nonatomic) unsigned diagnosticProbeFlags;
@property(nonatomic) BOOL diagnosticProbeKnown;
@property(nonatomic) unsigned diagnosticProbeSuppressed;
@property(nonatomic) BOOL sourceSizeSeen;
@property(nonatomic) BOOL continuityActive;
@property(nonatomic) BOOL continuityMove;
@property(nonatomic) BOOL continuitySyncing;
@property(nonatomic) BOOL continuityScheduled;
@property(nonatomic) NSUInteger continuityScheduleGeneration;
@property(nonatomic, copy) NSString *continuitySyncKey;
@property(nonatomic) NSUInteger continuitySyncAttempts;
@property(nonatomic) NSUInteger continuityBudgetGeneration;
@property(nonatomic) NSUInteger continuityBudgetAttempts;
@property(nonatomic) NSUInteger continuityFrameReports;
@property(nonatomic) NSUInteger continuityGeneration;
@property(nonatomic) uint64_t continuityEpoch;
@property(nonatomic) unsigned continuityKey;
@property(nonatomic) PXWMGeometry continuityGeometry;
@property(nonatomic) BOOL initialTargetActive;
@property(nonatomic) unsigned initialTargetKey;
@property(nonatomic) uint64_t initialTargetEpoch;
@property(nonatomic) CFTimeInterval initialTargetDeadline;
@property(nonatomic) BOOL initialContentRefreshed;
@property(nonatomic) BOOL initialFrameSubstituted;
@property(nonatomic) BOOL initialPreparationWaitLogged;
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
@property(nonatomic) BOOL resizing;
@property(nonatomic) BOOL startingSizeKnown;
@property(nonatomic) PXWMRect startingFrame;
@end
@implementation PXWMGesture
@end

@interface PXWMExpansion : NSObject
@property(nonatomic, weak) PXWMContext *context;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) uint64_t epoch;
@property(nonatomic) BOOL applied;
@end
@implementation PXWMExpansion
@end

static NSArray<PXWMExpansion *> *PXWMExpansionScope;
static void (*PXWMOriginalRestoreDockTapped)(id, SEL, id);
static void (*PXWMOriginalExternalOpen)(id, SEL, id);
static void (*PXWMOriginalDockTapped)(id, SEL, id);
static void (*PXWMOriginalBottomDoubleTapped)(id, SEL);
static void (*PXWMOriginalBottomHeld)(id, SEL, id);
static BOOL (*PXWMOriginalConfiguredAction)(id, SEL, id);
static BOOL (*PXWMOriginalConfiguredActionSearch)(id, SEL, id, BOOL);

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
static id (*PXWMOriginalCardInit)(id, SEL, CGRect);
static void (*PXWMOriginalSetSourceSize)(id, SEL, CGSize);
static void PXWMScheduleRestore(PXWMContext *context);
static void PXWMQueueContentSync(PXWMContext *context);
static void PXWMProbeContentGeometry(PXWMContext *context, unsigned stage);
static void PXWMScheduleInitialSettle(PXWMContext *context);
static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,
                                                   const PXWMRect *nativeFrameOverride,
                                                   BOOL allowingVisibleTicket);

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
        NSDictionary *snapshot=PXWindowMemoryStore.shared.snapshot;
        state[@"epoch"] = state[@"epoch"] ?: snapshot[@"epoch"] ?: @0;
        state[@"revision"] = state[@"revision"] ?: snapshot[@"revision"] ?: @0;
        state[@"monotonicMs"] = @((uint64_t)(CACurrentMediaTime()*1000));
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

static BOOL PXWMOpeningTicketOwnsCanvas(PXWMContext *context, UIView *canvas) {
    return context && canvas && context.bridge && context.canvas == canvas &&
           context->native.entering && context->native.initialCleanupSeen &&
           !context->native.cancelled &&
           objc_getAssociatedObject(context.bridge, PXWMOpenTicketKey) == context &&
           context.bundle.length > 0;
}

/* A newly bound context still owns the first native frame until either the
 * initial target is prepared or a user/native lifecycle transition advances
 * its generation. This covers the handoff where native open has returned but
 * the first PXHostCard frame is written just afterwards. It is deliberately
 * limited to generation zero and never applies to an ordinary resize/layout. */
static BOOL PXWMInitialFrameMayPrepare(PXWMContext *context) {
    return context && PXWMInitialHandoffEligible((uint64_t)context->native.serial,
        context->native.initialCleanupSeen, context->native.cancelled,
        (uint64_t)context.generation, context.resolved, context.interacting,
        context.savePending, context->native.entering, context->native.bound);
}

/* The bridge republishes canvas/bundle for the incoming scene at some point
 * AFTER the native open returns (measured: still mismatched a few ms after a
 * successful exact-match bind). The window's own view tree stays authoritative:
 * the card about to be framed is the card captured when the binding was
 * confirmed, or an ancestor of the canvas this opening ticket received. Both
 * are limited to the unresolved generation-zero window of one open; an ordinary
 * resize/layout never satisfies them. */
static BOOL PXWMInitialHandoffOwnsCard(PXWMContext *context, UIView *card) {
    if (!PXWMInitialFrameMayPrepare(context) || !card) return NO;
    if (context.card == card) return YES;
    return context.canvas != nil && PXWMFindCard(context.canvas) == card;
}

/* Diagnostics must stay content-free: only nil/same/different, never a name. */
enum { PXWMLinkNil = 0, PXWMLinkSame = 1, PXWMLinkDifferent = 2 };
static unsigned PXWMLinkState(id observed, id expected) {
    if (!observed) return PXWMLinkNil;
    return observed == expected ? PXWMLinkSame : PXWMLinkDifferent;
}
static unsigned PXWMIdentityState(id observed, id expected) {
    if (!observed) return PXWMLinkNil;
    return [observed isEqual:expected] ? PXWMLinkSame : PXWMLinkDifferent;
}

/* The card being created right now is the earliest owner of the default frame.
 * Only claim it for the one unresolved opening ticket; several pending opens
 * must never be disambiguated by a guess. */
static PXWMContext *PXWMPendingInitialCardContext(void) {
    if (!NSThread.isMainThread || !PXWMContexts) return nil;
    PXWMContext *found = nil;
    for (PXWMContext *candidate in PXWMContexts.allObjects) {
        if (!PXWMInitialFrameMayPrepare(candidate) || candidate.card) continue;
        if (found) return nil; // Ambiguous: leave the original frame untouched.
        found = candidate;
    }
    return found;
}

/* Use a remembered frame at card creation only when it was recorded for the
 * screen we are on now; a different reference size is reconciled later. */
static BOOL PXWMInitialCardSavedFrame(PXWMContext *context, PXWMRect *target, unsigned *outKey) {
    if (!context || !target) return NO;
    PXWindowMemoryStore *store = PXWindowMemoryStore.shared;
    if (!store.isLoaded) return NO;
    NSDictionary *snapshot = store.snapshot;
    if (![snapshot[@"enabled"] boolValue]) return NO;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    for (unsigned key = 0; key < 4; key++) {
        PXWMGeometry saved;
        if (!PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved)) continue;
        if (!PXWMInitialCardFrameUsable(YES, true, saved.reference.width, saved.reference.height,
                                        screen.width, screen.height)) continue;
        if (!PXWMValidRect(saved.frame)) continue;
        *target = saved.frame;
        if (outKey) *outKey = key;
        return YES;
    }
    return NO;
}

/* During the synchronous native open, the bridge can still expose the previous
 * canvas/bundle for a short handoff window. The ticket already owns the
 * incoming canvas and the previous scene cleanup has completed, so this is a
 * narrower fact than a normal bound-context match. Never use it after the
 * ticket has left the entering state. */
static BOOL PXWMTicketMayUseIncomingAssociation(PXWMContext *context, BOOL preparingInitialLayout) {
    return preparingInitialLayout && PXWMOpeningTicketOwnsCanvas(context, context.canvas);
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
                             const PXWMRect *nativeFrameOverride, PXWMGeometry *out, unsigned *key) {
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
    if (card) context.card = card;
    /* Only the first-open handoff may fall back to the card captured at bind. */
    else if (preparingInitialLayout && PXWMInitialFrameMayPrepare(context)) card = context.card;
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
    id bridgeBundle = PXWMObject(context.bridge, @"bundleID");
    BOOL bridgeCanvasMatches = PXWMObject(context.bridge, @"canvas") == canvas;
    BOOL bundleMatches = [bridgeBundle isEqual:context.bundle] || bridgeBundle == nil;
    BOOL ticketOwnsIncoming = PXWMTicketMayUseIncomingAssociation(context, preparingInitialLayout) && bundleMatches;
    /* A republished bridge canvas no longer identifies the incoming scene, but
     * the card we are about to frame still does. Never accept a foreign bundle. */
    BOOL handoffOwnsCard = preparingInitialLayout && bundleMatches &&
        PXWMInitialHandoffOwnsCard(context, card);
    if ((!bridgeCanvasMatches || !bundleMatches) && !ticketOwnsIncoming && !handoffOwnsCard) return NO;
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
    // The original hostedSourceSize forwards to its real sourceSize, cleared by close.
    if (!isfinite(content.width) || !isfinite(content.height) || content.width <= 0 || content.height <= 0) return NO;
    PXWMRect nativeFrame = nativeFrameOverride ? *nativeFrameOverride : PXWMFromRect(card.frame);
    PXWMGeometry geometry = {nativeFrame, PXWMFromRect(reference)};
    if (!PXWMValidGeometry(geometry)) return NO;
    context.geometryGate = PXWMGateReady;
    context.card = card;
    if (out) *out = geometry;
    if (key) *key = PXWMOrientationKey(reference.size.width > reference.size.height,
                                      content.width > content.height);
    return YES;
}

static BOOL PXWMNormalGeometry(PXWMContext *context, PXWMGeometry *out, unsigned *key) {
    return PXWMReadGeometry(context, NO, NULL, out, key);
}

/* Runtime target is separate from the opening ticket. User moves update its
 * centre; a real resize replaces it. Epoch/generation/identity prevent stale
 * work from reaching a different window or a cleared preference snapshot. */
static void PXWMDiagnosticReasonLog(PXWMContext *context,unsigned lane,unsigned reason,BOOL incident) {
    if (!context || ![PXWindowMemoryStore.shared.snapshot[@"diagnostics"] boolValue]) return;
    PXWMDiagnosticGate *gate=incident ? &context->diagnosticIncidentGate : &context->diagnosticGate;
    if (!PXWMDiagnosticShouldRecord(gate,(uint64_t)context.generation,lane,reason)) {
        if (gate->count>=PXWMDiagnosticReasonLimit && !gate->limitReported) {
            gate->limitReported=true;
            PXWMLog(context,@"diagnostic_reason_limit",@{@"lane":@(lane),@"lastReason":@(reason),
                @"criticalLane":@(incident),@"recorded":@(gate->count)});
        }
        return;
    }
    UIView *card=context.card;
    CGRect frame=card ? card.frame : CGRectZero;
    PXWMLog(context,@"continuity_decision",
        @{@"lane":@(lane),@"reason":@(reason),@"diagIncident":@(incident),
          @"gate":@(context.geometryGate),@"active":@(context.continuityActive),
          @"interacting":@(context.interacting),@"savePending":@(context.savePending),
          @"targetEpoch":@(context.continuityEpoch),@"targetGeneration":@(context.continuityGeneration),
          @"targetKey":@(context.continuityKey),@"attempts":@(context.continuitySyncAttempts),
          @"totalAttempts":@(context.continuityBudgetAttempts),
          @"x":@(frame.origin.x),@"y":@(frame.origin.y),@"w":@(frame.size.width),@"h":@(frame.size.height),
          @"targetX":@(context.continuityGeometry.frame.x),@"targetY":@(context.continuityGeometry.frame.y),
          @"targetW":@(context.continuityGeometry.frame.width),@"targetH":@(context.continuityGeometry.frame.height),
          @"windowPresent":@(card.window!=nil),@"hidden":@(card.window.hidden),
          @"windowAlpha":@(card.window.alpha),@"cardHidden":@(card.hidden),@"cardAlpha":@(card.alpha),
          @"scenePresent":@(PXWMObject(context.bridge,@"scene")!=nil),
          @"surface":@(PXWMBool(context.bridge,@"hasHostedSurface")),
          @"keyboard":@(PXWMBool(context.bridge,@"isHostedKeyboardVisible")),
          @"fullscreen":@(PXWMBool(context.bridge,@"fullscreenHandoff")),
          @"canvasInteractive":@(context.canvas.userInteractionEnabled),
          @"bundleMatch":@([PXWMObject(context.bridge,@"bundleID") isEqual:context.bundle]),
          @"canvasMatch":@(PXWMObject(context.bridge,@"canvas")==context.canvas)});
}

/* Observe the existing apply boundaries. These samples do not change frame,
 * visibility, animation or scheduling. Model vs presentation is explicit. */
static void PXWMFirstFrameSnapshot(PXWMContext *context,PXWMRect target,unsigned path,unsigned phase) {
    if (!context || ![PXWindowMemoryStore.shared.snapshot[@"diagnostics"] boolValue]) return;
    UIView *card=context.card;
    if (!card) { PXWMDiagnosticReasonLog(context,PXWMLaneFirstFrame,PXWMReasonNoCard,NO); return; }
    CGRect frame=card.frame,bounds=card.bounds;
    CALayer *presentation=card.layer.presentationLayer;
    CGRect shown=presentation ? presentation.frame : card.layer.frame;
    CGAffineTransform transform=card.transform;
    BOOL visible=card.window && !card.window.hidden && card.window.alpha>0.1;
    for (UIView *view=card;view;view=view.superview)
        if (view.hidden || view.alpha<=0.1) visible=NO;
    BOOL differs= !PXWMRectNear(PXWMFromRect(frame),target,1);
    PXWMLog(context,@"first_frame_boundary",
        @{@"path":@(path),@"phase":@(phase),@"visible":@(visible),@"hasPresentation":@(presentation!=nil),
          @"x":@(frame.origin.x),@"y":@(frame.origin.y),@"w":@(frame.size.width),@"h":@(frame.size.height),
          @"boundsX":@(bounds.origin.x),@"boundsY":@(bounds.origin.y),
          @"centerX":@(card.center.x),@"centerY":@(card.center.y),
          @"shownX":@(shown.origin.x),@"shownY":@(shown.origin.y),
          @"shownW":@(shown.size.width),@"shownH":@(shown.size.height),
          @"targetX":@(target.x),@"targetY":@(target.y),
          @"targetW":@(target.width),@"targetH":@(target.height),
          @"ta":@(transform.a),@"tb":@(transform.b),@"tc":@(transform.c),@"td":@(transform.d),
          @"tx":@(transform.tx),@"ty":@(transform.ty),
          @"windowPresent":@(card.window!=nil),@"windowHidden":@(card.window.hidden),
          @"diagIncident":@(phase==0 && visible && differs && target.width>0)});
}

static void PXWMArmContinuity(PXWMContext *context, PXWMGeometry geometry,
                              unsigned key, uint64_t epoch, BOOL moving) {
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (!context || !PXWMBindingIsActive(context) || !PXWMValidGeometry(geometry) ||
        ![snapshot[@"enabled"] boolValue] || epoch != [snapshot[@"epoch"] unsignedLongLongValue]) {
        unsigned reason=!PXWMBindingIsActive(context) ? PXWMReasonBinding :
            !PXWMValidGeometry(geometry) ? PXWMReasonGeometry :
            ![snapshot[@"enabled"] boolValue] ? PXWMReasonDisabled : PXWMReasonEpoch;
        PXWMDiagnosticReasonLog(context,PXWMLaneArm,reason,NO); return;
    }
    context.continuityFrameReports=0;
    context.continuityGeometry = geometry;
    context.continuityKey = key;
    context.continuityEpoch = epoch;
    context.continuityGeneration = context.generation;
    context.continuityMove = moving;
    context.continuityActive = YES;
    PXWMLog(context,@"continuity_armed",@{@"moving":@(moving),@"key":@(key),@"targetEpoch":@(epoch),
        @"x":@(geometry.frame.x),@"y":@(geometry.frame.y),@"w":@(geometry.frame.width),@"h":@(geometry.frame.height)});
}

static BOOL PXWMContinuityReady(PXWMContext *context) {
    if (!context || !context.continuityActive || context.restoring) {
        PXWMDiagnosticReasonLog(context,PXWMLaneReady,context.restoring ? PXWMReasonRestoring : PXWMReasonInactive,NO);
        return NO;
    }
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    PXWMGeometry current; unsigned key = 0;
    BOOL normal = PXWMNormalGeometry(context, &current, &key);
    BOOL identity = PXWMObject(context.bridge,@"canvas") == context.canvas &&
        [PXWMObject(context.bridge,@"bundleID") isEqual:context.bundle] &&
        PXWMFindCard(context.canvas) == context.card;
    BOOL reference = normal && PXWMRectNear(current.reference,context.continuityGeometry.reference,1);
    BOOL transient = !normal || !context.canvas.userInteractionEnabled ||
        PXWMBool(context.bridge,@"fullscreenHandoff") ||
        PXWMBool(context.bridge,@"isHostedKeyboardVisible");
    BOOL allowed = PXWMContinuityAllowed(PXWMBindingIsActive(context),identity,
        [snapshot[@"enabled"] boolValue],context.continuityEpoch,
        [snapshot[@"epoch"] unsignedLongLongValue],context.continuityGeneration,
        context.generation,transient,normal && key==context.continuityKey,reference);
    if (!allowed) {
        unsigned reason=!PXWMBindingIsActive(context) ? PXWMReasonBinding : !identity ? PXWMReasonIdentity :
            ![snapshot[@"enabled"] boolValue] ? PXWMReasonDisabled :
            context.continuityEpoch!=[snapshot[@"epoch"] unsignedLongLongValue] ? PXWMReasonEpoch :
            context.continuityGeneration!=context.generation ? PXWMReasonGeneration :
            transient ? PXWMReasonTransient : key!=context.continuityKey ? PXWMReasonDirection : PXWMReasonReference;
        PXWMDiagnosticReasonLog(context,PXWMLaneReady,reason,reason==PXWMReasonIdentity);
    }
    if (context.continuityEpoch != [snapshot[@"epoch"] unsignedLongLongValue] ||
        context.continuityGeneration != context.generation || ![snapshot[@"enabled"] boolValue] ||
        (normal && (!reference || key!=context.continuityKey))) {
        context.continuityActive=NO;
        context.initialTargetActive=NO;
    }
    return allowed;
}

static BOOL PXWMContentGeometry(PXWMContext *context, PXWMRect *shown,
                                PXWMRect *expected, double *scale) {
    UIView *canvas = context.canvas;
    UIView *host = PXWMObject(context.bridge,@"hostView");
    if (!canvas || ![host isKindOfClass:UIView.class] || host==canvas ||
        ![host isDescendantOfView:canvas] || !host.window || host.window!=canvas.window) {
        PXWMDiagnosticReasonLog(context,PXWMLaneContent,(!canvas || ![host isKindOfClass:UIView.class]) ?
            PXWMReasonNoHost : PXWMReasonHostTree,NO); return NO;
    }
    CGSize source = CGSizeZero;
    SEL selector = NSSelectorFromString(@"sourceSize");
    if (!PXCloneInstanceMethodMatches(context.bridge,selector,@encode(CGSize),@[])) {
        PXWMDiagnosticReasonLog(context,PXWMLaneContent,PXWMReasonNoSourceMethod,YES); return NO;
    }
    @try { source=((CGSize (*)(id,SEL))objc_msgSend)(context.bridge,selector); }
    @catch (__unused NSException *exception) {
        PXWMDiagnosticReasonLog(context,PXWMLaneContent,PXWMReasonSourceException,YES); return NO;
    }
    if (!PXWMContentFit(PXWMFromRect(canvas.bounds),source.width,source.height,expected,scale)) {
        PXWMDiagnosticReasonLog(context,PXWMLaneContent,PXWMReasonSourceSize,NO); return NO;
    }
    CGRect converted=[host convertRect:host.bounds toView:canvas];
    *shown=PXWMFromRect(converted);
    if (!PXWMValidRect(*shown)) PXWMDiagnosticReasonLog(context,PXWMLaneContent,PXWMReasonConvertedRect,YES);
    return PXWMValidRect(*shown);
}

static BOOL PXWMReconcileRuntimeFrame(PXWMContext *context) {
    if (!PXWMContinuityReady(context) || context.interacting || context.savePending ||
        context.continuitySyncing) {
        PXWMDiagnosticReasonLog(context,PXWMLaneReconcile,context.interacting ? PXWMReasonInteracting :
            context.savePending ? PXWMReasonSavePending : context.continuitySyncing ? PXWMReasonSyncing : PXWMReasonInactive,NO);
        return NO;
    }
    UIView *card=context.card;
    PXWMRect actual=PXWMFromRect(card.frame),target=context.continuityGeometry.frame;
    if (PXWMRectNear(actual,target,0.5)) return NO;
    context.restoring=YES;
    @try {
        [UIView performWithoutAnimation:^{
            card.frame=PXWMToRect(target);
            [card setNeedsLayout]; [card layoutIfNeeded];
        }];
    } @finally { context.restoring=NO; }
    PXWMLog(context,@"runtime_geometry_reconciled",
        @{@"diagIncident":@YES,@"fromX":@(actual.x),@"fromY":@(actual.y),@"fromW":@(actual.width),@"fromH":@(actual.height),
          @"toX":@(target.x),@"toY":@(target.y),@"toW":@(target.width),@"toH":@(target.height)});
    return YES;
}

static void PXWMQueueContentSync(PXWMContext *context) {
    if (!context || (context.continuityScheduled && context.continuityScheduleGeneration==context.generation) ||
        context.continuitySyncing || context.restoring || !PXWMContinuityReady(context) || !PXWMOriginalLayout ||
        (context.interacting && !context.continuityMove)) {
        unsigned reason=context.continuityScheduled ? PXWMReasonQueued : context.continuitySyncing ? PXWMReasonSyncing :
            context.restoring ? PXWMReasonRestoring : !context.continuityActive ? PXWMReasonInactive :
            !PXWMOriginalLayout ? PXWMReasonNoLayout : context.interacting ? PXWMReasonResize : PXWMReasonTransient;
        PXWMDiagnosticReasonLog(context,PXWMLaneQueue,reason,reason==PXWMReasonNoLayout); return;
    }
    PXWMRect shown,expected; double scale=0;
    if (!PXWMContentGeometry(context,&shown,&expected,&scale)) return;
    BOOL canvasMatches=fabs(context.canvas.bounds.size.width-context.card.bounds.size.width)<=1 &&
        fabs(context.canvas.bounds.size.height-context.card.bounds.size.height)<=1;
    if (canvasMatches && PXWMRectNear(shown,expected,1)) return;
    NSString *syncKey=[NSString stringWithFormat:@"%llu/%lu/%@/%@/%.4f/%@",
        (unsigned long long)context.continuityEpoch,(unsigned long)context.generation,
        NSStringFromCGRect(context.card.bounds),NSStringFromCGRect(context.canvas.bounds),
        scale,NSStringFromCGRect(PXWMToRect(expected))];
    if (![context.continuitySyncKey isEqual:syncKey]) {
        context.continuitySyncKey=syncKey; context.continuitySyncAttempts=0;
    }
    if (context.continuityBudgetGeneration!=context.generation) {
        context.continuityBudgetGeneration=context.generation;
        context.continuityBudgetAttempts=0;
    }
    if (!PXWMContentSyncMayAttempt((unsigned)context.continuitySyncAttempts,
                                  (unsigned)context.continuityBudgetAttempts)) {
        PXWMDiagnosticReasonLog(context,PXWMLaneQueue,PXWMReasonBudget,YES); return;
    }
    context.continuityScheduled=YES;
    NSUInteger generation=context.generation;
    context.continuityScheduleGeneration=generation;
    NSDictionary *diagnosticTicket=@{@"appHash":@(PXWMAppHash(context.bundle)),
        @"openSerial":@(context->native.serial),@"generation":@(generation),
        @"epoch":@(context.continuityEpoch)};
    PXWMLog(context,@"content_sync_queued",@{@"diagIncident":@YES,@"attempts":@(context.continuitySyncAttempts),
        @"totalAttempts":@(context.continuityBudgetAttempts),@"expectedW":@(expected.width),@"expectedH":@(expected.height)});
    __weak PXWMContext *weakContext=context;
    /* One coalesced next-main-turn correction per observed layout change.
     * This is not a polling loop; probes are read-only and never call this. */
    dispatch_async(dispatch_get_main_queue(), ^{
        PXWMContext *current=weakContext;
        if (!current) {
            [PXWindowMemoryStore.shared diagnostic:@"content_sync_context_released" details:diagnosticTicket]; return;
        }
        if (current.continuityScheduleGeneration==generation) current.continuityScheduled=NO;
        if (current.generation!=generation || current.continuitySyncing ||
            !PXWMContinuityReady(current) ||
            (current.interacting && !current.continuityMove)) {
            PXWMDiagnosticReasonLog(current,PXWMLaneCallback,current.generation!=generation ? PXWMReasonGeneration :
                current.continuitySyncing ? PXWMReasonSyncing : current.interacting ? PXWMReasonResize : PXWMReasonTransient,NO);
            return;
        }
        PXWMRect before,target; double expectedScale=0;
        if (!PXWMContentGeometry(current,&before,&target,&expectedScale)) return;
        BOOL canvasStillMatches=fabs(current.canvas.bounds.size.width-current.card.bounds.size.width)<=1 &&
            fabs(current.canvas.bounds.size.height-current.card.bounds.size.height)<=1;
        if (canvasStillMatches && PXWMRectNear(before,target,1)) {
            PXWMLog(current,@"content_sync_already_matched",@{@"queuedGeneration":@(generation)}); return;
        }
        if (![current.continuitySyncKey isEqual:syncKey] ||
            !PXWMContentSyncMayAttempt((unsigned)current.continuitySyncAttempts,
                                      (unsigned)current.continuityBudgetAttempts)) {
            PXWMDiagnosticReasonLog(current,PXWMLaneCallback,
                ![current.continuitySyncKey isEqual:syncKey] ? PXWMReasonChangedTarget : PXWMReasonBudget,YES); return;
        }
        current.continuitySyncAttempts++; current.continuityBudgetAttempts++;
        current.continuitySyncing=YES;
        @try {
            [current.card setNeedsLayout]; [current.card layoutIfNeeded];
            PXWMOriginalLayout(current.bridge,NSSelectorFromString(@"layoutHost"));
        } @finally { current.continuitySyncing=NO; }
        PXWMRect after,afterTarget; double afterScale=0;
        BOOL measured=PXWMContentGeometry(current,&after,&afterTarget,&afterScale);
        PXWMLog(current,@"content_layout_reconciled",
            @{@"beforeX":@(before.x),@"beforeY":@(before.y),
              @"beforeW":@(before.width),@"beforeH":@(before.height),
              @"expectedW":@(target.width),@"expectedH":@(target.height),
              @"measured":@(measured),@"matches":@(measured && PXWMRectNear(after,afterTarget,1)),
              @"afterX":@(measured ? after.x : 0),@"afterY":@(measured ? after.y : 0),
              @"afterW":@(measured ? after.width : 0),@"afterH":@(measured ? after.height : 0),
              @"attempts":@(current.continuitySyncAttempts),@"totalAttempts":@(current.continuityBudgetAttempts),
              @"diagIncident":@(!measured || !PXWMRectNear(after,afterTarget,1))});
        PXWMProbeContentGeometry(current,6);
    });
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

/* Do not read Swift dockedHosts/activeBridge fields. The bound bridge/canvas
 * identity is enough: native parking leaves this existing card transformed in
 * a separate dock window; the original expansion reuses that same card. */
static BOOL PXWMIsParked(PXWMContext *context) {
    if (!PXWMBindingIsActive(context) || context.interacting || context.savePending ||
        PXWMObject(context.bridge, @"canvas") != context.canvas ||
        ![PXWMObject(context.bridge, @"bundleID") isEqual:context.bundle] ||
        PXWMBool(context.bridge, @"fullscreenHandoff") ||
        PXWMBool(context.bridge, @"isHostedKeyboardVisible")) return NO;
    UIView *card = PXWMFindCard(context.canvas);
    UIWindow *window = card.window;
    if (!card || !window || window.screen != UIScreen.mainScreen) return NO;
    context.card = card;
    CGSize host = window.bounds.size, screen = UIScreen.mainScreen.bounds.size;
    BOOL smallWindow = fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
                       fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3;
    return smallWindow || !CGAffineTransformIsIdentity(card.transform);
}

static NSArray<PXWMExpansion *> *PXWMBeginExpansion(NSString *bundle, UIWindow *triggerWindow) {
    if (!NSThread.isMainThread || !PXWindowMemoryStore.shared.isLoaded) return @[];
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (![snapshot[@"enabled"] boolValue]) return @[];
    NSMutableArray *scope = [NSMutableArray array];
    @try {
    for (PXWMContext *context in PXWMContexts.allObjects) {
        if ((bundle && ![context.bundle isEqual:bundle]) ||
            (triggerWindow && context.canvas.window != triggerWindow) || !PXWMIsParked(context)) continue;
        PXWMExpansion *event = [PXWMExpansion new];
        event.context = context; event.generation = context.generation;
        event.epoch = [snapshot[@"epoch"] unsignedLongLongValue];
        context.initialTargetActive = NO;
        [scope addObject:event];
        PXWMLog(context, @"expansion_native_entry", @{@"epoch":@(event.epoch)});
    }
    } @catch (__unused NSException *exception) {
        [PXWindowMemoryStore.shared diagnostic:@"expansion_observation_exception" details:@{}];
        return @[];
    }
    return scope;
}

static void PXWMEndExpansion(NSArray<PXWMExpansion *> *scope) {
    for (PXWMExpansion *event in scope) {
        PXWMContext *context = event.context;
        PXWMLog(context, @"expansion_native_returned", @{@"targetApplied":@(event.applied)});
    }
}

static BOOL PXWMExpansionTarget(PXWMContext *context, CGRect incoming, CGRect *result) {
    if (!context || !result || context.restoring || !PXWMExpansionScope.count) return NO;
    PXWMExpansion *event = nil;
    for (PXWMExpansion *candidate in PXWMExpansionScope)
        if (candidate.context == context) { event = candidate; break; }
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (!event || !PXWindowMemoryStore.shared.isLoaded || ![snapshot[@"enabled"] boolValue] ||
        !PXWMMayApplyExpansion(PXWMExpansionScope != nil, YES,
         PXWMBindingIsActive(context), event.generation == context.generation,
         context.interacting, context.savePending,
         event.epoch == [snapshot[@"epoch"] unsignedLongLongValue], event.applied)) return NO;
    PXWMRect nativeFrame = PXWMFromRect(incoming), restored;
    PXWMGeometry geometry, saved;
    unsigned key = 0;
    if (!PXWMReadGeometry(context, YES, &nativeFrame, &geometry, &key)) {
        PXWMLog(context, @"expansion_target_not_ready", @{@"gate":@(context.geometryGate)});
        return NO;
    }
    if (!PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved)) {
        PXWMLog(context, @"expansion_native_default", @{@"key":@(key)});
        return NO;
    }
    if (!PXWMRestore(saved, geometry.reference, nativeFrame, &restored)) return NO;
    event.applied = YES;
    context.key = key; context.keyKnown = YES; context.resolved = YES;
    *result = PXWMToRect(restored);
    PXWMArmContinuity(context,(PXWMGeometry){restored,geometry.reference},key,event.epoch,NO);
    PXWMLog(context, @"expansion_remembered_target", @{@"fromW":@(incoming.size.width),
              @"fromH":@(incoming.size.height), @"toW":@(restored.width), @"toH":@(restored.height),
              @"revision":snapshot[@"revision"] ?: @0});
    PXWMVerifyRestore(context, restored, key, event.epoch);
    return YES;
}

/* The verified alpha440 restore path runs the animation block synchronously:
 * card transform identity -> setFrame -> layoutIfNeeded -> bridge.layoutHost.
 * Scope ends when the exact original selector returns, even after exceptions.
 * No return-address tricks, timer extension, private Swift offsets or repeated
 * frame writes. If a later version defers that block, this safely does nothing. */
static void PXWMRestoreDockTapped(id self, SEL command, id gesture) {
    if (!PXWMOriginalRestoreDockTapped) return;
    if (!NSThread.isMainThread || PXWMExpansionScope) {
        PXWMOriginalRestoreDockTapped(self, command, gesture); return;
    }
    UIWindow *triggerWindow = [gesture isKindOfClass:UIGestureRecognizer.class] ?
                              [(UIGestureRecognizer *)gesture view].window : nil;
    if (!triggerWindow) { PXWMOriginalRestoreDockTapped(self, command, gesture); return; }
    NSArray *previous = PXWMExpansionScope;
    NSArray *scope = PXWMBeginExpansion(nil, triggerWindow);
    PXWMExpansionScope = scope;
    @try { PXWMOriginalRestoreDockTapped(self, command, gesture); }
    @finally { PXWMExpansionScope = previous; PXWMEndExpansion(scope); }
}
static void PXWMExternalOpen(id self, SEL command, id bundle) {
    if (!PXWMOriginalExternalOpen) return;
    if (!NSThread.isMainThread || PXWMExpansionScope || ![bundle isKindOfClass:NSString.class]) {
        PXWMOriginalExternalOpen(self, command, bundle); return;
    }
    NSArray *previous = PXWMExpansionScope;
    NSArray *scope = PXWMBeginExpansion(bundle, nil);
    PXWMExpansionScope = scope;
    @try { PXWMOriginalExternalOpen(self, command, bundle); }
    @finally { PXWMExpansionScope = previous; PXWMEndExpansion(scope); }
}

/* A parked app selected from the original rail/search also goes through the
 * native dock restore function. Preserve action consumption/BOOL exactly; no
 * route/account/payment handling belongs to the memory adapter. */
static BOOL PXWMConfiguredAction(id self, SEL command, id action) {
    if (!PXWMOriginalConfiguredAction) return NO;
    if (!NSThread.isMainThread || PXWMExpansionScope)
        return PXWMOriginalConfiguredAction(self, command, action);
    NSArray *previous = PXWMExpansionScope;
    NSArray *scope = PXWMBeginExpansion(nil, nil);
    PXWMExpansionScope = scope;
    @try { return PXWMOriginalConfiguredAction(self, command, action); }
    @finally { PXWMExpansionScope = previous; PXWMEndExpansion(scope); }
}
static BOOL PXWMConfiguredActionSearch(id self, SEL command, id action, BOOL fromSearch) {
    if (!PXWMOriginalConfiguredActionSearch) return NO;
    if (!NSThread.isMainThread || PXWMExpansionScope)
        return PXWMOriginalConfiguredActionSearch(self, command, action, fromSearch);
    NSArray *previous = PXWMExpansionScope;
    NSArray *scope = PXWMBeginExpansion(nil, nil);
    PXWMExpansionScope = scope;
    @try { return PXWMOriginalConfiguredActionSearch(self, command, action, fromSearch); }
    @finally { PXWMExpansionScope = previous; PXWMEndExpansion(scope); }
}

/* The alpha455 open path can make the new window visible while its geometry
 * gate is still catching up. Resolve the ticket before forwarding the first
 * default PXHostCard frame so the original reveal uses the saved target. */
/* Resolve the exact current canvas card even before PXSceneBridge.open returns
 * and publishes its ticket as the long-lived binding. This is needed because
 * the default PXHostCard frame write is earlier than our post-open retry. */
static PXWMContext *PXWMContextForCardFrame(UIView *card) {
    if (!NSThread.isMainThread || !card || !PXWMContexts) return nil;
    PXWMContext *match = nil;
    for (PXWMContext *candidate in PXWMContexts.allObjects) {
        BOOL bound = PXWMBindingIsActive(candidate);
        BOOL currentTicket = candidate.bridge && !candidate->native.cancelled &&
            objc_getAssociatedObject(candidate.bridge, PXWMOpenTicketKey) == candidate;
        if (!bound && !currentTicket) continue;
        BOOL ownsCard = candidate.card == card;
        if (!ownsCard && PXWMInitialHandoffOwnsCard(candidate, card)) {
            ownsCard = YES;
            if (!candidate.card) candidate.card = card;
        }
        if (!ownsCard && currentTicket && candidate.canvas &&
            (PXWMObject(candidate.bridge, @"canvas") == candidate.canvas ||
             PXWMTicketMayUseIncomingAssociation(candidate, YES))) {
            id bridgeBundle = PXWMObject(candidate.bridge, @"bundleID");
            BOOL bundleMatches = [bridgeBundle isEqual:candidate.bundle] || bridgeBundle == nil;
            if (bundleMatches)
                ownsCard = PXWMFindCard(candidate.canvas) == card;
        }
        if (!ownsCard) continue;
        if (match) return nil; // Ambiguous context: leave the original frame untouched.
        match = candidate;
        if (!candidate.card && currentTicket) candidate.card = card;
    }
    return match;
}

/* Content-free probe: does the hosted canvas track the host card? A mismatch
 * means the window frame is right while the content is still laid out for
 * another size. Sizes only; never any content, name or identifier. */
static void PXWMProbeContentGeometry(PXWMContext *context, unsigned stage) {
    if (!context) return;
    UIView *card = context.card;
    if (!card) card = PXWMFindCard(context.canvas);
    if (!card) return;
    UIView *canvas = context.canvas;
    id bridge = context.bridge;
    UIView *host = PXWMObject(bridge, @"hostView");
    if (![host isKindOfClass:UIView.class]) host = nil;
    CGSize cardSize = card.bounds.size;
    CGSize canvasSize = canvas ? canvas.bounds.size : CGSizeZero;
    CGSize hostSize = host ? host.bounds.size : CGSizeZero;
    CGSize source = CGSizeZero;
    SEL sel = NSSelectorFromString(@"sourceSize");
    if (bridge && PXCloneInstanceMethodMatches(bridge, sel, @encode(CGSize), @[])) {
        @try { source = ((CGSize (*)(id,SEL))objc_msgSend)(bridge, sel); }
        @catch (__unused NSException *exception) { source = CGSizeZero; }
    }
    CGAffineTransform t = host ? host.transform : CGAffineTransformIdentity;
    PXWMRect shown={0},fit={0}; double expected=0;
    BOOL measured=PXWMContentGeometry(context,&shown,&fit,&expected);
    double scale=measured && source.width>0 ? shown.width/source.width : 0;
    double boundsRatio=(source.width>0 && hostSize.width>0) ? hostSize.width/source.width : 0;
    CGRect canvasBounds=canvas ? canvas.bounds : CGRectZero;
    BOOL clip=measured && (shown.x<canvasBounds.origin.x-1 || shown.y<canvasBounds.origin.y-1 ||
        shown.x+shown.width>CGRectGetMaxX(canvasBounds)+1 ||
        shown.y+shown.height>CGRectGetMaxY(canvasBounds)+1);
    BOOL canvasMismatch = fabs(canvasSize.width - cardSize.width) > 1 ||
                          fabs(canvasSize.height - cardSize.height) > 1;
    BOOL scaleMismatch=measured && (fabs(shown.width-fit.width)>1 || fabs(shown.height-fit.height)>1);
    BOOL positionMismatch=measured && (fabs(shown.x-fit.x)>1 || fabs(shown.y-fit.y)>1);
    CGRect cardFrame=card.frame;
    CALayer *presentation=card.layer.presentationLayer;
    CGRect visibleFrame=presentation ? presentation.frame : card.layer.frame;
    /* Include position/full transform and ownership, not only the dimensions. */
    NSString *signature=[NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%d/%d/%d/%d",
        NSStringFromCGRect(cardFrame),NSStringFromCGRect(visibleFrame),NSStringFromCGRect(canvasBounds),
        NSStringFromCGSize(source),NSStringFromCGRect(PXWMToRect(shown)),NSStringFromCGAffineTransform(t),
        NSStringFromCGSize(hostSize),(int)measured,(int)clip,(int)canvasMismatch,(int)positionMismatch];
    if (stage > 0 && [signature isEqualToString:context.probeSignature ?: @""]) return;
    unsigned flags=(measured?1u:0u)|(canvasMismatch?2u:0u)|(scaleMismatch?4u:0u)|(positionMismatch?8u:0u);
    CFTimeInterval now=CACurrentMediaTime();
    if (stage>0 && stage!=6 && context.diagnosticProbeKnown && flags==context.diagnosticProbeFlags &&
        now-context.diagnosticProbeTime<0.25) {
        if (context.diagnosticProbeSuppressed<65535) context.diagnosticProbeSuppressed++;
        return;
    }
    unsigned suppressed=context.diagnosticProbeSuppressed;context.diagnosticProbeSuppressed=0;
    context.diagnosticProbeTime=now;context.diagnosticProbeFlags=flags;context.diagnosticProbeKnown=YES;
    context.probeSignature = signature;
    PXWMLog(context, @"content_geometry_probe",
            @{@"stage":@(stage),@"suppressed":@(suppressed),
              @"cardW":@(cardSize.width), @"cardH":@(cardSize.height),
              @"canvasW":@(canvasSize.width), @"canvasH":@(canvasSize.height),
              @"hostW":@(hostSize.width), @"hostH":@(hostSize.height),
              @"sourceW":@(source.width), @"sourceH":@(source.height),
              @"probeSchema":@3,@"measured":@(measured),@"boundsRatio":@(boundsRatio),
              @"scale":@(scale), @"expectScale":@(expected), @"ta":@((double)t.a),
              @"tb":@((double)t.b),@"tc":@((double)t.c),@"td":@((double)t.d),
              @"tx":@((double)t.tx),@"ty":@((double)t.ty),
              @"cardX":@(cardFrame.origin.x),@"cardY":@(cardFrame.origin.y),
              @"shownX":@(visibleFrame.origin.x),@"shownY":@(visibleFrame.origin.y),
              @"shownW":@(visibleFrame.size.width),@"shownH":@(visibleFrame.size.height),
              @"contentX":@(shown.x),@"contentY":@(shown.y),
              @"contentW":@(shown.width),@"contentH":@(shown.height),
              @"bundleMatch":@([PXWMObject(bridge,@"bundleID") isEqual:context.bundle]),
              @"canvasMatch":@(PXWMObject(bridge,@"canvas")==canvas),
              @"cardMatch":@(PXWMFindCard(canvas)==card),
              @"clip":@(clip ? 1 : 0), @"canvasMismatch":@(canvasMismatch ? 1 : 0),
              @"positionMismatch":@(positionMismatch),@"scaleMismatch":@(scaleMismatch ? 1 : 0),
              @"diagIncident":@(measured && (positionMismatch || scaleMismatch || canvasMismatch))});
}

/* Sample a live window at 1s (first 30s) then 5s (about 8 minutes). Only state
 * changes are written, so a healthy window stays silent. */
static void PXWMScheduleProbe(PXWMContext *context, NSUInteger tick) {
    if (!context) return;
    __weak PXWMContext *weakContext = context;
    int64_t delay = tick < 30 ? NSEC_PER_SEC : 5 * NSEC_PER_SEC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
        PXWMContext *current = weakContext;
        if (!current || !PXWMBindingIsActive(current)) return;
        PXWMProbeContentGeometry(current, 4);
        if (tick < 130) PXWMScheduleProbe(current, tick + 1);
    });
}

/* The vendor gives the card its default frame here, before any window exists.
 * Hand the remembered frame to the original call instead of fighting the first
 * frame afterwards. Everything stays referential: one pending open, a record
 * made for this screen, and the original call is always executed. */
static id PXWMCardInit(id self, SEL command, CGRect frame) {
    if (!PXWMOriginalCardInit) return nil;
    CGRect adjusted = frame;
    if (NSThread.isMainThread && PXWMContexts) {
        PXWMContext *context = PXWMPendingInitialCardContext();
        PXWMRect target = {0, 0, 0, 0}; unsigned key = 0;
        if (context && PXWMInitialCardSavedFrame(context, &target, &key)) {
            adjusted = PXWMToRect(target);
            context.card = (UIView *)self;
            context.initialNativeFrame = PXWMFromRect(frame);
            context.initialTarget = target;
            context.initialTargetKey = key;
            context.key = key;
            context.keyKnown = YES;
            context.initialTargetEpoch = [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue];
            context.initialTargetDeadline = CACurrentMediaTime() + 2.0;
            context.initialTargetActive = YES;
            context.resolved = YES;
            context.initialPreparationWaitLogged = NO;
            context.initialContentRefreshed = NO;
            context.initialFrameSubstituted = NO;
            PXWMLog(context, @"first_frame_memory_applied_at_init",
                    @{@"defaultW":@(frame.size.width), @"defaultH":@(frame.size.height),
                      @"targetW":@(target.width), @"targetH":@(target.height),
                      @"orientationKey":@(key),
                      @"revision":PXWindowMemoryStore.shared.snapshot[@"revision"] ?: @0});
        }
    }
    return PXWMOriginalCardInit(self, command, adjusted);
}

static void PXWMCardSetFrame(id self, SEL command, CGRect frame) {
    if (PXWMOriginalCardSetFrame) {
        if (NSThread.isMainThread && PXWMContexts) {
            PXWMContext *context = PXWMContextForCardFrame((UIView *)self);
            if (!context) {
                /* Bounded: one content-free record per opening serial, so a
                 * failed first frame always says whether the hook even resolved
                 * an owning context. */
                static uint64_t lastMissSerial;
                uint64_t serial = 0; NSUInteger pending = 0;
                for (PXWMContext *candidate in PXWMContexts.allObjects)
                    if (PXWMInitialFrameMayPrepare(candidate)) {
                        pending++;
                        if (candidate->native.serial > serial) serial = candidate->native.serial;
                    }
                if (serial && serial != lastMissSerial) {
                    lastMissSerial = serial;
                    PXWMLog(nil, @"first_frame_no_context",
                            @{@"serial":@(serial), @"pending":@(pending),
                              @"w":@(frame.size.width), @"h":@(frame.size.height)});
                }
            }
            CGRect expandedTarget;
            if (PXWMExpansionTarget(context, frame, &expandedTarget)) frame = expandedTarget;
            if (PXWMContinuityReady(context) &&
                (!context.interacting || context.continuityMove) &&
                (!context.savePending || context.continuityMove)) {
                PXWMRect requested=PXWMFromRect(frame), target=context.continuityGeometry.frame;
                BOOL accepted=YES;
                if (context.continuityMove) {
                    PXWMGeometry moving={requested,context.continuityGeometry.reference};
                    accepted=PXWMKeepMoveSize(context.continuityGeometry,moving,&target);
                }
                if (accepted) {
                    if (!PXWMRectNear(requested,target,0.5) && context.continuityFrameReports++<6)
                        PXWMLog(context,@"runtime_frame_preserved",
                            @{@"fromX":@(requested.x),@"fromY":@(requested.y),
                              @"fromW":@(requested.width),@"fromH":@(requested.height),
                              @"toX":@(target.x),@"toY":@(target.y),
                              @"toW":@(target.width),@"toH":@(target.height),
                              @"moving":@(context.continuityMove)});
                    frame=PXWMToRect(target);
                    if (context.continuityMove) {
                        PXWMGeometry latest=context.continuityGeometry;
                        latest.frame=target;
                        context.continuityGeometry=latest;
                    }
                }
            }
            BOOL preflightReady = PXWMInitialFrameMayPrepare(context) &&
                !context.initialTargetActive && !context.restoring &&
                !context.interacting && !context.savePending;
            PXWMRect pendingDefault = PXWMFromRect(frame);
            if (preflightReady) context.card = (UIView *)self;
            if (preflightReady && !context.initialTargetActive) {
                if (context.card != (UIView *)self || context.initialNativeFrame.width < 1 || context.initialNativeFrame.height < 1)
                    context.initialNativeFrame = pendingDefault;
                context.card = (UIView *)self;
                NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
                BOOL loaded = PXWindowMemoryStore.shared.isLoaded;
                PXWMGeometry pending, saved; unsigned key = 0;
                BOOL geometryReady = PXWMReadGeometry(context, YES, &pendingDefault, &pending, &key);
                BOOL hasRecord = loaded && [snapshot[@"enabled"] boolValue] && geometryReady &&
                    PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved);
                BOOL prepared = NO;
                if (geometryReady && hasRecord && !context.resolved) {
                    PXWMRect initialNative = context.initialNativeFrame;
                    prepared = PXWMPrepareInitialLayoutWithNativeFrame(context, &initialNative, YES);
                }
                if (prepared)
                    PXWMLog(context, @"first_frame_memory_ready",
                            @{@"defaultW":@(pendingDefault.width), @"defaultH":@(pendingDefault.height),
                              @"targetW":@(context.initialTarget.width), @"targetH":@(context.initialTarget.height),
                              @"revision":snapshot[@"revision"] ?: @0});
                if (!prepared) {
                    if (!geometryReady) { if (PXWMShouldLogRestoreWait((unsigned)++context.restoreRetryAttempts, context.geometryGate, context.restoreRetryLoggedGate)) {
                        context.restoreRetryLoggedGate=context.geometryGate;
                        PXWMLog(context, @"first_frame_memory_waiting_for_native_source",
                                @{@"gate":@(context.geometryGate), @"attempt":@(context.restoreRetryAttempts),
                                  @"defaultW":@(context.initialNativeFrame.width), @"defaultH":@(context.initialNativeFrame.height),
                                  @"canvas":@(PXWMLinkState(PXWMObject(context.bridge, @"canvas"), context.canvas)),
                                  @"bundle":@(PXWMIdentityState(PXWMObject(context.bridge, @"bundleID"), context.bundle)),
                                  @"cardOwns":@(PXWMInitialHandoffOwnsCard(context, (UIView *)self) ? 1 : 0),
                                  @"hidden":@(((UIView *)self).window.hidden ? 1 : 0)}); } }
                    else if (!context.initialPreparationWaitLogged) { context.initialPreparationWaitLogged=YES; if (!loaded) PXWMLog(context, @"first_frame_memory_waiting_for_store", @{@"revision":snapshot[@"revision"] ?: @0}); else if (![snapshot[@"enabled"] boolValue]) PXWMLog(context, @"first_frame_memory_disabled", @{@"revision":snapshot[@"revision"] ?: @0}); else if (!hasRecord) PXWMLog(context, @"first_frame_memory_no_record", @{@"orientationKey":@(key), @"revision":snapshot[@"revision"] ?: @0}); else PXWMLog(context, @"first_frame_memory_not_prepared", @{@"gate":@(context.geometryGate), @"resolved":@(context.resolved)}); }
                }
            }
            /* A frame applied at bind is held for as long as this window lives and
             * the user keeps their hands off it: the vendor reloads content seconds
             * later and would otherwise snap the window back to its default size. */
            BOOL holding = context.initialTargetAppliedAtBind ||
                CACurrentMediaTime() < context.initialTargetDeadline;
            BOOL transformed = !CGAffineTransformIsIdentity(((UIView *)self).transform);
            BOOL fullscreen = context.bridge && PXWMBool(context.bridge, @"fullscreenHandoff");
            NSDictionary *holdSnapshot=PXWindowMemoryStore.shared.snapshot;
            BOOL holdBlocked = (context.initialTargetAppliedAtBind && (transformed || fullscreen)) ||
                ![holdSnapshot[@"enabled"] boolValue] ||
                context.initialTargetEpoch != [holdSnapshot[@"epoch"] unsignedLongLongValue] ||
                PXWMBool(context.bridge,@"isHostedKeyboardVisible");
            if (holdBlocked && (![(holdSnapshot)[@"enabled"] boolValue] ||
                context.initialTargetEpoch != [holdSnapshot[@"epoch"] unsignedLongLongValue]))
                context.initialTargetActive=NO;
            if (context && context.initialTargetActive && !context.restoring && !context.interacting &&
                !context.savePending && holding && !holdBlocked) {
                CGRect target = PXWMToRect(context.initialTarget);
                CGRect native = PXWMToRect(context.initialNativeFrame);
                BOOL sameNative = fabs(frame.origin.x-native.origin.x)<0.5 &&
                    fabs(frame.origin.y-native.origin.y)<0.5 && fabs(frame.size.width-native.size.width)<0.5 &&
                    fabs(frame.size.height-native.size.height)<0.5;
                BOOL same = fabs(frame.origin.x-target.origin.x)<0.5 && fabs(frame.origin.y-target.origin.y)<0.5 &&
                    fabs(frame.size.width-target.size.width)<0.5 && fabs(frame.size.height-target.size.height)<0.5;
                if (!same && (sameNative || context.initialTargetAppliedAtBind)) {
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
        if (NSThread.isMainThread) PXWMQueueContentSync(PXWMContextForCardFrame((UIView *)self));
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
    NSUInteger generation=context.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,900*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        PXWMContext *current = weakContext;
        if (!current || !current.initialTargetActive || current.generation!=generation) {
            PXWMDiagnosticReasonLog(current,PXWMLaneFirstFrame,current.generation!=generation ?
                PXWMReasonGeneration : PXWMReasonInactive,NO); return;
        }
        /* Keep holding when this target came from bind; only the timeout path ends here. */
        if (!current.initialTargetAppliedAtBind) current.initialTargetActive = NO;
        if (!PXWMBindingIsActive(current) || current.interacting || current.savePending ||
            !current.keyKnown || current.key != key || !current.card) {
            PXWMDiagnosticReasonLog(current,PXWMLaneFirstFrame,!PXWMBindingIsActive(current) ? PXWMReasonBinding :
                current.interacting ? PXWMReasonInteracting : current.savePending ? PXWMReasonSavePending :
                !current.card ? PXWMReasonNoCard : PXWMReasonDirection,NO); return;
        }
        if ([PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue] != epoch) {
            PXWMDiagnosticReasonLog(current,PXWMLaneFirstFrame,PXWMReasonEpoch,NO); return;
        }
        UIView *card = current.card;
        CGRect target = PXWMToRect(current.initialTarget);
        CGRect native = PXWMToRect(current.initialNativeFrame);
        PXWMFirstFrameSnapshot(current,current.initialTarget,3,0);
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
            PXWMProbeContentGeometry(current, 3);
            PXWMLog(current, @"restore_initial_content_refreshed",
                    @{ @"substituted":@(current.initialFrameSubstituted) });
            PXWMProbeContentGeometry(current, 1);
        }
        PXWMFirstFrameSnapshot(current,current.initialTarget,3,1);
    });
}

/* Native layoutHost already has the true sourceSize, before it fits hosted
 * content. Prepare its outer hostCard here, not after scene visibility. Keep
 * the original layout call and its animations; never hide a window or edit a
 * hosted content transform to disguise a late correction. */
static BOOL PXWMPrepareInitialLayoutWithNativeFrame(PXWMContext *context,
                                                   const PXWMRect *nativeFrameOverride,
                                                   BOOL allowingVisibleTicket) {
    if (!context || context.restoring) return NO;
    id bridge = context.bridge;
    BOOL currentTicket = bridge && objc_getAssociatedObject(bridge, PXWMOpenTicketKey) == context;
    id bridgeBundle = PXWMObject(bridge, @"bundleID");
    BOOL ticketOwnsIncoming = PXWMTicketMayUseIncomingAssociation(context, allowingVisibleTicket) &&
        ([bridgeBundle isEqual:context.bundle] || bridgeBundle == nil);
    BOOL handoffOwnsCard = allowingVisibleTicket &&
        ([bridgeBundle isEqual:context.bundle] || bridgeBundle == nil) &&
        PXWMInitialHandoffOwnsCard(context, context.card);
    BOOL matching = bridge && context.canvas &&
        ((PXWMObject(bridge, @"canvas") == context.canvas &&
          ([bridgeBundle isEqual:context.bundle] ||
           (allowingVisibleTicket && currentTicket && bridgeBundle == nil))) ||
         ticketOwnsIncoming || handoffOwnsCard);
    PXWindowMemoryStore *store = PXWindowMemoryStore.shared;
    NSDictionary *snapshot = store.snapshot;
    BOOL ticketOwns = PXWMOpeningTicketOwnsCanvas(context, context.canvas);
    BOOL standardPermission = PXWMMayPrepareInitialLayout(PXWMBindingIsActive(context), currentTicket,
          context->native.entering, context->native.initialCleanupSeen, context->native.cancelled,
          matching, store.isLoaded, [snapshot[@"enabled"] boolValue], context.resolved,
          context.interacting, context.savePending);
    BOOL visibleTicketPermission = allowingVisibleTicket && ticketOwns && matching &&
          store.isLoaded && [snapshot[@"enabled"] boolValue] && !context.resolved &&
          !context.interacting && !context.savePending;
    if (!standardPermission && !visibleTicketPermission) return NO;
    PXWMGeometry native, saved;
    unsigned key = 0;
    if (!PXWMReadGeometry(context, YES, nativeFrameOverride, &native, &key) ||
        !PXWindowMemoryGeometry(snapshot, context.bundle, key, &saved)) return NO;
    PXWMRect restored;
    if (!PXWMRestore(saved, native.reference, native.frame, &restored)) return NO;
    UIView *card = context.card;
    PXWMFirstFrameSnapshot(context,restored,2,0);
    context.restoring = YES;
    [UIView performWithoutAnimation:^{
        card.frame = PXWMToRect(restored);
        [card setNeedsLayout]; [card layoutIfNeeded];
    }];
    context.restoring = NO;
    PXWMFirstFrameSnapshot(context,restored,2,1);
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
        context.initialPreparationWaitLogged = NO;
        context.initialContentRefreshed = NO;
        context.initialFrameSubstituted = NO;
        PXWMArmContinuity(context,(PXWMGeometry){restored,native.reference},key,
                          [snapshot[@"epoch"] unsignedLongLongValue],NO);
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

static BOOL PXWMPrepareInitialLayout(PXWMContext *context) {
    return PXWMPrepareInitialLayoutWithNativeFrame(context, NULL, NO);
}

/* sourceSize is the native evidence that the app's content axes are known.
 * Acting on this event is earlier than any 100ms retry and is not polling.
 * It only prepares a current opening ticket; every other call is delegated. */
static void PXWMSetSourceSize(id self, SEL command, CGSize size) {
    if (PXWMOriginalSetSourceSize) PXWMOriginalSetSourceSize(self, command, size);
    if (!NSThread.isMainThread || !PXWMContexts) return;
    /* The first open of a session can lay content out before this size exists
     * (probe showed sourceW=0). Once the real size arrives, let the vendor run
     * its own layout pass once more so the content is scaled against it. */
    if (size.width > 0 && size.height > 0 && PXWMOriginalLayout) {
        for (PXWMContext *candidate in PXWMContexts.allObjects) {
            if (candidate.bridge != self || !candidate.keyKnown) continue;
            if (!PXWMBindingIsActive(candidate) || candidate.interacting || candidate.savePending) continue;
            if (candidate.sourceSizeSeen) continue;
            candidate.sourceSizeSeen = YES;
            PXWMOriginalLayout(self, NSSelectorFromString(@"layoutHost"));
            PXWMLog(candidate, @"content_relaid_after_source_size",
                    @{@"sourceW":@(size.width), @"sourceH":@(size.height)});
            PXWMProbeContentGeometry(candidate, 5);
            break;
        }
    }
    PXWMContext *context = nil;
    for (PXWMContext *candidate in PXWMContexts.allObjects) {
        if (candidate.bridge != self || !PXWMOpeningTicketOwnsCanvas(candidate, candidate.canvas)) continue;
        if (context) return; // More than one current ticket: never choose by guess.
        context = candidate;
    }
    if (!context || context.resolved || context.initialTargetActive || context.interacting ||
        context.savePending || !PXWindowMemoryStore.shared.isLoaded) return;
    PXWMPrepareInitialLayoutWithNativeFrame(context, NULL, YES);
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
    if (matched) {
        PXWMArmContinuity(context,(PXWMGeometry){PXWMFromRect(actual),native.reference},key,
                          [snapshot[@"epoch"] unsignedLongLongValue],NO);
        PXWMQueueContentSync(context);
    }
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

/* Starting frame is observable before a newly hosted scene reports its source
 * axes. This is only a before/after user-resize sample, not permission to save
 * or restore: the normal scene/direction gate is still required at the end. */
static BOOL PXWMCaptureGestureFrame(PXWMContext *context, PXWMRect *frame) {
    if (!frame || !PXWMBindingIsActive(context) || !context.canvas.userInteractionEnabled ||
        PXWMBool(context.bridge, @"fullscreenHandoff") ||
        PXWMBool(context.bridge, @"isHostedKeyboardVisible")) return NO;
    UIView *card = PXWMFindCard(context.canvas);
    UIWindow *window = card.window;
    if (!card || !window || !card.superview || window.screen != UIScreen.mainScreen ||
        window.hidden || window.alpha <= 0.1 || !CGAffineTransformIsIdentity(card.transform)) return NO;
    for (UIView *view = card; view; view = view.superview)
        if (view.hidden || view.alpha <= 0.1) return NO;
    CGSize host = window.bounds.size, screen = UIScreen.mainScreen.bounds.size;
    if (fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
        fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3) return NO;
    CGRect reference = CGRectIntersection(card.superview.bounds,
                      [window convertRect:window.bounds toView:card.superview]);
    PXWMGeometry geometry = {PXWMFromRect(card.frame), PXWMFromRect(reference)};
    if (!PXWMValidGeometry(geometry)) return NO;
    *frame = geometry.frame;
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
    if (!PXWMBindingIsActive(context) || stamp.generation != context.generation || context.interacting ||
        !context.savePending || context.pendingGesture != stamp) return;
    PXWMGeometry geometry;
    unsigned key = 0;
    UIView *card = PXWMFindCard(context.canvas);
    CGSize host = card.window.bounds.size, screen = UIScreen.mainScreen.bounds.size;
    BOOL parked = card && card.window &&
        (fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
         fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3);
    if (parked) {
        context.continuityActive=NO; context.continuityMove=NO;
        context.savePending = NO; context.pendingGesture = nil;
        context.generation++;
        PXWMLog(context, @"save_cancelled_parked_window", @{});
        return;
    }
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
        context.continuityActive=NO; context.continuityMove=NO;
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
        context.continuityActive=NO; context.continuityMove=NO;
        context.savePending = NO;
        PXWMLog(context, @"save_skipped_direction_change", @{ @"known":@(orientationKnown), @"started":@(orientation), @"current":@(key) });
        return;
    }
    if (!PXWMMayStoreGesture(stamp.orientationKnown, stamp.orientation, key,
                              stamp.generation, context.generation, NO) ||
        !PXWMMayCommitGesture(stamp.orientationKnown, stamp.orientation, key,
                              stamp.generation, context.generation)) {
        context.continuityActive=NO; context.continuityMove=NO;
        context.savePending = NO;
        PXWMLog(context, @"save_skipped_direction_change", @{ @"known":@(stamp.orientationKnown),
                   @"started":@(stamp.orientation), @"current":@(key), @"samples":@(stamp.samples) });
        return;
    }
    context.savePending = NO;
    NSDictionary *snapshot = PXWindowMemoryStore.shared.snapshot;
    if (!PXWMMaySave([snapshot[@"enabled"] boolValue], stamp.epoch,
                    [snapshot[@"epoch"] unsignedLongLongValue], !animation, normal, YES)) {
        context.continuityActive=NO; context.continuityMove=NO;
        PXWMLog(context, @"save_skipped_non_normal_or_reset", @{@"gate":@(context.geometryGate),
                   @"normal":@(normal), @"animation":@(animation), @"epoch":@(stamp.epoch),
                   @"currentEpoch":snapshot[@"epoch"] ?: @0}); return;
    }
    context.key = key; context.keyKnown = YES; context.resolved = YES;
    if (!stamp.resizing) {
        PXWMGeometry saved,merged;
        PXWMRect target;
        BOOL hasSize=PXWMContinuityReady(context) && context.continuityKey==key;
        if (hasSize) saved=context.continuityGeometry;
        else hasSize=PXWindowMemoryGeometry(snapshot,context.bundle,key,&saved);
        if (hasSize && PXWMUpdateRememberedPosition(saved,geometry,&merged) &&
            PXWMRestore(merged,geometry.reference,geometry.frame,&target) &&
            !PXWMRectNear(geometry.frame,target,0.5)) {
            context.restoring=YES;
            @try {
                [UIView performWithoutAnimation:^{
                    card.frame=PXWMToRect(target);
                    [card setNeedsLayout]; [card layoutIfNeeded];
                }];
            } @finally { context.restoring=NO; }
            geometry.frame=PXWMFromRect(card.frame);
            if (!PXWMValidGeometry(geometry)) return;
        }
    }
    PXWMArmContinuity(context,geometry,key,stamp.epoch,NO);
    PXWMQueueContentSync(context);
    PXWMLog(context,@"gesture_end_geometry",
        @{@"x":@(geometry.frame.x),@"y":@(geometry.frame.y),
          @"w":@(geometry.frame.width),@"h":@(geometry.frame.height),@"resize":@(stamp.resizing)});
    if (stamp.resizing) {
        BOOL startingKnown = stamp.startingSizeKnown;
        if (!PXWMUserSizeChanged(startingKnown, stamp.startingFrame, geometry.frame)) {
            /* An unreadable starting frame must not throw the gesture away: the
             * window is normal, settled and the user finished a resize. Only a
             * *known* unchanged size is a real no-op. */
            if (startingKnown) {
                PXWMLog(context, @"resize_unchanged_no_save", @{@"startingSizeKnown":@YES});
                return;
            }
            PXWMLog(context, @"resize_unknown_start_saved",
                    @{@"w":@(geometry.frame.width), @"h":@(geometry.frame.height)});
        }
        PXWMLog(context, @"save_user_geometry", @{@"x":@(geometry.frame.x),@"y":@(geometry.frame.y),
                  @"w":@(geometry.frame.width),@"h":@(geometry.frame.height), @"resize":@YES,
                  @"beforeW":@(stamp.startingFrame.width), @"beforeH":@(stamp.startingFrame.height)});
        [PXWindowMemoryStore.shared saveGeometry:geometry bundle:context.bundle orientation:key observedEpoch:stamp.epoch];
    } else {
        PXWMLog(context, @"save_user_position_only", @{@"x":@(geometry.frame.x),@"y":@(geometry.frame.y),
                  @"observedW":@(geometry.frame.width),@"observedH":@(geometry.frame.height), @"resize":@NO});
        [PXWindowMemoryStore.shared savePosition:geometry bundle:context.bundle orientation:key observedEpoch:stamp.epoch];
    }
}

static void PXWMGestureAction(id panel, SEL command, UIGestureRecognizer *gesture,
                             void (*original)(id,SEL,id)) {
    if (!NSThread.isMainThread || ![gesture isKindOfClass:UIGestureRecognizer.class]) {
        if (original) original(panel,command,gesture); return;
    }
    UIGestureRecognizerState phase = gesture.state;
    if (phase==UIGestureRecognizerStateCancelled || phase==UIGestureRecognizerStateFailed) {
        PXWMGesture *cancelled=objc_getAssociatedObject(gesture,PXWMGestureKey);
        cancelled.context.continuityActive=NO;
        cancelled.context.continuityMove=NO;
    }
    if (phase == UIGestureRecognizerStateBegan) {
        PXWMContext *context = PXWMContextForGesture(gesture);
        if (context) {
            PXWMGeometry moveAnchor=context.continuityGeometry;
            unsigned moveKey=context.continuityKey;
            BOOL canKeepSize=PXWMContinuityReady(context);
            NSDictionary *moveSnapshot=PXWindowMemoryStore.shared.snapshot;
            if (!canKeepSize && context.continuityActive &&
                context.continuityGeneration==context.generation &&
                context.continuityEpoch==[moveSnapshot[@"epoch"] unsignedLongLongValue] &&
                [moveSnapshot[@"enabled"] boolValue] && PXWMValidGeometry(moveAnchor))
                canKeepSize=YES; // Retain the known target; Ready still gates every application.
            if (!canKeepSize) canKeepSize=PXWMNormalGeometry(context,&moveAnchor,&moveKey);
            context.generation++; context.interacting = YES; context.resolved = YES; context.savePending = NO;
            context.continuityActive=NO; context.continuityMove=NO;
            context.pendingGesture = nil;
            context.initialTargetActive = NO;
            PXWMGesture *stamp = [PXWMGesture new];
            stamp.context = context; stamp.generation = context.generation;
            stamp.epoch = [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue];
            stamp.resizing = command == NSSelectorFromString(@"resizeHost:");
            PXWMRect startingFrame = {0};
            stamp.startingSizeKnown = PXWMCaptureGestureFrame(context, &startingFrame);
            stamp.startingFrame = startingFrame;
            unsigned startingKey = 0;
            stamp.orientationKnown = PXWMCaptureGestureOrientation(context, &startingKey);
            stamp.orientation = startingKey;
            if (stamp.orientationKnown) { context.keyKnown = YES; context.key = startingKey; }
            if (!stamp.resizing && canKeepSize)
                PXWMArmContinuity(context,moveAnchor,moveKey,stamp.epoch,YES);
            objc_setAssociatedObject(gesture,PXWMGestureKey,stamp,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            PXWMLog(context, @"gesture_begin", @{@"resize":@(command == NSSelectorFromString(@"resizeHost:")),
                     @"geometryKnown":@(stamp.orientationKnown), @"gate":@(context.geometryGate),
                     @"startKnown":@(stamp.startingSizeKnown),@"startX":@(startingFrame.x),
                     @"startY":@(startingFrame.y),@"startW":@(startingFrame.width),
                     @"startH":@(startingFrame.height),@"sizeHeld":@(context.continuityActive)});
        } else {
            PXWMLog(nil, @"gesture_no_bound_window", @{@"resize":@(command == NSSelectorFromString(@"resizeHost:"))});
        }
    }
    if (original) original(panel,command,gesture);
    PXWMGesture *activeStamp=objc_getAssociatedObject(gesture,PXWMGestureKey);
    if (activeStamp && !activeStamp.resizing && phase!=UIGestureRecognizerStateCancelled &&
        phase!=UIGestureRecognizerStateFailed) {
        PXWMContext *moving=activeStamp.context;
        PXWMGeometry observed; unsigned observedKey=0;
        if (PXWMContinuityReady(moving) && PXWMNormalGeometry(moving,&observed,&observedKey) &&
            observedKey==moving.continuityKey) {
            PXWMRect target;
            if (PXWMKeepMoveSize(moving.continuityGeometry,observed,&target)) {
                PXWMGeometry latest=moving.continuityGeometry; latest.frame=target;
                moving.continuityGeometry=latest;
                if (!PXWMRectNear(observed.frame,target,0.5)) {
                    moving.restoring=YES;
                    @try {
                        moving.card.frame=PXWMToRect(target);
                        [moving.card setNeedsLayout]; [moving.card layoutIfNeeded];
                    } @finally { moving.restoring=NO; }
                }
            }
        }
        PXWMQueueContentSync(moving);
    }
    if (phase == UIGestureRecognizerStateEnded || phase == UIGestureRecognizerStateCancelled ||
        phase == UIGestureRecognizerStateFailed) {
        PXWMGesture *stamp = objc_getAssociatedObject(gesture,PXWMGestureKey);
        PXWMContext *context = stamp.context;
        if (stamp && context.generation == stamp.generation) {
            context.interacting = NO;
            if (phase == UIGestureRecognizerStateEnded) {
                context.savePending = YES;
                context.pendingGesture = stamp;
                PXWMSettleSave(stamp,0);
            } else {
                context.savePending = NO;
                context.pendingGesture = nil;
                context.generation++;
                context.continuityActive=NO; context.continuityMove=NO;
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
/* Observe only the existing normal card(s) touched by this native action.
 * A resize which already ended may finish its normal, settled save BEFORE
 * parking; any still-unsettled callback is cancelled, never sampled in dock. */
static void PXWMPrepareForNativePark(UIWindow *window) {
    if (!NSThread.isMainThread) return;
    NSMutableArray<PXWMContext *> *matches = [NSMutableArray array];
    for (PXWMContext *context in PXWMContexts.allObjects) {
        if (!PXWMBindingIsActive(context) || (window && context.canvas.window != window)) continue;
        UIView *card = PXWMFindCard(context.canvas);
        UIWindow *hostWindow = card.window;
        if (!card || !hostWindow || hostWindow.hidden || hostWindow.alpha <= 0.1 ||
            hostWindow.screen != UIScreen.mainScreen || !CGAffineTransformIsIdentity(card.transform)) continue;
        CGSize host = hostWindow.bounds.size, screen = UIScreen.mainScreen.bounds.size;
        if (fabs(fmin(host.width,host.height)-fmin(screen.width,screen.height)) > 3 ||
            fabs(fmax(host.width,host.height)-fmax(screen.width,screen.height)) > 3) continue;
        [matches addObject:context];
    }
    if (matches.count != 1) return;
    PXWMContext *context = matches.firstObject;
    if (context.pendingGesture && context.savePending && !context.interacting)
        PXWMSettleSave(context.pendingGesture,0);
    context.generation++;
    context.savePending = NO; context.pendingGesture = nil;
    context.interacting = NO; context.initialTargetActive = NO;
    context.continuityActive=NO; context.continuityMove=NO;
    PXWMLog(context, @"native_park_no_size_save", @{});
}
static void PXWMDockTapped(id self, SEL command, id sender) {
    if ([sender isKindOfClass:UIView.class])
        PXWMPrepareForNativePark([(UIView *)sender window]);
    if (PXWMOriginalDockTapped) PXWMOriginalDockTapped(self, command, sender);
}
static void PXWMBottomDoubleTapped(id self, SEL command) {
    PXWMPrepareForNativePark(nil);
    if (PXWMOriginalBottomDoubleTapped) PXWMOriginalBottomDoubleTapped(self, command);
}
static void PXWMBottomHeld(id self, SEL command, id gesture) {
    if ([gesture isKindOfClass:UIGestureRecognizer.class] &&
        [(UIGestureRecognizer *)gesture state] == UIGestureRecognizerStateBegan)
        PXWMPrepareForNativePark([(UIGestureRecognizer *)gesture view].window);
    if (PXWMOriginalBottomHeld) PXWMOriginalBottomHeld(self, command, gesture);
}

static PXWMContext *PXWMDetachBinding(id bridge) {
    PXWMContext *context = objc_getAssociatedObject(bridge, PXWMContextKey);
    if (context) {
        PXWMNativeClose(&context->native);
        context.generation++;
        context.pendingGesture = nil; context.savePending = NO;
        context.initialTargetActive = NO;
        context.continuityActive=NO; context.continuityMove=NO;
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
    if (ticket && PXWMContexts) [PXWMContexts addObject:ticket];
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
                /* Remember the card while canvas and bundle still match exactly. */
                if (!ticket.card) ticket.card = PXWMFindCard(ticket.canvas);
                if (!ticket.card) {
                    id hostView = PXWMObject(self, @"hostView");
                    if ([hostView isKindOfClass:UIView.class]) ticket.card = PXWMFindCard(hostView);
                }
                /* Bind is the last moment canvas+bundle still match this open, and
                 * the window has not been shown yet. Hand the remembered frame to
                 * the card here instead of waiting for the vendor's later write. */
                PXWMRect bindTarget; unsigned bindKey = 0;
                BOOL bindRecord = PXWMInitialCardSavedFrame(ticket, &bindTarget, &bindKey);
                if (bindRecord && !ticket.card) {
                    /* Bounded: one record per open says the record existed but the
                     * card was not reachable at bind. */
                    static uint64_t lastBindMissSerial;
                    if (lastBindMissSerial != ticket->native.serial) {
                        lastBindMissSerial = ticket->native.serial;
                        PXWMLog(ticket, @"first_frame_bind_no_card",
                                @{@"serial":@(ticket->native.serial)});
                    }
                }
                if (bindRecord && ticket.card) {
                    UIView *card = ticket.card;
                    PXWMRect nativeFrame = PXWMFromRect(card.frame);
                    ticket.initialNativeFrame = nativeFrame;
                    ticket.initialTarget = bindTarget;
                    ticket.initialTargetKey = bindKey;
                    ticket.key = bindKey;
                    ticket.keyKnown = YES;
                    ticket.initialTargetEpoch =
                        [PXWindowMemoryStore.shared.snapshot[@"epoch"] unsignedLongLongValue];
                    ticket.initialTargetDeadline = CACurrentMediaTime() + 2.0;
                    ticket.initialTargetAppliedAtBind = YES;
                    ticket.initialFrameSubstituted = NO;
                    ticket.initialContentRefreshed = NO;
                    PXWMFirstFrameSnapshot(ticket,bindTarget,1,0);
                    ticket.restoring = YES;
                    [UIView performWithoutAnimation:^{
                        card.frame = PXWMToRect(bindTarget);
                        [card setNeedsLayout]; [card layoutIfNeeded];
                    }];
                    ticket.restoring = NO;
                    PXWMFirstFrameSnapshot(ticket,bindTarget,1,1);
                    ticket.initialTargetActive = YES;
                    ticket.resolved = YES;
                    PXWMGeometry remembered;
                    NSDictionary *bindSnapshot=PXWindowMemoryStore.shared.snapshot;
                    if (PXWindowMemoryGeometry(bindSnapshot,ticket.bundle,bindKey,&remembered))
                        PXWMArmContinuity(ticket,remembered,bindKey,ticket.initialTargetEpoch,NO);
                    PXWMLog(ticket, @"first_frame_memory_applied_at_bind",
                            @{@"fromW":@(nativeFrame.width), @"fromH":@(nativeFrame.height),
                              @"toW":@(bindTarget.width), @"toH":@(bindTarget.height),
                              @"orientationKey":@(bindKey),
                              @"revision":PXWindowMemoryStore.shared.snapshot[@"revision"] ?: @0});
                    /* Same one-shot settle the prepared path uses: if the vendor
                     * animation later lands on the native default, put the
                     * remembered frame back once, without animation. */
                    PXWMScheduleInitialSettle(ticket);
                    PXWMProbeContentGeometry(ticket, 0);
                    PXWMScheduleProbe(ticket, 0);
                }
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
        PXWMReconcileRuntimeFrame(context);
    }
    if (PXWMOriginalLayout) PXWMOriginalLayout(self,command);
    if (NSThread.isMainThread) {
        PXWMReconcileRuntimeFrame(context);
        PXWMQueueContentSync(context);
        PXWMProbeContentGeometry(context,3);
        // Native layout establishes hostCard's default geometry and sourceSize.
        // Apply saved geometry now, before the original returns to its reveal/centering
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
        PXWMReconcileRuntimeFrame(context);
        PXWMQueueContentSync(context);
        if (context->native.entering && !context.resolved)
            PXWMPrepareInitialLayoutWithNativeFrame(context, NULL, YES);
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
        PXWMOriginalClose && PXWMOriginalControllerLayout && PXWMOriginalCardSetFrame &&
        PXWMOriginalRestoreDockTapped && PXWMOriginalExternalOpen) return YES;
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
    SEL cardInit = @selector(initWithFrame:);
    // Optional: if the vendor ever stops creating cards with a frame, the
    // pre-existing first-frame path stays the fallback.
    if (PXCloneClassInstanceMethodMatches(PXWMCardClass, cardInit, @encode(id),
            @[[NSString stringWithUTF8String:@encode(CGRect)]]))
        PXWM_HOOK(PXWMCardClass,cardInit,PXWMCardInit,PXWMOriginalCardInit,id (*)(id,SEL,CGRect));
    SEL setSourceSize = NSSelectorFromString(@"setSourceSize:");
    NSString *sizeType = [NSString stringWithUTF8String:@encode(CGSize)];
    if (PXCloneClassInstanceMethodMatches(bridge, setSourceSize, @encode(void), @[sizeType]))
        PXWM_HOOK(bridge,setSourceSize,PXWMSetSourceSize,PXWMOriginalSetSourceSize,void (*)(id,SEL,CGSize));
    Class dockCoordinator = PXWMVendorClass(@"PXDockCoordinator");
    SEL restoreDock = NSSelectorFromString(@"restoreDockTapped:");
    if (PXCloneClassInstanceMethodMatches(dockCoordinator, restoreDock, @encode(void), objects))
        PXWM_HOOK(dockCoordinator,restoreDock,PXWMRestoreDockTapped,PXWMOriginalRestoreDockTapped,void (*)(id,SEL,id));
    SEL parkDock = NSSelectorFromString(@"dockTapped:");
    SEL parkDouble = NSSelectorFromString(@"bottomDoubleTapped");
    SEL parkHeld = NSSelectorFromString(@"bottomHeld:");
    if (PXCloneClassInstanceMethodMatches(panel, parkDock, @encode(void), objects))
        PXWM_HOOK(panel,parkDock,PXWMDockTapped,PXWMOriginalDockTapped,void (*)(id,SEL,id));
    if (PXCloneClassInstanceMethodMatches(panel, parkDouble, @encode(void), @[]))
        PXWM_HOOK(panel,parkDouble,PXWMBottomDoubleTapped,PXWMOriginalBottomDoubleTapped,void (*)(id,SEL));
    if (PXCloneClassInstanceMethodMatches(panel, parkHeld, @encode(void), objects))
        PXWM_HOOK(panel,parkHeld,PXWMBottomHeld,PXWMOriginalBottomHeld,void (*)(id,SEL,id));
    SEL configured = NSSelectorFromString(@"performConfiguredAction:");
    SEL configuredSearch = NSSelectorFromString(@"performConfiguredAction:fromSearchFavorites:");
    if (PXCloneClassInstanceMethodMatches(bridge, configured, @encode(BOOL), objects))
        PXWM_HOOK(bridge,configured,PXWMConfiguredAction,PXWMOriginalConfiguredAction,BOOL (*)(id,SEL,id));
    if (PXCloneClassInstanceMethodMatches(bridge, configuredSearch, @encode(BOOL),
            @[@"@", [NSString stringWithUTF8String:@encode(BOOL)]]))
        PXWM_HOOK(bridge,configuredSearch,PXWMConfiguredActionSearch,PXWMOriginalConfiguredActionSearch,BOOL (*)(id,SEL,id,BOOL));
    SEL externalOpen = NSSelectorFromString(@"externalOpenApplication:");
    if (PXCloneClassMethodMatches(panel, externalOpen, @encode(void), objects, NULL))
        PXWM_HOOK(object_getClass((id)panel),externalOpen,PXWMExternalOpen,PXWMOriginalExternalOpen,void (*)(id,SEL,id));
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
    [store diagnostic:@"hook_status" details:@{@"ready":@(ready),
        @"cardFrameReady":@(PXWMOriginalCardSetFrame != NULL),
        @"cardInitReady":@(PXWMOriginalCardInit != NULL),
        @"dockExpansionReady":@(PXWMOriginalRestoreDockTapped != NULL),
        @"externalExpansionReady":@(PXWMOriginalExternalOpen != NULL),
        @"actionExpansionReady":@(PXWMOriginalConfiguredAction != NULL && PXWMOriginalConfiguredActionSearch != NULL),
        @"parkBoundaryReady":@(PXWMOriginalDockTapped != NULL && PXWMOriginalBottomDoubleTapped != NULL &&
                              PXWMOriginalBottomHeld != NULL)}];
    return ready;
}

/* The original can bind a valid app window before its source geometry is ready.
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
