// Local CleanStatus integration port: ba31k/ios26-27-anims v1.5.2.
// Upstream attribution: bazik1337 (@bazik1337), https://t.me/ba31k_tweaks
// iOS 26-27 Anims by @bazik1337 — iOS 26/27 app open/close animation on iOS 16 (SpringBoard).
// Animation values measured on iOS 27.0 (24A435).

#import <UIKit/UIKit.h>
#import "LocalCleanStatusAnimationPreferences.h"
#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusAnimationCapabilities.h"
#import "LocalCleanStatusAnimationPolicy.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "LCSAAnimationSupport.h"
#include "LCSASpringMath.h"
#include "LCSAGenieEngine.h"

@interface SBFFluidBehaviorSettings : NSObject <NSCopying>
@property (nonatomic) double dampingRatio;
@property (nonatomic) double response;
@property (nonatomic) double retargetImpulse;
- (unsigned int)highFrameRateReason;
- (CAFrameRateRange)frameRateRange API_AVAILABLE(ios(15.0));
- (void)setFrameRateRange:(CAFrameRateRange)range highFrameRateReason:(unsigned int)reason API_AVAILABLE(ios(15.0));
@end

// Optional display-link reason; requested frame rates never exceed the physical display.
@interface CADisplayLink (LCSAPrivate)
- (void)setHighFrameRateReason:(unsigned int)reason;
@end

static const unsigned int kLCSADefaultFrameRateReason = 0x110001; // switcher layoutSettings
static unsigned int gLCSAFrameRateReason = kLCSADefaultFrameRateReason;

static void LCSARequestHighFrameRate(CADisplayLink *link, unsigned int reason) {
    NSInteger maximum = MAX(1, UIScreen.mainScreen.maximumFramesPerSecond);
    float preferred = (float)MIN(maximum, 120);
    if (@available(iOS 15.0, *)) link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(60.0f, preferred), preferred, preferred);
    else link.preferredFramesPerSecond = maximum;
    if (LCSACall(link, @selector(setHighFrameRateReason:), "v", {@encode(unsigned int)}))
        [link setHighFrameRateReason:reason ?: kLCSADefaultFrameRateReason];
}

@interface SBTransitionSwitcherModifier : NSObject
@end

@interface SBFullScreenToHomeIconZoomSwitcherModifier : SBTransitionSwitcherModifier
- (CGRect)frameForIndex:(NSUInteger)index;
- (BOOL)_isIndexZoomAppLayout:(NSUInteger)index;
- (id)layoutSettingsForTargetCenter:(CGPoint)center;
@end

@interface SBChainableModifierEventResponse : NSObject
+ (id)responseByAppendingResponse:(id)response toResponse:(id)toResponse;
@end
// Must append through this subclass: the composite it builds responds to -type, which
// SBFluidSwitcherRootSwitcherModifier calls on every response (the base class does not).
@interface SBSwitcherModifierEventResponse : SBChainableModifierEventResponse
@end
@interface SBTimerEventSwitcherEventResponse : SBSwitcherModifierEventResponse
- (instancetype)initWithDelay:(double)delay validator:(BOOL (^)(void))validator reason:(NSString *)reason;
@end
@interface SBUpdateLayoutSwitcherEventResponse : SBSwitcherModifierEventResponse
- (instancetype)initWithOptions:(NSUInteger)options updateMode:(NSInteger)updateMode;
@end
@interface SBTimerSwitcherModifierEvent : NSObject
@property (nonatomic, readonly) NSString *reason;
@end

@interface SBFluidSwitcherViewController : UIViewController
- (UIView *)_itemContainerForAppLayoutIfExists:(id)appLayout;
@end

@interface UIView (LCSAItemIdentity)
- (id)appLayout;
@end

typedef struct { CGFloat x, y; } LCSAMeshPoint;
typedef struct { CGFloat x, y, z; } LCSAMeshPoint3D;
typedef struct { LCSAMeshPoint from; LCSAMeshPoint3D to; } LCSAMeshVertex;
typedef struct { unsigned int indices[4]; float w[4]; } LCSAMeshFace;
@interface CAMutableMeshTransform : NSObject
+ (instancetype)meshTransform;
- (void)addVertex:(LCSAMeshVertex)vertex;
- (void)addFace:(LCSAMeshFace)face;
@property (nonatomic) int subdivisionSteps;
@end
@interface CALayer (LCSAMesh)
- (id)meshTransform;
- (void)setMeshTransform:(id)mesh;
@end

typedef struct { double topLeft, bottomLeft, bottomRight, topRight; } LCSACornerRadii;

// Resolve the optional UIKit symbol before use; no unresolved direct private function dependency.
static float (*gLCSADragFunction)(void);
static float LCSADragCoefficient(void) { return gLCSADragFunction ? gLCSADragFunction() : 1.0f; }

// Main-thread immutable preference snapshot. Only the Darwin refresh queue reads storage.
static NSDictionary *gLCSAPreferences;
static BOOL gLCSAReduceMotion = YES;
static BOOL gLCSAAppSupported, gLCSAGenieSupported, gLCSAIconsSupported, gLCSADropletSupported, gLCSASheetSupported;
static std::atomic<double> gLCSAGlobalSlow(1.0);
static std::atomic<bool> gLCSAActive(false);
static BOOL LCSABoolPref(NSString *key, BOOL fallback) {
    if (![NSThread isMainThread]) return fallback;
    NSNumber *v = gLCSAPreferences[key]; return [v isKindOfClass:NSNumber.class] ? v.boolValue : fallback;
}
static double LCSADoublePref(NSString *key, double fallback, double lo, double hi) {
    if (![NSThread isMainThread]) return fallback;
    NSNumber *v = gLCSAPreferences[key]; double n = [v isKindOfClass:NSNumber.class] ? v.doubleValue : fallback;
    return isfinite(n) && n >= lo && n <= hi ? n : fallback;
}
static BOOL LCSAEnabled(void) {
    return [NSThread isMainThread] && !gLCSAReduceMotion && LCSABoolPref(@"animationEnabled", NO);
}
static BOOL LCSAAppEnabled(void) { return gLCSAAppSupported && LCSAEnabled() && LCSABoolPref(@"animationApps", YES); }
static BOOL LCSASpringValid(id obj) {
    return [obj isKindOfClass:NSClassFromString(@"SBFFluidBehaviorSettings")] &&
        LCSANumberType(obj, @"response") && LCSANumberType(obj, @"dampingRatio") && LCSANumberType(obj, @"retargetImpulse");
}
// Reads a scalar ivar by name (MSHookIvar is C++-only).
static NSUInteger LCSAUIntIvar(id obj, const char *name) {
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NSNotFound;
    const char *type = ivar_getTypeEncoding(iv);
    if (!type || (strcmp(type, @encode(NSUInteger)) && strcmp(type, @encode(NSInteger)))) return NSNotFound;
    return *(NSUInteger *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
}

static double LCSASlowFactor(void) { return LCSADoublePref(@"animationSlowFactor", 1, 1, 10); }

// iOS 27 open spring: genieFullScreen{Center,Edge}RowZoomUpSettings = dampingRatio 1.0, response 0.24.
static const double kLCSAOpenDampingRatio = 1.0;
static const double kLCSAOpenResponse = 0.24;

// Settings pane tuning. OpenResponse: the open spring (iOS 27 = 0.24 s). CloseSpeed: divides every close spring
// (tap and swipe; 1 = iOS 27). Droplet: the round "droplet" corners at the start of a transition.
static double LCSAOpenResponse(void) {
    return LCSADoublePref(@"animationOpenResponse", kLCSAOpenResponse, 0.12, 0.5);
}

static double LCSACloseScale(void) {
    return 1.0 / LCSADoublePref(@"animationCloseSpeed", 1.0, 0.5, 2.0);
}

static BOOL LCSADropletEnabled(void) {
    return gLCSADropletSupported && LCSAAppEnabled() && LCSABoolPref(@"animationDroplet", YES);
}
static const double kLCSACloseResponse = 0.336; // iOS 27 and iOS 16 close spring

// iOS 27 "droplet": while the transition animates, the window's corner radius is half of its
// shorter side (215 pt); a timer then resets it (open after 0.06 s, close after 0.12 s:
// genieCornerRadiusTo{App,Home}ResetDelay) and asks for a layout update (options 4, updateMode 3).
static NSString *const kLCSACornerResetReason = @"com.local.cleanstatus.animation.corner-reset";
static const double kLCSAOpenCornerResetDelay = 0.06;
static const double kLCSACloseCornerResetDelay = 0.12;
static const NSUInteger kLCSAPhaseWillUpdate = 2; // SBTransitionPhase: 1 begin, 2 update, 3 end
static const void *kLCSACornerResetKey = &kLCSACornerResetKey;
static const void *kLCSAStartedKey = &kLCSAStartedKey;

static double LCSATimeScale(void) {
    double drag = LCSADragCoefficient();
    return LCSASlowFactor() * (isfinite(drag) && drag > 0 ? drag : 1);
}


// ---------------------------------------------------------------------------------------------
// iOS 27 genie: 9 vertex springs + bounds-progress spring (GenieEngine.h, decoded from SpringBoard 27.0),
// applied as a 3x3 mesh to iOS 16's animated item container (which already supplies the crop/scale).
static BOOL LCSAGenieEnabled(void) { return gLCSAGenieSupported && LCSAAppEnabled() && LCSABoolPref(@"animationGenie", YES); }

// Keep the icon overlay unmeshed so scaled/custom icons and badges retain their existing appearance.
static BOOL LCSAPreserveScaledIconOverlay(void) { return YES; }

static __weak SBFluidSwitcherViewController *gLCSASwitcherVC;

// gLCSASwitcherVC is only learned when SpringBoard itself asks for an item container; until then (or after the switcher
// controller is rebuilt) every genie gave up after 0.2 s without a container. Fall back to the main switcher's content.
static SBFluidSwitcherViewController *LCSASwitcherVC(void) {
    SBFluidSwitcherViewController *vc = gLCSASwitcherVC;
    if (vc) return vc;
    Class main = %c(SBMainSwitcherViewController);
    id shared = LCSAObject(main, "sharedInstance");
    SEL content = @selector(contentViewController);
    id candidate = LCSAObject(shared, sel_getName(content));
    if ([candidate isKindOfClass:%c(SBFluidSwitcherViewController)]) gLCSASwitcherVC = vc = candidate;
    return vc;
}

static double LCSAIntensity(void) { return LCSADoublePref(@"animationGenieIntensity", 1, 0, 2); }

@interface LCSAGenieDriver : NSObject {
@public
    LCSAG27Genie _engine;
    double _shownXY[LCSAG27_V][2];   // mesh on screen (unit square of the container), for the badge copy
    BOOL _hasShownXY;
}
@property (nonatomic, weak) UIView *container;
// The icon crossfade (SBFluidSwitcherIconOverlayView) lives in a sibling SBFluidSwitcherSpaceOverlayAccessoryView
// with the container's exact frame; it gets the same mesh so the icon fades in inside the genie shape (iOS 27
// keeps both inside SBSwitcherGenieEffectView) instead of as a plain square around the deformed window.
@property (nonatomic, weak) UIView *accessory;
@property (nonatomic) int accessorySearches;
@property (nonatomic, strong) id appLayout;
@property (nonatomic) double startTime, lastTime, intensity;
@property (nonatomic) BOOL sawLayout;
@property (nonatomic) double renderedB;
@property (nonatomic) BOOL retargeted;
@property (nonatomic) BOOL preserveScaledIconOverlay;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, weak) id owner;
@property (nonatomic, strong) id previousMesh;
@property (nonatomic, strong) id appliedMesh;
@property (nonatomic, strong) id previousAccessoryMesh, appliedAccessoryMesh;
// Home indicators hidden while the genie runs: they are separate views at the bottom of the screen and do not
// follow the deformed window.
@property (nonatomic, strong) NSHashTable<UIView *> *grabbers;
// iOS 27 keeps the crossfade icon's badge visible, sticking out of the window's corner. Our mesh crops everything to
// the layer's unit square, so the badge is drawn by an unmeshed copy that follows the deformed top-right corner.
@property (nonatomic, weak) UIView *badge;
@property (nonatomic, strong) UIView *badgeCopy;
@property (nonatomic) int badgeSearches;
@property (nonatomic) double iconWidth;   // the home screen icon the window lands in
@property (nonatomic) BOOL opening;
- (void)finish;
@end

