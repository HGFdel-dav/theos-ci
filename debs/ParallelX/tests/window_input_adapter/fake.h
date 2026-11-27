#pragma once
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#import "PXWindowInputPolicy.h"
#import "PXWindowMemoryPolicy.h"

// Aliases affect compilation, not ObjC runtime names. No CALayer is defined.
#define UIView PXIFakeView
#define UIWindow PXIFakeWindow
#define UITouch PXIFakeTouch
#define UIEvent PXIFakeEvent
#define PXWindowMemoryStore PXIFakeStore

typedef NS_ENUM(NSInteger, UITouchPhase) {
    UITouchPhaseBegan, UITouchPhaseMoved, UITouchPhaseStationary,
    UITouchPhaseEnded, UITouchPhaseCancelled
};
typedef NS_ENUM(NSInteger, UIEventType) { UIEventTypeTouches, UIEventTypeMotion };

static double PXIFakeNow = 100;
static NSUInteger PXIFakeForbiddenReads, PXIFakeWrites, PXIFakeHookCalls;
static BOOL PXIFakeRejectABI, PXIFakeStoreThrows;
static NSMutableArray<dispatch_block_t> *PXIFakeJobs;
static NSMutableArray<NSNumber *> *PXIFakeDelays;
static NSMutableArray<NSString *> *PXIFakeEvents;
static NSMutableArray<NSDictionary *> *PXIFakeDetails;
static double CACurrentMediaTime(void) { return PXIFakeNow; }
static dispatch_time_t PXIFakeTime(dispatch_time_t base, int64_t delta) {
    (void)base; return (dispatch_time_t)delta;
}
static void PXIFakeAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue; [PXIFakeDelays addObject:@((double)time / NSEC_PER_SEC)];
    [PXIFakeJobs addObject:[block copy]];
}
#define dispatch_time PXIFakeTime
#define dispatch_after PXIFakeAfter

@class PXIFakeWindow;
@interface PXIFakeView : NSObject
@property(nonatomic, weak) PXIFakeView *superview;
@property(nonatomic, strong) NSMutableArray<PXIFakeView *> *children;
@property(nonatomic, readonly) PXIFakeWindow *window;
@property(nonatomic) BOOL userInteractionEnabled;
@property(nonatomic) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic) NSUInteger reads;
@property(nonatomic) BOOL throwReads;
- (void)addSubview:(PXIFakeView *)view;
- (BOOL)isDescendantOfView:(PXIFakeView *)view;
- (id)hitTest:(id)point withEvent:(id)event;
- (id)text;
@end
@interface PXIFakeWindow : PXIFakeView
@property(nonatomic, getter=isKeyWindow) BOOL keyWindow;
- (void)sendEvent:(id)event;
@end
@interface PXIFakeTouch : NSObject
@property(nonatomic, strong) PXIFakeWindow *window;
@property(nonatomic, strong) PXIFakeView *view;
@property(nonatomic) UITouchPhase phase;
@property(nonatomic) BOOL throwReads;
@property(nonatomic) NSUInteger reads;
- (id)locationInView:(id)view;
- (id)preciseLocationInView:(id)view;
@end
@interface PXIFakeEvent : NSObject
@property(nonatomic) UIEventType type;
@property(nonatomic, copy) NSSet<PXIFakeTouch *> *allTouches;
@property(nonatomic) BOOL throwReads;
@property(nonatomic) NSUInteger reads;
@end
@interface PXIFakeBridge : NSObject
@property(nonatomic, strong) PXIFakeView *canvas;
@property(nonatomic, strong) PXIFakeView *hostView;
@property(nonatomic, strong) PXIFakeView *keyboardOverlay;
@property(nonatomic, strong) id scene;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic) NSUInteger reads;
- (void)setHostedInteractionEnabled:(BOOL)enabled;
- (BOOL)foregroundScene:(id)scene;
- (void)scene:(id)scene didUpdateClientSettingsWithDiff:(id)diff oldClientSettings:(id)old transitionContext:(id)transition;
@end
// Missing optional getters are deliberate: unknown BOOL/PID must remain -1.
@interface PXIFakeScene : NSObject
@property(nonatomic, strong) id settings;
@property(nonatomic, strong) id clientProcess;
@end
@interface PXIFakeStore : NSObject
@property(nonatomic, copy) NSDictionary *snapshot;
+ (instancetype)shared;
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details;
@end