static LCSAGenieDriver *gLCSAGenie;

static BOOL LCSASameFrame(CALayer *a, CALayer *b) {
    CGPoint p = a.position, q = b.position;
    CGSize s = a.bounds.size, t = b.bounds.size;
    return fabs(p.x - q.x) < 0.5 && fabs(p.y - q.y) < 0.5 && fabs(s.width - t.width) < 0.5 &&
        fabs(s.height - t.height) < 0.5 && CATransform3DEqualToTransform(a.transform, b.transform);
}

static UIView *LCSAFindAccessory(UIView *container) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFluidSwitcherSpaceOverlayAccessoryView");
    if (!cls || !container.superview) return nil;
    for (UIView *v in container.superview.subviews)
        if ([v isKindOfClass:cls] && !v.hidden && LCSASameFrame(v.layer, container.layer) &&
            LCSACall(v.layer, @selector(meshTransform), "@") && LCSACall(v.layer, @selector(setMeshTransform:), "v", {"@"}) && ![v.layer meshTransform])
            return v;
    return nil;
}
static id LCSAGestureLayoutSettings(id appLayout);

static NSString *const kLCSAGrabberHideKey = @"com.local.cleanstatus.animation.grabber-hide";

static void LCSACollectViews(UIView *v, NSString *className, int depth, NSHashTable<UIView *> *out) {
    Class cls = NSClassFromString(className);
    if (!cls || depth > 14) return;
    if ([v isKindOfClass:cls]) { [out addObject:v]; return; }
    for (UIView *sub in v.subviews) LCSACollectViews(sub, className, depth + 1, out);
}

static void LCSAHideGrabbers(NSHashTable<UIView *> *grabbers) {
    for (UIView *g in grabbers) {
        if ([g.layer animationForKey:kLCSAGrabberHideKey]) continue;
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @0; a.toValue = @0; a.duration = 15.0;
        a.removedOnCompletion = YES;
        [g.layer addAnimation:a forKey:kLCSAGrabberHideKey];
    }
}

static void LCSAShowGrabbers(NSHashTable<UIView *> *grabbers) {
    for (UIView *g in grabbers) [g.layer removeAnimationForKey:kLCSAGrabberHideKey];
}

static const int kLCSAPredictFrames = 8;
static NSString *const kLCSAMeshAnimationKey = @"com.local.cleanstatus.animation.mesh";

@implementation LCSAGenieDriver

- (void)start {
    self.startTime = self.lastTime = CACurrentMediaTime();
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    LCSARequestHighFrameRate(self.link, gLCSAFrameRateReason);
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Compare the actual post-set model object (CALayer may copy on set) before restoring our owned mesh.
    [self.container.layer removeAnimationForKey:kLCSAMeshAnimationKey];
    [self.accessory.layer removeAnimationForKey:kLCSAMeshAnimationKey];
    id current = [self.container.layer meshTransform];
    if (self.appliedMesh && (current == self.appliedMesh || [current isEqual:self.appliedMesh])) self.container.layer.meshTransform = self.previousMesh;
    id accessoryCurrent = [self.accessory.layer meshTransform];
    if (self.appliedAccessoryMesh && (accessoryCurrent == self.appliedAccessoryMesh || [accessoryCurrent isEqual:self.appliedAccessoryMesh])) self.accessory.layer.meshTransform = self.previousAccessoryMesh;
    self.appliedAccessoryMesh = nil; self.previousAccessoryMesh = nil;
    self.appliedMesh = nil;
    self.previousMesh = nil;
    LCSAShowGrabbers(self.grabbers);
    self.grabbers = nil;
    [self.badgeCopy removeFromSuperview];
    self.badgeCopy = nil;
    [CATransaction commit];
}

- (id)meshForEngine:(const LCSAG27Genie *)g {
    double xy[LCSAG27_V][2];
    LCSAG27GenieMesh(g, g->b, xy);
    double gain = self.intensity;
    if (gain != 1.0)
        for (int k = 0; k < LCSAG27_V; k++) {
            xy[k][0] = (double)(k % LCSAG27_N) / (LCSAG27_N - 1) + gain * (xy[k][0] - (double)(k % LCSAG27_N) / (LCSAG27_N - 1));
            xy[k][1] = (double)(k / LCSAG27_N) / (LCSAG27_N - 1) + gain * (xy[k][1] - (double)(k / LCSAG27_N) / (LCSAG27_N - 1));
        }
    CAMutableMeshTransform *mesh = [%c(CAMutableMeshTransform) meshTransform];
    if (!LCSACall(mesh, @selector(setSubdivisionSteps:), "v", {@encode(int)}) ||
        !LCSACall(mesh, @selector(addVertex:), "v", {@encode(LCSAMeshVertex)}) || !LCSACall(mesh, @selector(addFace:), "v", {@encode(LCSAMeshFace)})) return nil;
    mesh.subdivisionSteps = -1;
    for (int i = 0; i < LCSAG27_N; i++) {
        for (int j = 0; j < LCSAG27_N; j++) {
            int k = i * LCSAG27_N + j;
            LCSAMeshVertex vx = { {(double)j / (LCSAG27_N - 1), (double)i / (LCSAG27_N - 1)}, {xy[k][0], xy[k][1], 0} };
            [mesh addVertex:vx];
        }
    }
    for (unsigned int i = 0; i + 1 < LCSAG27_N; i++) {
        for (unsigned int j = 0; j + 1 < LCSAG27_N; j++) {
            unsigned int a = i * LCSAG27_N + j;
            LCSAMeshFace face = { {a, a + 1, a + LCSAG27_N + 1, a + LCSAG27_N}, {0, 0, 0, 0} };
            [mesh addFace:face];
        }
    }
    return mesh;
}

// The mesh is computed on the main thread, but SpringBoard's own main thread stalls for 20-40 ms when a
// transition starts (app activation; measured the same with the tweak off) while the window keeps moving in
// the render server. So besides the model value, each frame hands the render server the predicted meshes of
// the next kLCSAPredictFrames frames as a discrete keyframe animation; the next tick replaces it, and a stall
// plays the prediction instead of freezing the shape.

- (void)applyMeshWithLead:(double)lead at:(double)showTime frame:(double)frame {
    // The presentation crop we synced to belongs to the frame on screen now; the mesh will be shown on
    // the next one, so render the engine `lead` seconds ahead (one display frame).
    LCSAG27Genie ahead = _engine;
    if (lead > 0 && lead < 0.05) LCSAG27GenieStep(&ahead, lead);
    self.renderedB = ahead.b;
    id mesh = [self meshForEngine:&ahead];
    if (!mesh) { [self finish]; return; }
    LCSAG27GenieMesh(&ahead, ahead.b, _shownXY);
    for (int k = 0; k < LCSAG27_V && self.intensity != 1.0; k++) {
        _shownXY[k][0] = (double)(k % LCSAG27_N) / (LCSAG27_N - 1) + self.intensity * (_shownXY[k][0] - (double)(k % LCSAG27_N) / (LCSAG27_N - 1));
        _shownXY[k][1] = (double)(k / LCSAG27_N) / (LCSAG27_N - 1) + self.intensity * (_shownXY[k][1] - (double)(k / LCSAG27_N) / (LCSAG27_N - 1));
    }
    _hasShownXY = YES;
    CAKeyframeAnimation *prediction = nil;
    if (showTime > 0 && frame > 0.004 && frame < 0.034 && !LCSAG27GenieSettled(&ahead)) {
        // Keyframes at most 1/120 s apart: when our link gets 60 Hz while the window animates at 120 (Low Power Mode
        // ends, a missed frame-rate request), the render server shows the in-between meshes instead of holding one
        // shape for two window frames. Same horizon as kLCSAPredictFrames link frames.
        int steps = (int)fmin(ceil(frame * 120 - 0.01), 2) * kLCSAPredictFrames;
        double step = frame * kLCSAPredictFrames / steps;
        NSMutableArray *values = [NSMutableArray arrayWithObject:mesh];
        NSMutableArray *times = [NSMutableArray arrayWithObject:@0];
        LCSAG27Genie future = ahead;
        for (int i = 1; i <= steps; i++) {
            LCSAG27GenieStep(&future, step);
            id predicted = [self meshForEngine:&future];
            if (!predicted) { [self finish]; return; }
            [values addObject:predicted];
            [times addObject:@((double)i / (steps + 1))];
        }
        // Discrete keyframes take one more key time than values: the last mesh holds until the end.
        [times addObject:@1];
        prediction = [CAKeyframeAnimation animationWithKeyPath:@"meshTransform"];
        prediction.values = values;
        prediction.keyTimes = times;
        prediction.calculationMode = kCAAnimationDiscrete;
        prediction.beginTime = showTime;
        prediction.duration = step * (steps + 1);
        prediction.removedOnCompletion = YES;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *layer = self.container.layer;
    id currentMesh = [layer meshTransform];
    if (self.appliedMesh && currentMesh != self.appliedMesh && ![currentMesh isEqual:self.appliedMesh]) { [CATransaction commit]; [self finish]; return; }
    layer.meshTransform = mesh;
    self.appliedMesh = [layer meshTransform];
    if (prediction) [layer addAnimation:prediction forKey:kLCSAMeshAnimationKey];
    else [layer removeAnimationForKey:kLCSAMeshAnimationKey];
    UIView *accessory = self.accessory;
    if (accessory && LCSASameFrame(accessory.layer, layer)) {
        if (!self.appliedAccessoryMesh) self.previousAccessoryMesh = [accessory.layer meshTransform];
        accessory.layer.meshTransform = mesh;
        self.appliedAccessoryMesh = [accessory.layer meshTransform];
        if (prediction) [accessory.layer addAnimation:prediction forKey:kLCSAMeshAnimationKey];
        else [accessory.layer removeAnimationForKey:kLCSAMeshAnimationKey];
    } else if (accessory) {
        [accessory.layer removeAnimationForKey:kLCSAMeshAnimationKey];
        id currentAccessory = [accessory.layer meshTransform];
        if (currentAccessory == self.appliedAccessoryMesh || [currentAccessory isEqual:self.appliedAccessoryMesh]) accessory.layer.meshTransform = self.previousAccessoryMesh;
        self.appliedAccessoryMesh = nil; self.previousAccessoryMesh = nil;
        self.accessory = nil;
    }
    [CATransaction commit];
}

- (void)tick:(CADisplayLink *)link {
    double now = CACurrentMediaTime();
    // The genie outlives its transition phase only to settle (as on iOS 27); a hard cap guards against leaks.
    if (!LCSAAppEnabled() || !LCSAGenieEnabled() || now - self.startTime > fmin(2.0 * LCSATimeScale(), 15.0)) {
        [self finish];
        return;
    }
    if (!self.container) {
        id candidate = [LCSASwitcherVC() _itemContainerForAppLayoutIfExists:self.appLayout];
        if (candidate && ![candidate isKindOfClass:UIView.class]) { [self finish]; return; }
        self.container = candidate;
        if (!self.container) { if (now - self.startTime > 0.2) [self finish]; return; }
        if (!LCSACall(self.container.layer, @selector(meshTransform), "@") || !LCSACall(self.container.layer, @selector(setMeshTransform:), "v", {"@"})) { [self finish]; return; }
        self.previousMesh = [self.container.layer meshTransform];
        if (self.previousMesh) { [self finish]; return; }
        self.grabbers = [NSHashTable weakObjectsHashTable];
        // Only the switcher's own tree: walking every SpringBoard window (home screen included) cost a main-thread
        // stall right when the animation starts.
        SBFluidSwitcherViewController *vc = LCSASwitcherVC();
        UIView *switcherView = vc.isViewLoaded ? vc.view : self.container.superview;
        if (switcherView) LCSACollectViews(switcherView, @"SBHomeGrabberView", 0, self.grabbers);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        LCSAHideGrabbers(self.grabbers);
        [CATransaction commit];
    }
    if (!self.container.window) { [self finish]; return; }
    if (LCSACall(self.container, @selector(appLayout), @encode(id)) &&
        ![[self.container appLayout] isEqual:self.appLayout]) { [self finish]; return; }
    if (!self.preserveScaledIconOverlay && !self.accessory && self.accessorySearches < 240) {
        self.accessorySearches++;
        self.accessory = LCSAFindAccessory(self.container);
    }
    // The icon crossfade in the accessory carries the badge, which sticks out of the icon (x 49, y -11 on 64 pt) and
    // would be cut by the mesh. The crossfade icon can be added after the accessory is found, so look every frame
    // until the badge shows up: the original is hidden and, when closing, an unmeshed copy drawn (see badgeCopy).
    if (self.accessory && !self.badge && self.badgeSearches < 240) {
        self.badgeSearches++;
        NSHashTable<UIView *> *badges = [NSHashTable weakObjectsHashTable];
        LCSACollectViews(self.accessory, @"SBIconBadgeView", 0, badges);
        UIView *badge = nil;
        for (UIView *b in badges) if (!b.hidden && b.bounds.size.width > 1) { badge = b; break; }
        if (badge) {
            self.badge = badge;
            for (UIView *b in badges) [self.grabbers addObject:b];
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            LCSAHideGrabbers(self.grabbers);
            [CATransaction commit];
        }
    }
    if (self.badge && !self.badgeCopy && !self.opening) [self makeBadgeCopy];
    double dt = fmax(0, now - self.lastTime);
    self.lastTime = now;
    [self advance:dt];
    if (!self.link) return; // finished inside advance
    BOOL ownerRunning = self.owner && LCSAUIntIvar(self.owner, "_transitionPhase") == kLCSAPhaseWillUpdate;
    if (LCSAG27GenieSettled(&_engine) && (!ownerRunning || now - self.startTime > 0.15)) { [self finish]; return; }
    BOOL tracking = self.sawLayout && self.owner &&
        LCSAUIntIvar(self.owner, "_transitionPhase") == kLCSAPhaseWillUpdate;
    double frame = link.targetTimestamp - link.timestamp;
    [self applyMeshWithLead:tracking ? frame : 0 at:link.targetTimestamp frame:frame];
    [self placeBadgeCopy];
}

// Snapshot of the badge, drawn above the meshed accessory. Material-based badges
// can supply a live copy because renderInContext cannot capture backdrop layers.
- (void)makeBadgeCopy {
    UIView *badge = self.badge, *acc = self.accessory;
    if (!badge || !acc.superview || badge.bounds.size.width < 1) return;
    SEL snapshot = NSSelectorFromString(@"is18_transitionSnapshotView");
    if (LCSACall(badge, snapshot, @encode(id)))
        self.badgeCopy = ((UIView *(*)(id, SEL))objc_msgSend)(badge, snapshot);
    if (!self.badgeCopy) {
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:badge.bounds];
        UIImage *image = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [badge.layer renderInContext:ctx.CGContext];
        }];
        self.badgeCopy = [[UIImageView alloc] initWithImage:image];
    }
    self.badgeCopy.userInteractionEnabled = NO;
    self.badgeCopy.layer.opacity = 0;
    [acc.superview insertSubview:self.badgeCopy aboveSubview:acc];
}