static void PXIFakePoison(void) {
    PXIFakeForbiddenReads++;
    @throw [NSException exceptionWithName:@"ForbiddenInputRead" reason:@"coordinates/text/hitTest are forbidden" userInfo:nil];
}
@implementation PXIFakeView
@synthesize userInteractionEnabled = _userInteractionEnabled, hidden = _hidden, alpha = _alpha;
- (instancetype)init {
    if ((self = [super init])) { _userInteractionEnabled=YES; _alpha=1; _children=[NSMutableArray new]; }
    return self;
}
- (void)read {
    _reads++;
    if (_throwReads) @throw [NSException exceptionWithName:@"ObserverGetter" reason:nil userInfo:nil];
}
- (PXIFakeWindow *)window {
    [self read];
    if ([self isKindOfClass:PXIFakeWindow.class]) return (PXIFakeWindow *)self;
    return self.superview.window;
}
- (BOOL)userInteractionEnabled { [self read]; return _userInteractionEnabled; }
- (void)setUserInteractionEnabled:(BOOL)value { PXIFakeWrites++; _userInteractionEnabled=value; }
- (BOOL)hidden { [self read]; return _hidden; }
- (void)setHidden:(BOOL)value { PXIFakeWrites++; _hidden=value; }
- (double)alpha { [self read]; return _alpha; }
- (void)setAlpha:(double)value { PXIFakeWrites++; _alpha=value; }
- (void)addSubview:(PXIFakeView *)view { PXIFakeWrites++; view.superview=self; [self.children addObject:view]; }
- (BOOL)isDescendantOfView:(PXIFakeView *)view {
    [self read];
    for (PXIFakeView *v=self; v; v=v.superview) if (v==view) return YES;
    return NO;
}
- (id)hitTest:(id)point withEvent:(id)event { (void)point; (void)event; PXIFakePoison(); return nil; }
- (id)text { PXIFakePoison(); return nil; }
@end
@implementation PXIFakeWindow
- (void)sendEvent:(id)event { (void)event; }
@end
@implementation PXIFakeTouch
@synthesize view = _view, phase = _phase;
- (PXIFakeView *)view {
    _reads++;
    if (_throwReads) @throw [NSException exceptionWithName:@"TouchGetter" reason:nil userInfo:nil];
    return _view;
}
- (void)setView:(PXIFakeView *)value { _view=value; }
- (UITouchPhase)phase { _reads++; return _phase; }
- (void)setPhase:(UITouchPhase)value { _phase=value; }
- (id)locationInView:(id)view { (void)view; PXIFakePoison(); return nil; }
- (id)preciseLocationInView:(id)view { (void)view; PXIFakePoison(); return nil; }
@end
@implementation PXIFakeEvent
@synthesize allTouches = _allTouches;
- (NSSet<PXIFakeTouch *> *)allTouches {
    _reads++;
    if (_throwReads) @throw [NSException exceptionWithName:@"EventGetter" reason:nil userInfo:nil];
    return _allTouches;
}
- (void)setAllTouches:(NSSet<PXIFakeTouch *> *)value { _allTouches=[value copy]; }
@end
@implementation PXIFakeBridge
@synthesize canvas = _canvas, hostView = _hostView, keyboardOverlay = _keyboardOverlay, scene = _scene, bundleID = _bundleID;
- (PXIFakeView *)canvas { _reads++; return _canvas; }
- (void)setCanvas:(PXIFakeView *)value { _canvas=value; }
- (PXIFakeView *)hostView { _reads++; return _hostView; }
- (void)setHostView:(PXIFakeView *)value { _hostView=value; }
- (PXIFakeView *)keyboardOverlay { _reads++; return _keyboardOverlay; }
- (void)setKeyboardOverlay:(PXIFakeView *)value { _keyboardOverlay=value; }
- (id)scene { _reads++; return _scene; }
- (void)setScene:(id)value { _scene=value; }
- (NSString *)bundleID { _reads++; return _bundleID; }
- (void)setBundleID:(NSString *)value { _bundleID=[value copy]; }
- (void)setHostedInteractionEnabled:(BOOL)enabled { (void)enabled; }
- (BOOL)foregroundScene:(id)scene { (void)scene; return YES; }
- (void)scene:(id)scene didUpdateClientSettingsWithDiff:(id)diff oldClientSettings:(id)old transitionContext:(id)transition {
    (void)scene; (void)diff; (void)old; (void)transition;
}
@end
@implementation PXIFakeScene @end
@implementation PXIFakeStore
+ (instancetype)shared { static PXIFakeStore *store; if (!store) store=[self new]; return store; }
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details {
    if (PXIFakeStoreThrows) @throw [NSException exceptionWithName:@"StoreFailure" reason:nil userInfo:nil];
    [PXIFakeEvents addObject:event]; [PXIFakeDetails addObject:[details copy]];
}
@end

// Runtime and hook boundaries only; production observer functions are not mocked.
static BOOL PXIFakeMethodMatches(Class cls, SEL selector, const char *ret, NSArray<NSString *> *args) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method)!=args.count+2) return NO;
    char *actual=method_copyReturnType(method);
    BOOL matches=actual && strcmp(actual,ret)==0; free(actual);
    for (NSUInteger i=0; matches && i<args.count; i++) {
        actual=method_copyArgumentType(method,(unsigned)i+2);
        matches=actual && strcmp(actual,args[i].UTF8String)==0; free(actual);
    }
    return matches;
}
static BOOL PXCloneInstanceMethodMatches(id object, SEL selector, const char *ret, NSArray *args) {
    return object && PXIFakeMethodMatches([object class],selector,ret,args);
}
static BOOL PXCloneClassInstanceMethodMatches(Class cls, SEL selector, const char *ret, NSArray *args) {
    return !PXIFakeRejectABI && PXIFakeMethodMatches(cls,selector,ret,args);
}
static id PXCloneSendId(id object, SEL selector) {
    @try { return ((id (*)(id,SEL))objc_msgSend)(object,selector); }
    @catch (__unused NSException *exception) { return nil; }
}
static BOOL PXCloneHookMessage(Class cls, SEL selector, IMP replacement, IMP *original) {
    (void)replacement; PXIFakeHookCalls++;
    *original=class_getMethodImplementation(cls,selector); return *original!=NULL;
}