// Badge copy: the badge's offset from the icon's top-right corner, hung on that corner of the deformed mesh, in the
// accessory's on-screen (presentation) geometry; alpha = the crossfade's.
- (void)placeBadgeCopy {
    UIView *copy = self.badgeCopy, *badge = self.badge, *acc = self.accessory;
    if (!copy) return;
    if (self.opening || !badge || !acc || !_hasShownXY || !copy.superview) { copy.layer.opacity = 0; return; }
    CALayer *AP = acc.layer.presentationLayer ?: acc.layer, *SP = copy.superview.layer.presentationLayer ?: copy.superview.layer;
    CGRect ab = acc.bounds;
    CGRect r = [badge convertRect:badge.bounds toView:acc];
    // top-right vertex of the mesh (row 0, column N-1), in accessory bounds coordinates
    const double *tr = _shownXY[LCSAG27_N - 1];
    CGPoint corner = CGPointMake(ab.origin.x + tr[0] * ab.size.width, ab.origin.y + tr[1] * ab.size.height);
    CGPoint o = CGPointMake(corner.x + (CGRectGetMinX(r) - CGRectGetMaxX(ab)), corner.y + (CGRectGetMinY(r) - CGRectGetMinY(ab)));
    CGPoint e = CGPointMake(o.x + r.size.width, o.y + r.size.height);
    CGPoint so = [AP convertPoint:o toLayer:SP], se = [AP convertPoint:e toLayer:SP];
    // 16 fades the crossfade icon in right at release, while the window is still big: following that alpha put a
    // huge badge over the app. The copy fades in with the window's size instead: invisible at twice the icon's
    // width, fully shown once the window is icon-sized (27 shows the badge only as the window turns into the icon).
    CGPoint a0 = [AP convertPoint:ab.origin toLayer:SP];
    CGPoint a1 = [AP convertPoint:CGPointMake(CGRectGetMaxX(ab), ab.origin.y) toLayer:SP];
    double shownW = hypot(a1.x - a0.x, a1.y - a0.y), iw = self.iconWidth > 1 ? self.iconWidth : 64;
    double alpha = fmin(fmax((2 * iw - shownW) / iw, 0), 1);
    for (UIView *v = badge.superview; v && alpha > 0; v = v.superview) {
        CALayer *P = v.layer.presentationLayer ?: v.layer;
        alpha *= P.opacity * (v.hidden ? 0 : 1);
        if (v == acc) break;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    copy.layer.bounds = badge.bounds;
    copy.layer.transform = CATransform3DMakeScale(fabs(se.x - so.x) / badge.bounds.size.width,
                                                fabs(se.y - so.y) / badge.bounds.size.height, 1);
    copy.layer.position = CGPointMake((so.x + se.x) / 2, (so.y + se.y) / 2);
    copy.layer.opacity = alpha;
    [CATransaction commit];
}

// iOS 27 drives the bounds progress with the same spring as the window frame, so the counter-scale always
// matches the crop. iOS 16's frame spring differs (close is slower, open starts a frame later), so the
// engine follows the container's live crop: b_measured = (H - h) / (H - w) of the presentation bounds.
- (void)advance:(double)dt {
    CALayer *layer = self.container.layer.presentationLayer ?: self.container.layer;
    CGSize size = layer.bounds.size, screen = UIScreen.mainScreen.bounds.size;
    double H = screen.height, w = size.width, h = size.height;
    BOOL valid = w > 1 && H > w + 1 && h > w - 1 && h < H + 1 && fabs(w - screen.width) < 1;
    double bMeas = valid ? LCSAG27Clamp((H - h) / (H - w), 0, 1) : NAN;
    // Before the zoom layout lands, an opening container still has the full window bounds.
    if (valid && !self.sawLayout) {
        if (!self.retargeted && _engine.bTarget == 0 && h > H - 0.5) return;
        else self.sawLayout = YES;
    }
    if (!valid) { LCSAG27GenieStep(&_engine, dt); return; }
    BOOL ownerRunning = self.owner && LCSAUIntIvar(self.owner, "_transitionPhase") == kLCSAPhaseWillUpdate;
    // FollowBounds itself falls back to wall-clock time while a reversed crop still moves away from
    // the target, so retargeted genies stay locked to the window too.
    if (!ownerRunning) LCSAG27GenieStep(&_engine, dt);
    else LCSAG27GenieFollowBounds(&_engine, bMeas, dt);
}

- (void)finish {
    [self stop];
    if (gLCSAGenie == self) gLCSAGenie = nil;
}

@end

// Starts (or retargets, when the same app's genie is still in flight) the genie for a zoom modifier.
static void LCSAStartGenie(id modifier, BOOL opening, CGRect icon, id appLayout, double response, double zeta) {
    CGRect window = UIScreen.mainScreen.bounds;
    double W = window.size.width, H = window.size.height;
    double cx = CGRectGetMidX(icon), cy = CGRectGetMidY(icon), iw = icon.size.width;
    BOOL preserveScaledIconOverlay = LCSAPreserveScaledIconOverlay();
    LCSAGenieDriver *genie = gLCSAGenie;
    // Only a genie that is still moving is retargeted. An open that already settled (iOS 16 keeps its
    // transition in phase 2 for a while, so the driver may still be alive) must not turn the next close
    // into a "retarget": that path ran on wall-clock time and drifted from the window's real crop.
    // The live driver must also still hold the window's current container: SpringBoard can rebuild it between the open
    // and a quick close, and a retargeted driver bound to the old view finished on its next frame (no genie at all).
    UIView *current = genie.container ? [LCSASwitcherVC() _itemContainerForAppLayoutIfExists:appLayout] : nil;
    if (genie && genie.preserveScaledIconOverlay == preserveScaledIconOverlay &&
        genie.appLayout && [genie.appLayout isEqual:appLayout] && genie.link &&
        !LCSAG27GenieSettled(&genie->_engine) && (!genie.container || genie.container == current)) {
        // iOS 27 retargets the live vertex springs (retargetImpulse 0) instead of restarting.
        LCSAG27GenieRetarget(&genie->_engine, !opening, cx, cy, iw, W, H, response, zeta);
        genie.owner = modifier;
        genie.startTime = CACurrentMediaTime();
        genie.lastTime = genie.startTime;
        genie.retargeted = YES;
        genie.opening = opening;
        genie.intensity = LCSAIntensity();
        genie.sawLayout = NO;
        return;
    }
    [genie finish];
    genie = [LCSAGenieDriver new];
    genie.owner = modifier;
    genie.appLayout = appLayout;
    genie.preserveScaledIconOverlay = preserveScaledIconOverlay;
    genie.intensity = LCSAIntensity();
    LCSAG27GenieStart(&genie->_engine, !opening, cx, cy, iw, W, H, response, zeta);
    genie.iconWidth = iw;
    genie.opening = opening;
    gLCSAGenie = genie;
    [genie start];
}

%group LCSAApps
%hook SBFullScreenToHomeIconZoomSwitcherModifier

- (id)layoutSettingsForTargetCenter:(CGPoint)center {
    id settings = %orig;
    if (!LCSAAppEnabled() || !LCSASpringValid(settings)) return settings;
    NSUInteger direction = LCSAUIntIvar(self, "_direction"); // 0 = home -> app (open), 1 = app -> home
    if (direction > 1) return settings;
    double slow = LCSASlowFactor(), closeScale = direction == 0 ? 1.0 : LCSACloseScale();
    if (direction != 0 && slow == 1.0 && closeScale == 1.0) return settings;
    SBFFluidBehaviorSettings *tuned = LCSACall(settings, @selector(copy), @encode(id)) ? [settings copy] : nil;
    if (!tuned || tuned == settings || !LCSASpringValid(tuned)) return settings;
    // Preserve the original spring range on the copy, capped to the physical display.
    if (@available(iOS 15.0, *))
        if (LCSACall(settings, @selector(frameRateRange), @encode(CAFrameRateRange)) && LCSACall(settings, @selector(highFrameRateReason), @encode(unsigned int)) &&
            LCSACall(tuned, @selector(setFrameRateRange:highFrameRateReason:), "v", {@encode(CAFrameRateRange), @encode(unsigned int)}))
        {
            CAFrameRateRange range = [settings frameRateRange];
            float cap = (float)MAX(1, UIScreen.mainScreen.maximumFramesPerSecond);
            range.maximum = fmin(range.maximum, cap); range.preferred = fmin(range.preferred, range.maximum); range.minimum = fmin(range.minimum, range.maximum);
            if (isfinite(range.minimum) && isfinite(range.maximum) && isfinite(range.preferred) && range.maximum > 0)
                [tuned setFrameRateRange:range highFrameRateReason:[settings highFrameRateReason]];
        }
    if (direction == 0) {
        LCSASetSavedNumber(tuned, @"dampingRatio", kLCSAOpenDampingRatio, @"app");
        LCSASetSavedNumber(tuned, @"response", LCSAOpenResponse() * slow, @"app");
    } else {
        LCSASetSavedNumber(tuned, @"response", tuned.response * slow * closeScale, @"app");
    }
    return tuned;
}

- (id)transitionWillBegin {
    if (LCSAAppEnabled()) {
        objc_setAssociatedObject(self, kLCSAStartedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kLCSACornerResetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return %orig;
}

- (id)handleTimerEvent:(SBTimerSwitcherModifierEvent *)event {
    id response = %orig;
    if (!LCSADropletEnabled() || ![LCSAObject(event, "reason") isEqualToString:kLCSACornerResetReason]) return response;
    if (!LCSADropletEnabled() || LCSAUIntIvar(self, "_transitionPhase") != kLCSAPhaseWillUpdate) return response;
    objc_setAssociatedObject(self, kLCSACornerResetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SBUpdateLayoutSwitcherEventResponse *update = [[%c(SBUpdateLayoutSwitcherEventResponse) alloc] initWithOptions:4 updateMode:3];
    return LCSACall(update, @selector(type), @encode(NSInteger)) ? [%c(SBSwitcherModifierEventResponse) responseByAppendingResponse:update toResponse:response] : response;
}

- (LCSACornerRadii)cornerRadiiForIndex:(NSUInteger)index {
    LCSACornerRadii radii = %orig;
    if (!LCSAAppEnabled() || !LCSADropletEnabled() || ![self _isIndexZoomAppLayout:index]) return radii;
    if (LCSAUIntIvar(self, "_transitionPhase") != kLCSAPhaseWillUpdate) return radii;
    if (objc_getAssociatedObject(self, kLCSACornerResetKey)) return radii;
    // The droplet also ends on the clock: if the reset timer is dropped (its validator fails on an interrupted or
    // very short transition), the window would otherwise land in the icon as a circle (r = half its side).
    NSNumber *started = objc_getAssociatedObject(self, kLCSAStartedKey);
    double delay = (LCSAUIntIvar(self, "_direction") == 1 ? kLCSACloseCornerResetDelay : kLCSAOpenCornerResetDelay) * LCSATimeScale();
    if ([started isKindOfClass:NSNumber.class] && started.doubleValue > 1 && CACurrentMediaTime() - started.doubleValue > delay + 0.05)
        return radii;
    CGRect frame = [self frameForIndex:index];
    double r = MIN(CGRectGetWidth(frame), CGRectGetHeight(frame)) * 0.5;
    if (!isfinite(r) || r <= 0) return radii;
    return (LCSACornerRadii){r, r, r, r};
}

%end
%end

// The droplet window must start when the animation does. On iOS 16 that is phase 2
// (transitionWillUpdate, implemented by the superclass); phase 1 can last ~80 ms while the app launches.
%group LCSAApps
%hook SBTransitionSwitcherModifier

- (id)transitionWillUpdate {
    id response = %orig;
    if (!LCSAAppEnabled() || ![self isKindOfClass:%c(SBFullScreenToHomeIconZoomSwitcherModifier)]) return response;
    NSUInteger direction = LCSAUIntIvar(self, "_direction");
    if (direction > 1 || objc_getAssociatedObject(self, kLCSAStartedKey)) return response;
    objc_setAssociatedObject(self, kLCSAStartedKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kLCSACornerResetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    double delay = (direction == 1 ? kLCSACloseCornerResetDelay : kLCSAOpenCornerResetDelay) * LCSATimeScale();
    if (LCSADropletEnabled()) {
        __weak id weakSelf = self;
        SBTimerEventSwitcherEventResponse *timer = [[%c(SBTimerEventSwitcherEventResponse) alloc]
            initWithDelay:delay validator:^BOOL {
                id owner = weakSelf;
                return owner && LCSADropletEnabled() && LCSAUIntIvar(owner, "_transitionPhase") == kLCSAPhaseWillUpdate;
            } reason:kLCSACornerResetReason];
        if (LCSACall(timer, @selector(type), @encode(NSInteger))) response = [%c(SBSwitcherModifierEventResponse) responseByAppendingResponse:timer toResponse:response];
    }

    if (LCSAGenieEnabled()) {
        Ivar iconIvar = class_getInstanceVariable(object_getClass(self), "_homeScreenIconFrame");
        Ivar layoutIvar = class_getInstanceVariable(object_getClass(self), "_appLayout");
        NSUInteger iconSize = 0;
        if (iconIvar) NSGetSizeAndAlignment(ivar_getTypeEncoding(iconIvar), &iconSize, NULL);
        if (iconIvar && layoutIvar && iconSize == sizeof(CGRect) &&
            LCSAEncodingMatches(ivar_getTypeEncoding(iconIvar), @encode(CGRect)) &&
            LCSAEncodingMatches(ivar_getTypeEncoding(layoutIvar), @encode(id))) {
            CGRect icon = *(CGRect *)((uint8_t *)(__bridge void *)self + ivar_getOffset(iconIvar));
            CGRect window = UIScreen.mainScreen.bounds;
            if (!CGRectIsEmpty(icon) && !CGRectIsInfinite(icon) &&
                isfinite(icon.origin.x) && isfinite(icon.origin.y) &&
                isfinite(icon.size.width) && isfinite(icon.size.height) &&
                CGRectIntersectsRect(icon, window) && window.size.height > window.size.width) {
                BOOL opening = direction == 0;
                double spring = opening ? LCSAOpenResponse() : kLCSACloseResponse * LCSACloseScale(), zeta = 1.0;
                id appLayout = object_getIvar(self, layoutIvar);
                // iOS 27 genie attributes carry layoutSettings: the zoom spring, or for a swipe-to-home the
                // gesture's layout spring (homeGesture{Top,Bottom}RowZoomDownLayoutSettings, ratio 1.1, response
                // scaled by the lift-off velocity) set by -[SBGestureInitiatedIconZoom… genieAttributesForAppLayout:].
                SBFFluidBehaviorSettings *settings = opening ? nil : LCSAGestureLayoutSettings(appLayout);
                if (!settings)
                    settings = [(SBFullScreenToHomeIconZoomSwitcherModifier *)self
                        layoutSettingsForTargetCenter:CGPointMake(CGRectGetMidX(icon), CGRectGetMidY(icon))];
                if (LCSASpringValid(settings) && settings.response > 0.05 && settings.response < 5) {
                    spring = settings.response;
                    if (settings.dampingRatio > 0.3 && settings.dampingRatio < 3) zeta = settings.dampingRatio;
                }
                gLCSAFrameRateReason = LCSACall(settings, @selector(highFrameRateReason), @encode(unsigned int))
                    ? [settings highFrameRateReason] : kLCSADefaultFrameRateReason;
                double drag = LCSADragCoefficient();
                if (!isfinite(drag) || drag <= 0) drag = 1;
                spring *= drag;
                LCSAStartGenie(self, opening, icon, appLayout, spring, zeta);
            }
        }
    }
    return response;
}

%end
%end

// Swipe-to-home: SBHomeGestureToZoomDownSwitcherModifier adds an SBGestureInitiatedIconZoomAnimationAttributes-
// SwitcherModifier (iOS 16 and 27 alike) with its own layout/position/scale springs. iOS 27 additionally hands its
// layout spring to the genie and to the corner radius (decomp/HomeGesture, …genieAttributesForAppLayout: and
// …animationAttributesForLayoutElement:). The springs themselves get iOS 27 values in LCSAApplyIOS27Settings.
@interface SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier : NSObject
- (id)_layoutSettings;
@end

static __weak SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier *gLCSAGestureZoom;

static id LCSAGestureLayoutSettings(id appLayout) {
    SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier *gesture = gLCSAGestureZoom;
    if (!LCSAAppEnabled() || !gesture || !appLayout || !LCSACall(gesture, @selector(_layoutSettings), @encode(id))) return nil;
    if (![LCSAObjectIvar(gesture, "_appLayout") isEqual:appLayout]) return nil;
    id settings = [gesture _layoutSettings];
    return [settings isKindOfClass:%c(SBFFluidBehaviorSettings)] ? settings : nil;
}

%group LCSAApps
%hook SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier
- (id)initWithAppLayout:(id)appLayout gestureEdge:(NSUInteger)edge liftOffVelocity:(CGPoint)velocity {
    id result = %orig;
    if (result && LCSAAppEnabled()) gLCSAGestureZoom = result;
    return result;
}


%end
%end

// iOS 27.0 values of SBFluidSwitcherAnimationSettings that differ from iOS 16.2 (logs/*AnimationSettings*,
// diffed 2026-10-05). Applied after PTSettings sets its defaults, so they stay in effect for the session.
@interface SBFluidSwitcherAnimationSettings : NSObject
@end

static NSHashTable<id> *gLCSAAppSettings;
static const void *kLCSAOwnedSpringsKey = &kLCSAOwnedSpringsKey;
static void LCSARestoreAppSettings(id root) {
    LCSARestoreNumberObject(root, @"app");
    NSHashTable *children = objc_getAssociatedObject(root, kLCSAOwnedSpringsKey);
    for (id child in children.allObjects) LCSARestoreNumberObject(child, @"app");
    objc_setAssociatedObject(root, kLCSAOwnedSpringsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void LCSASetSpring(id root, NSString *key, double ratio, double response, double impulse) {
    SBFFluidBehaviorSettings *spring = LCSAObject(root, key.UTF8String);
    if (!LCSASpringValid(spring)) return;
    NSHashTable *children = objc_getAssociatedObject(root, kLCSAOwnedSpringsKey);
    if (!children) { children = [NSHashTable weakObjectsHashTable]; objc_setAssociatedObject(root, kLCSAOwnedSpringsKey, children, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    [children addObject:spring];
    if (ratio > 0) LCSASetSavedNumber(spring, @"dampingRatio", ratio, @"app");
    if (response > 0) LCSASetSavedNumber(spring, @"response", response, @"app");
    if (impulse >= 0) LCSASetSavedNumber(spring, @"retargetImpulse", impulse, @"app");
}
static void LCSASetValue(id root, NSString *key, double value) { LCSASetSavedNumber(root, key, value, @"app"); }

static double kLCSANoBounceResponseScale = 0.7;
static const double kLCSAZoomDownResponseMultiplier = 0.8;

static BOOL LCSAGestureBounce(void) { return LCSABoolPref(@"animationGestureBounce", YES); }

static void LCSAApplyIOS27Settings(id s) {
    if (!s || !LCSAAppEnabled()) return;
    if (!gLCSAAppSettings) gLCSAAppSettings = [NSHashTable weakObjectsHashTable];
    [gLCSAAppSettings addObject:s];
    // Home-gesture zoom springs: no retarget kick, top-row position 0.8 / scale 0.84 damping.
    for (NSString *row in @[@"TopRow", @"BottomRow"])
        for (NSString *kind in @[@"Layout", @"Position", @"Scale"])
            LCSASetSpring(s, [NSString stringWithFormat:@"homeGesture%@ZoomDown%@Settings", row, kind], -1, -1, 0);
    LCSASetSpring(s, @"homeGestureTopRowZoomDownPositionSettings", 0.8, 0.45, 0);
    LCSASetSpring(s, @"homeGestureTopRowZoomDownScaleSettings", 0.84, 0.55, 0);
    // iOS 27's zoom-down position/scale springs are slightly underdamped (0.8-0.86): the icon overshoots ~4 pt
    // up/left and 3% in scale before settling (measured identically on 27 and here). Kept by default (exactly 27);
    // GestureBounce = NO makes them critically damped so the window lands in the icon without the "jelly".
    // A critically damped spring arrives later than the bouncy one, so the responses are shortened too
    // (iOS 27 values x kLCSANoBounceResponseScale) to land in about the same time as 27's first arrival.
    if (!LCSAGestureBounce()) {
        LCSASetSpring(s, @"homeGestureTopRowZoomDownPositionSettings", 1.0, 0.45 * kLCSANoBounceResponseScale, 0);
        LCSASetSpring(s, @"homeGestureTopRowZoomDownScaleSettings", 1.0, 0.55 * kLCSANoBounceResponseScale, 0);
        LCSASetSpring(s, @"homeGestureBottomRowZoomDownPositionSettings", 1.0, 0.55 * kLCSANoBounceResponseScale, 0);
        LCSASetSpring(s, @"homeGestureBottomRowZoomDownScaleSettings", 1.0, 0.55 * kLCSANoBounceResponseScale, 0);
    }
    LCSASetSpring(s, @"homeGestureCenterRowZoomUpSettings", -1, -1, 0);
    LCSASetSpring(s, @"homeGestureEdgeRowZoomUpSettings", -1, -1, 0);
    // Home screen fade: critically damped and faster (0.601 / 0.444 on iOS 16).
    LCSASetSpring(s, @"homeScreenOpacitySettings", 1.0, 0.23, -1);
    // The wallpaper no longer zooms behind an open app (1.2 on iOS 16); icons still recede to 0.88.
    LCSASetValue(s, @"wallpaperScaleInApplication", 1.0);
    LCSASetValue(s, @"crossblurDosidoSmallScale", 0.55);
    LCSASetValue(s, @"siriSwipeDismissClientAnimationsDelay", 0.0);
}

%group LCSAApps
%hook SBFluidSwitcherAnimationSettings
- (void)setDefaultValues {
    if (![NSThread isMainThread]) { %orig; return; }
    LCSARestoreAppSettings(self);
    %orig;
    LCSAApplyIOS27Settings(self);
}
%end
%end

// Finger follow: iOS 27's SBHomeGestureSwitcherModifier reads its minimum card scale from
// homeGestureMinimumCardScale (0.55 in the settings), but on iPhone the live ivar is 0.4, the same constant iOS 16
// hard-codes; retain the original finger tracking.
// So the tracking itself is left stock; the differences are the springs below and in LCSAApplyIOS27Settings.

// iOS 27 scales the response of the swipe-to-home zoom springs (layout, position, scale; interpolated by the
// icon's row) by homeGestureZoomDownScaleMultiplier 0.8 on iPhone (0.75 for widgets), so the window settles into
// the icon faster. iOS 16 has no multiplier. The genie uses the same layout spring.

%group LCSAApps
%hook SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier
- (id)_settingsByInterpolatingBetween:(id)a and:(id)b progress:(double)progress {
    SBFFluidBehaviorSettings *settings = %orig;
    if (!LCSAAppEnabled() || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone || !LCSASpringValid(settings) ||
        settings.response <= 0.05 || !LCSACall(settings, @selector(copy), @encode(id))) return settings;
    SBFFluidBehaviorSettings *copy = [settings copy];
    if (!copy || copy == settings || !LCSASpringValid(copy)) return settings;
    LCSASetSavedNumber(copy, @"response", settings.response * kLCSAZoomDownResponseMultiplier * LCSACloseScale(), @"app");
    return copy;
}

%end
%end

// ---------------------------------------------------------------------------------------------
// iOS 27 icon fly-in when the cover sheet (Notification Center / Lock Screen) is dismissed over the home
// screen (docs/analysis/ANALYSIS_flyin_unlock_open.md, section 1). iOS 16 only flies icons in on some unlocks,
// all icons on one shared spring; iOS 27 hides the icons while the sheet is dragged, then on commit:
//   - perspective m34 = -1/300 around the screen centre, every icon on its own zPosition spring
//     (response 0.42 + t^3/1.4, t = min(distance from centre / 366 pt, 1); damping 0.731) -> centre icons land
//     first, the corners and the dock last;
//   - icons spread from the centre to their places (S: 0 -> 1, response 0.36, critically damped);
//   - icon container alpha S^2 and gaussian blur 6 * (1 - S).
// Everything is a Core Animation spring/keyframe animation, so it runs in the render server.
@interface SBRootFolderController : NSObject
- (UIView *)currentIconListView;
- (UIView *)dockListView;
- (UIView *)view;
- (id)beginModifyingDockOffscreenFractionForReason:(NSString *)reason;
@end
@interface NSObject (LCSADockToken)
- (void)setDockOffscreenFraction:(double)fraction;
- (void)invalidate;
@end
@interface SBHIconManager : NSObject
- (SBRootFolderController *)rootFolderController;
@end
@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBHIconManager *)iconManager;
@end
@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
- (void)setName:(NSString *)name;
@end

// iOS 27 SBCoverSheetIconFlyInAnimator (SpringBoard 27.0, IDA; checked live on the 27 VM, logs/ios27_rec_manual.txt):
// fly-in when the cover sheet / Notification Center is dismissed over the home screen, fly-out when it is pulled
// down over it (27 animates both: animateIconsOnPresentationToo; 16 has neither on NC). Both start on release
// (_finishTransitionToPresented -> prepareToAnimateIconFlyInForPresenting:withVelocity:_viewVelocity).
// - icons: perspective m34 = -1/5082.15 (_perspectiveTransform) about the screen centre; zPosition 10000 <-> 0
//   (behind the camera = not drawn), each icon on its own spring: response 0.42 +/- t^3 / 1.4 (fly-in +, fly-out -,
//   t = |icon - C| / 366), damping min(0.82 - 0.22 (v - 3) / 7, 0.82) (v = _velocity: a hard flick is bouncier),
//   initial z velocity -(screen height x v) / 200;
// - spread S (0 = out, 1 = home), critically damped 0.36 (iconsFlyInResponse / iconsFlyOutResponse), initial
//   velocity 2 v (fly-in) / 4 v (fly-out); position = C + (P - C)(1.7 - 0.7 S), C = (W/2, H/2 - 16);
// - icon list blur R (1 - S), R = 6 fly-in / 10 fly-out; list alpha S^2 on fly-out only;
// - dock: dockOffscreenFraction = 4 x base fraction (1 - progress) on spring 0.548 / 0.74 (page control + search
//   pill follow it); the poster wallpaper gets updateWallpaperAnimationWithIconFlyInTension:72 friction:14.4.
static const double kLCSAFlyCameraDistance = 5082.15;    // -1 / -0.000196767116
static const double kLCSAFlyFarZ = 10000.0;
static const double kLCSAFlyMaxDistance = 366.0;         // iPhone (iPad 666)
static const double kLCSAFlyZResponse = 0.42, kLCSAFlyZCurve = 1.4;
static const double kLCSAFlyZDampingMax = 0.82, kLCSAFlyZDampingSlope = -0.22 / 7, kLCSAFlyZDampingFrom = 3;
static const double kLCSAFlySpreadResponse = 0.36, kLCSAFlySpreadExtra = 0.7, kLCSAFlyCenterLift = 16.0;
static const double kLCSAFlyBlurIn = 6.0, kLCSAFlyBlurOut = 10.0;
static const double kLCSAFlyDockResponse = 0.547826087, kLCSAFlyDockDamping = 0.74, kLCSAFlyDockOffscreen = 4.0;
static NSString *const kLCSAFlyInKey = @"com.local.cleanstatus.animation.fly-in";

static BOOL gLCSAFlyHidden;          // icon list transparent + dock offscreen (sheet over the home screen)
static BOOL gLCSAFlyOutArmed;        // presentation gesture started over the home screen
// The sheet last came to rest presented (not a pull still in progress). SpringBoard starts on the lock screen.
static BOOL gLCSASheetSettledShown = YES;
static NSInteger gLCSAFlyGeneration;

// Settings pane tuning of the icon fly. FlyStrength k (1 = iOS 27) scales how far outside their places the icons
// start (0.7 k). With 27's spread spring (0.36 s) the sideways part is over while the icons are still near the
// camera and hugely magnified, so a wider start alone was invisible: above 1 the spread spring slows down with k too
// and the icons visibly converge as they land. 0 = depth only. FlyBlur: the blur that clears as they land.
static double LCSAFlyStrength(void) {
    return LCSADoublePref(@"animationFlyStrength", 1.0, 0, 3);
}

static double LCSAFlySpreadExtra(void) {
    return kLCSAFlySpreadExtra * LCSAFlyStrength();
}

static double LCSAFlySpreadResponse(void) {
    return kLCSAFlySpreadResponse * fmax(1.0, LCSAFlyStrength());
}

static BOOL LCSAFlyBlurEnabled(void) {
    return LCSABoolPref(@"animationFlyBlur", YES);
}

static BOOL LCSAFlyInEnabled(void) { return gLCSAIconsSupported && LCSAEnabled() && LCSABoolPref(@"animationIcons", YES); }
static SBRootFolderController *LCSAFlyRoot(void) {
    id ic = LCSAObject(%c(SBIconController), "sharedInstance");
    return LCSAObject(LCSAObject(ic, "iconManager"), "rootFolderController");
}
static UIView *LCSAFlyList(void) {
    id list = LCSAObject(LCSAFlyRoot(), "currentIconListView");
    return [list isKindOfClass:UIView.class] && [list window] ? list : nil;
}
static UIView *LCSAFlyDock(void) {
    UIView *dock = LCSAObject(LCSAFlyRoot(), "dockListView");
    if (![dock isKindOfClass:UIView.class]) return nil;
    for (UIView *v = dock; v; v = v.superview) if ([v isKindOfClass:%c(SBDockView)]) return v.window ? v : nil;
    return dock.window ? dock : nil;
}
static BOOL LCSAFlyHomeVisible(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL front = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    return LCSACall(app, front, @encode(id)) && ((id (*)(id, SEL))objc_msgSend)(app, front) == nil && LCSAFlyList() != nil;
}
static id gLCSAFlyDockModifier;
static void LCSAFlyDockLayout(SBRootFolderController *root) {
    SEL lay = NSSelectorFromString(@"layoutIfNeededForDockOffscreenFractionChanged");
    if (LCSACall(gLCSAFlyDockModifier, lay, "v")) ((void (*)(id, SEL))objc_msgSend)(gLCSAFlyDockModifier, lay);
    else if (LCSACall(root, lay, "v")) ((void (*)(id, SEL))objc_msgSend)(root, lay);
    else { UIView *view = LCSAObject(root, "view"); if ([view isKindOfClass:UIView.class]) [view layoutIfNeeded]; }
}
static BOOL LCSAFlyDockOffscreen(BOOL offscreen) {
    if (!offscreen && !gLCSAFlyDockModifier) return YES;
    SBRootFolderController *root = LCSAFlyRoot();
    if (offscreen) {
        if (!gLCSAFlyDockModifier && LCSACall(root, @selector(beginModifyingDockOffscreenFractionForReason:), @encode(id), {@encode(id)})) {
            id candidate = [root beginModifyingDockOffscreenFractionForReason:@"com.local.cleanstatus.animation.fly-in"];
            if (!LCSACall(candidate, @selector(setDockOffscreenFraction:), "v", {@encode(double)}) || !LCSACall(candidate, @selector(invalidate), "v")) {
                if (LCSACall(candidate, @selector(invalidate), "v")) [candidate invalidate];
                return NO;
            }
            gLCSAFlyDockModifier = candidate;
        }
        if (!gLCSAFlyDockModifier) return NO;
        [UIView performWithoutAnimation:^{ [gLCSAFlyDockModifier setDockOffscreenFraction:kLCSAFlyDockOffscreen]; LCSAFlyDockLayout(root); }];
    } else if (gLCSAFlyDockModifier) {
        // Invalidate our reason token: do not set the shared dock's system fraction to a guessed zero.
        [gLCSAFlyDockModifier invalidate]; gLCSAFlyDockModifier = nil;
        [UIView performWithoutAnimation:^{ LCSAFlyDockLayout(root); }];
    }
    return YES;
}

static CASpringAnimation *LCSAFlySpring(NSString *keyPath, id from, id to, double response, double damping, double velocity) {
    CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:keyPath];
    double w = 2 * M_PI / response;
    a.mass = 1;
    a.stiffness = w * w;
    a.damping = 2 * damping * w;
    a.initialVelocity = velocity;
    a.fromValue = from;
    a.toValue = to;
    a.duration = a.settlingDuration;
    a.fillMode = kCAFillModeBackwards;
    return a;
}

static void LCSAFlyCollect(UIView *v, int depth, NSMapTable<UIView *, NSNumber *> *ys) {
    if (depth > 7 || v.hidden) return;
    [ys setObject:@([v convertPoint:CGPointZero toView:nil].y) forKey:v];
    for (UIView *c in v.subviews) LCSAFlyCollect(c, depth + 1, ys);
}

// Re-layout the dock on/off screen without animation, then slide every view the layout moved (dock, page control,
// search pill) with the base fraction spring: the offscreen fraction is linear in position, so an additive spring
// with the same response/damping reproduces 27's animated layout (16 does not animate that layout in a UIKit spring).
static BOOL LCSAFlyDockSlide(BOOL offscreen, double begin, double *longest) {
    UIView *rootView = LCSAObject(LCSAFlyRoot(), "view");
    if (![rootView isKindOfClass:UIView.class]) return NO;
    if (!rootView || (!offscreen && !gLCSAFlyDockModifier)) return NO;
    NSMapTable<UIView *, NSNumber *> *before = [NSMapTable strongToStrongObjectsMapTable], *after = [NSMapTable strongToStrongObjectsMapTable];
    LCSAFlyCollect(rootView, 0, before);
    if (!LCSAFlyDockOffscreen(offscreen)) return NO;
    LCSAFlyCollect(rootView, 0, after);
    for (UIView *v in before) {
        NSNumber *y1 = [after objectForKey:v];
        if (!y1) continue;
        double d = [before objectForKey:v].doubleValue - y1.doubleValue;
        if (fabs(d) < 0.5) continue;
        UIView *sup = v.superview;
        NSNumber *s0 = sup ? [before objectForKey:sup] : nil, *s1 = sup ? [after objectForKey:sup] : nil;
        if (s0 && s1 && fabs((s0.doubleValue - s1.doubleValue) - d) < 0.5) continue;   // moved with its parent
        CASpringAnimation *slide = LCSAFlySpring(@"position.y", @(d), @0, kLCSAFlyDockResponse, kLCSAFlyDockDamping, 0);
        slide.additive = YES;
        slide.beginTime = begin;
        double drag = LCSADragCoefficient();
        if (isfinite(drag) && drag > 1) slide.speed = (float)(1.0 / drag);
        LCSATouchLayer(v.layer);
        [v.layer addAnimation:slide forKey:kLCSAFlyInKey];
        *longest = fmax(*longest, slide.duration);
    }
    return YES;
}

static NSHashTable<UIView *> *gLCSAFlyLists;
static void LCSAFlyTouch(UIView *list) {
    if (!list) return;
    if (!gLCSAFlyLists) gLCSAFlyLists = [NSHashTable weakObjectsHashTable];
    [gLCSAFlyLists addObject:list]; LCSATouchLayer(list.layer);
}
static void LCSAFlyResetList(UIView *list, __unused BOOL keepAnimations) { LCSARestoreLayerTree(list, kLCSAFlyInKey); }
static void LCSAFlyResetOtherLists(UIView *current) {
    for (UIView *list in gLCSAFlyLists.allObjects) {
        if (list == current) continue;
        LCSAFlyResetList(list, NO); [gLCSAFlyLists removeObject:list];
    }
}
static void LCSAFlyCleanup(void) {
    ++gLCSAFlyGeneration; gLCSAFlyHidden = NO; gLCSAFlyOutArmed = NO;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *layer in gLCSALayers.allObjects) LCSARestoreLayer(layer, kLCSAFlyInKey);
    [gLCSAFlyLists removeAllObjects]; LCSAFlyDockOffscreen(NO);
    [CATransaction commit];
}
static void LCSAFlySetHidden(BOOL hidden) {
    if (!hidden) { LCSAFlyCleanup(); return; }
    if (!LCSAFlyInEnabled()) return;
    gLCSAFlyHidden = YES; ++gLCSAFlyGeneration;
    UIView *list = LCSAFlyList(), *dock = LCSAFlyDock();
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    LCSAFlyResetOtherLists(list); LCSAFlyTouch(list); [list.layer removeAnimationForKey:kLCSAFlyInKey];
    LCSASetOpacity(list.layer, 0); LCSATouchLayer(dock.layer);
    BOOL moved = LCSAFlyDockOffscreen(YES);
    if (!moved) LCSASetOpacity(dock.layer, 0);
    [CATransaction commit];
    NSInteger generation = gLCSAFlyGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == gLCSAFlyGeneration) LCSAFlyCleanup();
    });
}

// Time at which a unit spring 1 -> 0 (from rest) first drops below `level`.
static double LCSAFlyCrossing(double response, double damping, double level) {
    double x = 1, v = 0, t = 0, dt = 1.0 / 480;
    while (x > level && t < 3) { LCSAG27SpringStep(&x, &v, 0, response, damping, dt); t += dt; }
    return t;
}

// Widgets and folders draw their background with a backdrop material that samples the wallpaper. Under a filter
// on an ancestor the backdrop sees only the filtered group (not the wallpaper) and the material changes tone, so
// such icons are left out of the blur.
static BOOL LCSAFlyIconHasBackdrop(UIView *iconView) {
    id icon = LCSAObject(iconView, "icon");
    if (!icon) return NO;
    for (NSString *sel in @[@"isWidgetIcon", @"isFolderIcon", @"isWidgetStackIcon"]) {
        SEL s = NSSelectorFromString(sel);
        if (LCSACall(icon, s, @encode(BOOL)) && ((BOOL (*)(id, SEL))objc_msgSend)(icon, s)) return YES;
    }
    NSString *name = NSStringFromClass([icon class]);
    return [name containsString:@"Widget"] || [name containsString:@"Folder"];
}

static BOOL LCSAFlyIconOverflows(UIView *iconView) {
    CGRect bounds = iconView.bounds;
    NSMutableArray<UIView *> *stack = [iconView.subviews mutableCopy];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.hidden || v.alpha < 0.01) continue;
        if ([NSStringFromClass(v.class) containsString:@"Badge"]) {
            CGRect r = [v convertRect:v.bounds toView:iconView];
            if (!CGRectContainsRect(CGRectInset(bounds, -0.5, -0.5), r)) return YES;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

// CAFilter exposes its inputs through its own CAML schema, rather than Objective-C scalar setters.
// Only a newly-created filter with an advertised double input is allowed to receive inputRadius.
static CAFilter *LCSACreateBlur(double radius) {
    Class cls = %c(CAFilter);
    if (!LCSAMethod(cls, @selector(filterWithType:), "@", {"@"}, YES)) return nil;
    id blur = [cls filterWithType:@"gaussianBlur"];
    SEL typeSelector = NSSelectorFromString(@"CAMLTypeForKey:");
    if (!LCSACall(blur, @selector(setName:), "v", {"@"}) || !LCSACall(blur, typeSelector, "@", {"@"}) ||
        !LCSACall(blur, @selector(setValue:forKey:), "v", {"@", "@"})) return nil;
    @try {
        id type = ((id (*)(id, SEL, id))objc_msgSend)(blur, typeSelector, @"inputRadius");
        if (![type isKindOfClass:NSString.class] || ![type isEqualToString:@"double"]) return nil;
        ((void (*)(id, SEL, id))objc_msgSend)(blur, @selector(setName:), @"lcsaGaussianBlur");
        // Schema-checked filter input; no generic KVC fallback.
        [blur setValue:@(radius) forKey:@"inputRadius"];
    } @catch (__unused NSException *exception) { return nil; }
    return blur;
}

// flyIn: S 0 -> 1, icons from behind the camera into place. !flyIn: S 1 -> 0, icons out through the camera.
static void LCSAFlyRun(BOOL flyIn, double velocity) {
    if (!LCSAFlyInEnabled() || !LCSAFlyHomeVisible()) { LCSAFlyCleanup(); return; }
    if (!isfinite(velocity)) velocity = 0;
    // The fly's own Core Animation springs do not see UIKit's drag coefficient: slow them by the same factor.
    double drag = LCSADragCoefficient();
    float flySpeed = isfinite(drag) && drag > 1 ? (float)(1.0 / drag) : 1.0f;
    UIView *list = LCSAFlyList(), *dock = LCSAFlyDock();
    if (!list && !dock) { gLCSAFlyHidden = !flyIn; return; }
    NSInteger generation = ++gLCSAFlyGeneration;
    gLCSAFlyHidden = !flyIn;
    UIWindow *window = (list ?: dock).window;
    CGSize W = window.bounds.size;
    CGPoint screenCenter = CGPointMake(W.width / 2, W.height / 2);
    CGPoint spreadCenterW = CGPointMake(W.width / 2, W.height / 2 - kLCSAFlyCenterLift);
    double begin = CACurrentMediaTime();
    double v = fmin(fmax(velocity, -10), 10);
    double spreadVelocity = (flyIn ? 2 : 4) * v;             // dS/dt at the start (S rises on fly-in, falls on fly-out)
    double spreadResponse = LCSAFlySpreadResponse();
    double towardSpread = flyIn ? spreadVelocity : -spreadVelocity;
    double zVelocity = -(W.height * v) / 200;
    double zDamping = fmin(kLCSAFlyZDampingMax + (v - kLCSAFlyZDampingFrom) * kLCSAFlyZDampingSlope, kLCSAFlyZDampingMax);
    double zFrom = flyIn ? kLCSAFlyFarZ : 0, zTo = flyIn ? 0 : kLCSAFlyFarZ;
    double longest = 0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    LCSAFlyResetOtherLists(list);
    if (list) {
        CALayer *L = list.layer;
        [L removeAnimationForKey:kLCSAFlyInKey];
        // A fly started while another is in flight must not save the perspective it finds as the "original".
        LCSAFlyTouch(list);
        LCSASetFilters(L, nil);
        BOOL backdrops = NO;
        for (UIView *iv in list.subviews)
            if ([iv isKindOfClass:%c(SBIconView)] && !iv.hidden && LCSAFlyIconHasBackdrop(iv)) { backdrops = YES; break; }
        // Perspective about the screen centre: T(-d) * P * T(d), d = centre - layer anchor (list coordinates).
        CGPoint c = [list convertPoint:screenCenter fromView:nil];
        CGPoint anchor = CGPointMake(CGRectGetMidX(list.bounds), CGRectGetMidY(list.bounds));
        CATransform3D P = CATransform3DIdentity;
        P.m34 = -1.0 / kLCSAFlyCameraDistance;
        LCSASetSublayer(L, CATransform3DConcat(CATransform3DConcat(
            CATransform3DMakeTranslation(-(c.x - anchor.x), -(c.y - anchor.y), 0), P),
            CATransform3DMakeTranslation(c.x - anchor.x, c.y - anchor.y, 0)));
        float originalOpacity = LCSAOriginalOpacity(L);
        LCSASetOpacity(L, flyIn ? originalOpacity : 0);

        // Spread S sampled at 60 Hz: list blur R (1 - S), and alpha S^2 on fly-out.
        NSMutableArray *radii = [NSMutableArray array], *alphas = [NSMutableArray array];
        double sTarget = flyIn ? 1 : 0, s = 1 - sTarget, sv = spreadVelocity, dt = 1.0 / 60, R = flyIn ? kLCSAFlyBlurIn : kLCSAFlyBlurOut;
        const int n = 75;
        for (int i = 0; i <= n; i++) {
            double si = i == n ? sTarget : fmin(fmax(s, 0), 1);
            [radii addObject:@(R * (1 - si))];
            [alphas addObject:@(si * si * originalOpacity)];
            LCSAG27SpringStep(&s, &sv, sTarget, spreadResponse, 1, dt);
        }
        NSMutableArray *anims = [NSMutableArray array];
        // One blur on the whole list, or, with widgets/folders on the page, one per plain icon (see above).
        CAFilter *blur = LCSAFlyBlurEnabled() ? LCSACreateBlur(flyIn ? 0 : R) : nil;
        CAKeyframeAnimation *blurAnim = nil;
        if (blur) {
            blurAnim = [CAKeyframeAnimation animationWithKeyPath:@"filters.lcsaGaussianBlur.inputRadius"];
            blurAnim.values = radii; blurAnim.duration = n * dt;
            if (!backdrops) { LCSASetFilters(L, @[blur]); [anims addObject:blurAnim]; }
        }
        if (!flyIn) {
            CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            a.values = alphas; a.duration = n * dt;
            [anims addObject:a];
        }
        if (anims.count) {
            CAAnimationGroup *g = [CAAnimationGroup animation];
            g.animations = anims; g.duration = n * dt; g.beginTime = begin; g.fillMode = kCAFillModeBackwards;
            g.speed = flySpeed;
            [L addAnimation:g forKey:kLCSAFlyInKey];
        }

        CGPoint C = [list convertPoint:spreadCenterW fromView:nil];
        double m = 1 + LCSAFlySpreadExtra();
        double visibleZ = kLCSAFlyCameraDistance * 0.98 / kLCSAFlyFarZ;   // fraction of the far z still drawn
        for (UIView *iv in list.subviews) {
            if (![iv isKindOfClass:%c(SBIconView)] || iv.hidden) continue;
            CALayer *I = iv.layer; LCSATouchLayer(I);
            [I removeAnimationForKey:kLCSAFlyInKey];
            CGPoint p = I.position, pw = [list convertPoint:p toView:nil];
            double t = fmin(hypot(pw.x - spreadCenterW.x, pw.y - spreadCenterW.y) / kLCSAFlyMaxDistance, 1.0);
            double k = t * t * t / kLCSAFlyZCurve;
            // Fly-out: 0.42 - k can go negative; tension (2 pi / r)^2 and friction 2 zeta sqrt(tension) make it |r|.
            double response = fmax(fabs(flyIn ? kLCSAFlyZResponse + k : kLCSAFlyZResponse - k), 0.02);
            CGPoint out = CGPointMake(C.x + (p.x - C.x) * m, C.y + (p.y - C.y) * m);
            // Children of a group run in the group's local time: they start at 0, the group at `begin`.
            CASpringAnimation *z = LCSAFlySpring(@"zPosition", @(I.zPosition + zFrom), @(I.zPosition + zTo), response, zDamping,
                                                 zVelocity / (zTo - zFrom));
            CASpringAnimation *spread = LCSAFlySpring(@"position", [NSValue valueWithCGPoint:flyIn ? out : p],
                                                      [NSValue valueWithCGPoint:flyIn ? p : out], spreadResponse, 1.0, towardSpread);
            // Behind the camera (z > d) 27 draws nothing: transparent while z is beyond the camera.
            double cross = LCSAFlyCrossing(response, zDamping, flyIn ? visibleZ : 1 - visibleZ);
            CAKeyframeAnimation *show = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            // Discrete keyframes need one more key time than values.
            show.values = flyIn ? @[@0, @(I.opacity)] : @[@(I.opacity), @0];
            show.keyTimes = @[@0, @(fmin(cross / z.duration, 1)), @1];
            show.calculationMode = kCAAnimationDiscrete;
            show.duration = z.duration;
            // A filter crops its layer to the bounds, and the badge (SBIconBadgeView inside SBIconImageView at
            // x 49, y -11 on a 64 pt icon) sticks out of every ancestor: badged icons are not blurred.
            BOOL partBlur = backdrops && blurAnim && !LCSAFlyIconHasBackdrop(iv) && !LCSAFlyIconOverflows(iv);
            for (UIView *part in iv.subviews) {
                CALayer *PL = part.layer;
                [PL removeAnimationForKey:kLCSAFlyInKey];
                LCSASetFilters(PL, nil);
                if (!partBlur) continue;
                LCSASetFilters(PL, @[blur]);
                CAKeyframeAnimation *pb = [blurAnim copy];
                pb.beginTime = begin; pb.fillMode = kCAFillModeBackwards;
                pb.speed = flySpeed;
                [PL addAnimation:pb forKey:kLCSAFlyInKey];
            }
            CAAnimationGroup *g = [CAAnimationGroup animation];
            g.animations = flyIn ? @[z, spread, show] : @[spread, z, show];
            g.duration = fmax(z.duration, spread.duration); g.beginTime = begin; g.fillMode = kCAFillModeBackwards;
            g.speed = flySpeed;
            [I addAnimation:g forKey:kLCSAFlyInKey];
            longest = fmax(longest, g.duration);
        }
    }
    if (dock) {
        [dock.layer removeAnimationForKey:kLCSAFlyInKey];
        LCSASetOpacity(dock.layer, LCSAOriginalOpacity(dock.layer));
        if (!LCSAFlyDockSlide(!flyIn, begin, &longest) && !flyIn) LCSASetOpacity(dock.layer, 0);
    }
    [CATransaction commit];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((fmin(fmax(longest, 1.25) / flySpeed, 15) + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == gLCSAFlyGeneration) LCSAFlyCleanup();
    });
}

static NSString *const kLCSASheetKeys[] = {
    @"sameWallpaperInitialTransitionSettings", @"sameWallpaperSubsequentTransitionSettings",
    @"differentWallpaperInitialTransitionSettings", @"differentWallpaperSubsequentTransitionSettings", @"overAppTransitionSettings",
};
static NSHashTable<id> *gLCSASheetParents;
static BOOL gLCSASheetBusy;
static BOOL LCSASheet27Enabled(void) { return gLCSASheetSupported && LCSAFlyInEnabled() && LCSABoolPref(@"animationClearSheet", YES); }
static void LCSASheetApply27(id parent) {
    if (!LCSASheet27Enabled() || !LCSAFlyHomeVisible()) return;
    NSDictionary *home = @{
        @"blursPanel": @NO, @"panelWallpaper": @NO, @"scaleWallpaper": @NO, @"fadesContent": @NO,
        @"darkensContent": @NO, @"trackingWallpaper": @NO, @"orientPanelWallpaper": @NO, @"fadePanelWallpaper": @NO,
        @"fadesCoverSheetContent": @NO,
    };
    NSDictionary *overApp = @{
        @"blursPanel": @NO, @"panelWallpaper": @YES, @"trackingWallpaper": @YES, @"trackingWallpaperParallaxFactor": @0.0,
        @"fadePanelWallpaper": @YES, @"fadesContent": @NO, @"floatingLayerAsWallpaperOverlay": @NO,
    };
    if (!gLCSASheetParents) gLCSASheetParents = [NSHashTable weakObjectsHashTable];
    [gLCSASheetParents addObject:parent];
    for (NSUInteger i = 0; i < sizeof(kLCSASheetKeys) / sizeof(kLCSASheetKeys[0]); ++i) {
        id child = LCSAObject(parent, kLCSASheetKeys[i].UTF8String); if (!child) continue;
        NSMutableDictionary *values = [(i == 4 ? overApp : home) mutableCopy];
        if (i == 1 || i == 2) values[@"floatingLayerAsWallpaperOverlay"] = @NO;
        for (NSString *key in values) LCSASetSavedNumber(child, key, [values[key] doubleValue], @"sheet");
    }
}
static void LCSASheetSync(id parent) {
    if (gLCSASheetBusy || ![NSThread isMainThread] || !parent) return;
    gLCSASheetBusy = YES;
    if (LCSASheet27Enabled() && LCSAFlyHomeVisible()) LCSASheetApply27(parent);
    else LCSARestoreNumbers(@"sheet");
    gLCSASheetBusy = NO;
}

%group LCSASheet
%hook CSCoverSheetTransitionsSettings
- (void)setDefaultValues {
    if (![NSThread isMainThread]) { %orig; return; }
    for (NSUInteger i = 0; i < sizeof(kLCSASheetKeys) / sizeof(kLCSASheetKeys[0]); ++i)
        LCSARestoreNumberObject(LCSAObject(self, kLCSASheetKeys[i].UTF8String), @"sheet");
    %orig;
    if (!gLCSASheetBusy) LCSASheetSync(self);
}
- (id)sameWallpaperInitialTransitionSettings {
    LCSASheetSync(self);
    return %orig;
}
- (id)sameWallpaperSubsequentTransitionSettings {
    LCSASheetSync(self);
    return %orig;
}
- (id)differentWallpaperInitialTransitionSettings {
    LCSASheetSync(self);
    return %orig;
}
- (id)differentWallpaperSubsequentTransitionSettings {
    LCSASheetSync(self);
    return %orig;
}
- (id)overAppTransitionSettings {
    LCSASheetSync(self);
    return %orig;
}
%end
%end

static void LCSACoverFinished(id manager) {
    if (![NSThread isMainThread]) return;
    BOOL presented = LCSABool(manager, "isPresented", NO);
    gLCSASheetSettledShown = presented;
    // Finite completion returns every touched layer and dock token to its original owner.
    // The sheet already occludes icons when presented; do not retain hidden model values indefinitely.
    LCSAFlyCleanup();
    if (!presented) LCSARestoreNumbers(@"sheet");
}

%group LCSAIcons
%hook SBCoverSheetPresentationManager
- (void)coverSheetSlidingViewController:(id)controller prepareForPresentationTransitionForUserGesture:(BOOL)gesture {
    %orig;
    if (![NSThread isMainThread]) return;
    gLCSAFlyOutArmed = gesture && !gLCSAFlyHidden && LCSAFlyInEnabled() && LCSAFlyHomeVisible();
}

- (void)coverSheetSlidingViewController:(id)controller prepareForDismissalTransitionForReversingTransition:(BOOL)reversing forUserGesture:(BOOL)gesture {
    %orig;
    if (![NSThread isMainThread]) return;
    gLCSAFlyOutArmed = NO;
    if (!LCSAFlyInEnabled()) { if (gLCSALayers.count || gLCSAFlyDockModifier) LCSAFlyCleanup(); return; }
    // A released half-way pull reverses into a dismissal: the icons never flew out, so they stay (27 alternates
    // fly-out / fly-in through iconsWereLastAnimatedIn, and does not touch the icons at all while a finger drags the
    // sheet). iOS 16 does not always report such a pull as `reversing`, so also keep them unless the sheet had come to
    // rest presented (lock screen, or a Notification Center that never flew the icons out): only then hide them for
    // the fly-in.
    if (!gLCSAFlyHidden && (reversing || !gLCSASheetSettledShown)) return;
    if (LCSAFlyHomeVisible()) { if (!gLCSAFlyHidden) LCSAFlySetHidden(YES); }
    else if (gLCSAFlyHidden) LCSAFlySetHidden(NO);
}

- (void)coverSheetSlidingViewController:(id)controller committingToEndPresented:(BOOL)presented {
    %orig;
    if (![NSThread isMainThread]) return;
    BOOL armed = gLCSAFlyOutArmed;
    gLCSAFlyOutArmed = NO;
    if (!presented && !gLCSAFlyHidden) return;
    if (presented && !armed) return;   // e.g. a cancelled dismissal: icons stay as they are under the sheet
    // -[SBCoverSheetSlidingViewController _finishTransitionToPresented:...] passes -[... _viewVelocity] (-finger dy/dt
    // / sheet height, clamped to +-10; same in 16) to prepareToAnimateIconFlyInForPresenting:withVelocity:.
    SEL vsel = NSSelectorFromString(@"_viewVelocity");
    double velocity = LCSACall(controller, vsel, @encode(double)) ? ((double (*)(id, SEL))objc_msgSend)(controller, vsel) : 0;
    if (!LCSAFlyInEnabled() || !LCSAFlyHomeVisible()) { if (gLCSAFlyHidden) LCSAFlySetHidden(NO); return; }
    LCSAFlyRun(!presented, velocity);
}

// Cleanup selectors are present in the independent 15.0 dump. All four are required before this group is installed.
- (void)coverSheetSlidingViewControllerCleanupDismissalTransition:(id)controller { %orig; LCSACoverFinished(self); }
- (void)coverSheetSlidingViewControllerCleanupPresentationTransition:(id)controller { %orig; LCSACoverFinished(self); }
- (void)coverSheetSlidingViewControllerCleanupInterstitialTransition:(id)controller { %orig; LCSACoverFinished(self); }
- (void)coverSheetSlidingViewControllerCleanupRubberBandedPresentationTransition:(id)controller { %orig; LCSACoverFinished(self); }

%end
%end

%group LCSAGenie
%hook SBFluidSwitcherViewController

- (id)_itemContainerForAppLayoutIfExists:(id)appLayout {
    if ([NSThread isMainThread] && LCSAGenieEnabled()) gLCSASwitcherVC = self;
    return %orig;
}

%end
%end

// Each Logos group is installed only after every hooked method in that group has a matching ABI.
// Optional object calls repeat the same checks on the actual receiver before sending a private message.
static BOOL LCSAAppABI(void) {
    Class zoom = NSClassFromString(@"SBFullScreenToHomeIconZoomSwitcherModifier");
    Class transition = NSClassFromString(@"SBTransitionSwitcherModifier");
    Class gesture = NSClassFromString(@"SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier");
    Class settings = NSClassFromString(@"SBFluidSwitcherAnimationSettings");
    Class spring = NSClassFromString(@"SBFFluidBehaviorSettings");
    return LCSAMethod(zoom, @selector(layoutSettingsForTargetCenter:), "@", {@encode(CGPoint)}) &&
        LCSAMethod(zoom, @selector(transitionWillBegin), "@") &&
        LCSAMethod(zoom, @selector(handleTimerEvent:), "@", {"@"}) &&
        LCSAMethod(zoom, @selector(cornerRadiiForIndex:), @encode(LCSACornerRadii), {@encode(NSUInteger)}) &&
        LCSAMethod(zoom, @selector(frameForIndex:), @encode(CGRect), {@encode(NSUInteger)}) &&
        LCSAMethod(zoom, @selector(_isIndexZoomAppLayout:), @encode(BOOL), {@encode(NSUInteger)}) &&
        LCSAMethod(transition, @selector(transitionWillUpdate), "@") &&
        LCSAMethod(gesture, @selector(initWithAppLayout:gestureEdge:liftOffVelocity:), "@", {"@", @encode(NSUInteger), @encode(CGPoint)}) &&
        LCSAMethod(gesture, @selector(_settingsByInterpolatingBetween:and:progress:), "@", {"@", "@", @encode(double)}) &&
        LCSAMethod(settings, @selector(setDefaultValues), "v") &&
        LCSAMethod(spring, @selector(response), @encode(double)) && LCSAMethod(spring, @selector(setResponse:), "v", {@encode(double)}) &&
        LCSAMethod(spring, @selector(dampingRatio), @encode(double)) && LCSAMethod(spring, @selector(setDampingRatio:), "v", {@encode(double)}) &&
        LCSAMethod(spring, @selector(retargetImpulse), @encode(double)) && LCSAMethod(spring, @selector(setRetargetImpulse:), "v", {@encode(double)});
}
static BOOL LCSADropletABI(void) {
    Class timer = NSClassFromString(@"SBTimerEventSwitcherEventResponse");
    Class update = NSClassFromString(@"SBUpdateLayoutSwitcherEventResponse");
    Class response = NSClassFromString(@"SBSwitcherModifierEventResponse");
    return LCSAMethod(timer, @selector(initWithDelay:validator:reason:), "@", {@encode(double), "@?", "@"}) &&
        LCSAMethod(update, @selector(initWithOptions:updateMode:), "@", {@encode(NSUInteger), @encode(NSInteger)}) &&
        LCSAMethod(response, @selector(responseByAppendingResponse:toResponse:), "@", {"@", "@"}, YES) &&
        LCSAMethod(response, @selector(type), @encode(NSInteger)) &&
        LCSAMethod(NSClassFromString(@"SBTimerSwitcherModifierEvent"), @selector(reason), "@");
}
static BOOL LCSAGenieABI(void) {
    Class mesh = NSClassFromString(@"CAMutableMeshTransform");
    return LCSAMethod(mesh, @selector(meshTransform), "@", {}, YES) &&
        LCSAMethod(mesh, @selector(addVertex:), "v", {@encode(LCSAMeshVertex)}) &&
        LCSAMethod(mesh, @selector(addFace:), "v", {@encode(LCSAMeshFace)}) &&
        LCSAMethod(mesh, @selector(subdivisionSteps), @encode(int)) && LCSAMethod(mesh, @selector(setSubdivisionSteps:), "v", {@encode(int)}) &&
        LCSAMethod(CALayer.class, @selector(meshTransform), "@") && LCSAMethod(CALayer.class, @selector(setMeshTransform:), "v", {"@"}) &&
        LCSAMethod(NSClassFromString(@"SBFluidSwitcherViewController"), @selector(_itemContainerForAppLayoutIfExists:), "@", {"@"});
}
static BOOL LCSAIconsABI(void) {
    Class manager = NSClassFromString(@"SBCoverSheetPresentationManager");
    Class root = NSClassFromString(@"SBRootFolderController");
    return NSClassFromString(@"SBIconView") &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewController:prepareForPresentationTransitionForUserGesture:), "v", {"@", @encode(BOOL)}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewController:prepareForDismissalTransitionForReversingTransition:forUserGesture:), "v", {"@", @encode(BOOL), @encode(BOOL)}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewController:committingToEndPresented:), "v", {"@", @encode(BOOL)}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewControllerCleanupDismissalTransition:), "v", {"@"}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewControllerCleanupPresentationTransition:), "v", {"@"}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewControllerCleanupInterstitialTransition:), "v", {"@"}) &&
        LCSAMethod(manager, @selector(coverSheetSlidingViewControllerCleanupRubberBandedPresentationTransition:), "v", {"@"}) &&
        LCSAMethod(manager, @selector(isPresented), @encode(BOOL)) &&
        LCSAMethod(NSClassFromString(@"SBIconController"), @selector(sharedInstance), "@", {}, YES) &&
        LCSAMethod(NSClassFromString(@"SBIconController"), @selector(iconManager), "@") &&
        LCSAMethod(NSClassFromString(@"SBHIconManager"), @selector(rootFolderController), "@") &&
        LCSAMethod(root, @selector(currentIconListView), "@") && LCSAMethod(root, @selector(dockListView), "@") &&
        LCSAMethod(NSClassFromString(@"SpringBoard"), NSSelectorFromString(@"_accessibilityFrontMostApplication"), "@");
}
static BOOL LCSASheetABI(void) {
    Class cls = NSClassFromString(@"CSCoverSheetTransitionsSettings");
    if (!LCSAMethod(cls, @selector(setDefaultValues), "v")) return NO;
    for (NSUInteger i = 0; i < sizeof(kLCSASheetKeys) / sizeof(kLCSASheetKeys[0]); ++i)
        if (!LCSAMethod(cls, NSSelectorFromString(kLCSASheetKeys[i]), "@")) return NO;
    Class child = NSClassFromString(@"CSCoverSheetTransitionSettings");
    for (NSString *key in @[@"blursPanel", @"panelWallpaper", @"fadesContent", @"darkensContent", @"trackingWallpaper", @"fadePanelWallpaper"]) {
        if (!LCSAMethod(child, NSSelectorFromString(key), @encode(BOOL)) || !LCSAMethod(child, LCSASetter(key), "v", {@encode(BOOL)})) return NO;
    }
    return YES;
}
static id LCSAAnimationSettings(void) {
    id root = LCSAObject(NSClassFromString(@"SBAppSwitcherDomain"), "rootSettings");
    id settings = LCSAObject(root, "animationSettings");
    return [settings isKindOfClass:NSClassFromString(@"SBFluidSwitcherAnimationSettings")] ? settings : nil;
}

static dispatch_queue_t gLCSAPreferenceQueue;
static std::atomic<uint64_t> gLCSARefreshGeneration(0);
static void LCSAApplySnapshot(NSDictionary *values) {
    if (![NSThread isMainThread]) return;
    gLCSAPreferences = [values copy];
    BOOL active = LCSAEnabled();
    gLCSAGlobalSlow.store(active ? LCSADoublePref(@"animationGlobalSlow", 1, 1, 5) : 1, std::memory_order_relaxed);
    gLCSAActive.store(active, std::memory_order_release);
    // Cancel every in-flight driver even when the fly is already flying IN (its hidden flag is false).
    [gLCSAGenie finish];
    LCSAFlyCleanup();
    LCSARestoreNumbers(nil);
    if (LCSAAppEnabled()) {
        id current = LCSAAnimationSettings();
        if (current) LCSAApplyIOS27Settings(current);
        for (id settings in gLCSAAppSettings.allObjects) if (settings != current) LCSAApplyIOS27Settings(settings);
    }
    if (LCSASheet27Enabled()) for (id parent in gLCSASheetParents.allObjects) LCSASheetSync(parent);
}
static void LCSARequestPreferenceRefresh(void) {
    if (!gLCSAPreferenceQueue) return;
    uint64_t generation = gLCSARefreshGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
    dispatch_async(gLCSAPreferenceQueue, ^{
        if (generation != gLCSARefreshGeneration.load(std::memory_order_acquire)) return;
        @autoreleasepool {
            NSDictionary *snapshot = [local_cleanstatus_sanitizedAnimationPreferences(local_cleanstatus_readAnimationPreferences()) copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == gLCSARefreshGeneration.load(std::memory_order_acquire)) LCSAApplySnapshot(snapshot);
            });
        }
    });
}
static void LCSAPreferencesChanged(__unused CFNotificationCenterRef center, __unused void *observer, __unused CFStringRef name,
                                 __unused const void *object, __unused CFDictionaryRef info) {
    LCSARequestPreferenceRefresh();
}
static float (*gLCSAOriginalDrag)(void);
static float LCSAAnimationDragCoefficient(void) {
    float original = gLCSAOriginalDrag ? gLCSAOriginalDrag() : 1.0f;
    if (!gLCSAActive.load(std::memory_order_acquire)) return original;
    double factor = gLCSAGlobalSlow.load(std::memory_order_relaxed);
    return factor > 1.0 ? (float)(original * factor) : original;
}
static id gLCSAReduceMotionObserver;
%ctor {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
            ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        gLCSAPreferenceQueue = dispatch_queue_create("com.local.cleanstatus.animation-preferences", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_main_queue(), ^{
            gLCSAPreferences = [local_cleanstatus_animationDefaults() copy];
            gLCSAReduceMotion = UIAccessibilityIsReduceMotionEnabled();
            gLCSAAppSupported = LCSAAppABI();
            gLCSADropletSupported = gLCSAAppSupported && LCSADropletABI();
            gLCSAGenieSupported = gLCSAAppSupported && LCSAGenieABI();
            gLCSAIconsSupported = LCSAIconsABI();
            gLCSASheetSupported = gLCSAIconsSupported && LCSASheetABI();
            if (gLCSAAppSupported) { %init(LCSAApps); }
            if (gLCSAGenieSupported) { %init(LCSAGenie); }
            if (gLCSAIconsSupported) { %init(LCSAIcons); }
            if (gLCSASheetSupported) { %init(LCSASheet); }
            void *dragSymbol = dlsym(RTLD_DEFAULT, "UIAnimationDragCoefficient");
            gLCSADragFunction = (float (*)(void))dragSymbol;
            if (dragSymbol && (gLCSAAppSupported || gLCSAIconsSupported))
                MSHookFunction(dragSymbol, (void *)&LCSAAnimationDragCoefficient, (void **)&gLCSAOriginalDrag);
            local_cleanstatus_publishAnimationCapabilities((gLCSAAppSupported ? LCSAnimationAppSupported : 0) |
                (gLCSAGenieSupported ? LCSAnimationGenieSupported : 0) | (gLCSAIconsSupported ? LCSAnimationIconsSupported : 0) |
                (gLCSADropletSupported ? LCSAnimationDropletSupported : 0) | (gLCSASheetSupported ? LCSAnimationSheetSupported : 0) |
                (gLCSAOriginalDrag ? LCSAnimationGlobalSlowSupported : 0) |
                ((gLCSAIconsSupported && LCSACreateBlur(0)) ? LCSAnimationBlurSupported : 0));
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LCSAPreferencesChanged,
                (__bridge CFStringRef)LCSAnimationPreferencesChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            gLCSAReduceMotionObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIAccessibilityReduceMotionStatusDidChangeNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    gLCSAReduceMotion = UIAccessibilityIsReduceMotionEnabled();
                    LCSAApplySnapshot(gLCSAPreferences);
                }];
            LCSARequestPreferenceRefresh();
        });
    }
}
