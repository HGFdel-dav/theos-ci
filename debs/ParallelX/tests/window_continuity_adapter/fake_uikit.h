#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
// Production targets iOS arm64, where BOOL is C bool. Intel macOS Foundation
// declares BOOL as signed char; keep extracted adapter locals/properties on
// the production ABI so its bool* policy calls remain strictly type-correct.
#if !OBJC_BOOL_IS_BOOL
#define BOOL bool
#endif
#import "PXWindowContinuity.h"
#import "PXWindowDiagnosticPolicy.h"

static NSString *NSStringFromCGRect(CGRect r) {
 return [NSString stringWithFormat:@"{{%.9g,%.9g},{%.9g,%.9g}}",r.origin.x,r.origin.y,r.size.width,r.size.height];
}
@class UIWindow;
@interface CALayer : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic, strong) CALayer *presentationLayer;
@property(nonatomic, copy) NSArray *animationKeys;
@end
@interface UIView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic) BOOL hidden;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) BOOL userInteractionEnabled;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, readonly) UIWindow *window;
@property(nonatomic, strong) NSMutableArray<UIView *> *subviews;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic) NSUInteger layoutCalls;
- (void)addSubview:(UIView *)view;
- (BOOL)isDescendantOfView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
+ (void)performWithoutAnimation:(void (^)(void))block;
@end
@interface UIScreen : NSObject
@property(nonatomic) CGRect bounds;
+ (instancetype)mainScreen;
@end
@interface UIWindow : UIView
@property(nonatomic, strong) UIScreen *screen;
@end
@interface ADCard : UIView @end

typedef NS_ENUM(NSInteger,UIGestureRecognizerState) {
 UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan,
 UIGestureRecognizerStateChanged, UIGestureRecognizerStateEnded,
 UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed
};
@interface UIGestureRecognizer : NSObject
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic, strong) UIView *view;
@end
@interface ADBridge : NSObject
@property(nonatomic, strong) UIView *canvas;
@property(nonatomic, strong) UIView *hostView;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, strong) NSObject *scene;
@property(nonatomic) BOOL hasHostedSurface;
@property(nonatomic) BOOL fullscreenHandoff;
@property(nonatomic) BOOL isHostedKeyboardVisible;
@property(nonatomic) CGSize sourceSize;
- (CGSize)hostedSourceSize;
@end
@interface PXWindowMemoryStore : NSObject
@property(nonatomic, readonly) BOOL isLoaded;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic) NSUInteger positionSaves;
@property(nonatomic) NSUInteger geometrySaves;
@property(nonatomic) PXWMGeometry lastSaved;
+ (instancetype)shared;
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details;
- (void)savePosition:(PXWMGeometry)g bundle:(NSString *)bundle orientation:(unsigned)key observedEpoch:(uint64_t)epoch;
- (void)saveGeometry:(PXWMGeometry)g bundle:(NSString *)bundle orientation:(unsigned)key observedEpoch:(uint64_t)epoch;
@end
static NSMutableArray<dispatch_block_t> *ADJobs;
static NSMutableArray<NSString *> *ADEvents;
static NSMutableArray<NSDictionary *> *ADDetails;
static NSUInteger ADOriginalCalls, ADLayoutCalls, ADProbeCalls;
// Observe *attempts*, including a write of the same rect or a layout request
// that the fake would otherwise ignore. No observer changes geometry or queues work.
static NSUInteger ADFrameWrites, ADLayoutRequests, ADLayoutPasses;
static BOOL ADMutateOriginal, ADOriginalSawInteraction;
static UIView *ADOriginalCard;
static BOOL PXCloneInstanceMethodMatches(id target, SEL selector, const char *ret, NSArray *args) {
 NSMethodSignature *signature=[target methodSignatureForSelector:selector];
 return signature && signature.numberOfArguments==args.count+2 && strcmp(signature.methodReturnType,ret)==0;
}
static id PXCloneSendId(id target,SEL selector) { return ((id (*)(id,SEL))objc_msgSend)(target,selector); }
static BOOL PXCloneSendBool(id target,SEL selector) { return ((BOOL (*)(id,SEL))objc_msgSend)(target,selector); }
static BOOL PXWindowMemoryGeometry(NSDictionary *snapshot, NSString *bundle, unsigned key, PXWMGeometry *out) {
 (void)snapshot; (void)bundle; (void)key; (void)out; return NO;
}
static void ADDispatchAsync(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; [ADJobs addObject:[block copy]]; }
static void ADDispatchAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
 (void)time; ADDispatchAsync(queue,block);
}
#define dispatch_async ADDispatchAsync
#define dispatch_after ADDispatchAfter

@implementation CALayer @end
@implementation UIView
- (instancetype)init { if ((self=[super init])) { _transform=CGAffineTransformIdentity; _alpha=1; _userInteractionEnabled=YES; _subviews=[NSMutableArray array]; _layer=[CALayer new]; } return self; }
- (CGRect)frame { return [self convertRect:self.bounds toView:self.superview]; }
- (void)setFrame:(CGRect)frame { ADFrameWrites++; _bounds.size=frame.size; _center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame)); _layer.frame=frame; }
- (UIWindow *)window { for (UIView *v=self;v;v=v.superview) if ([v isKindOfClass:UIWindow.class]) return (UIWindow *)v; return nil; }
- (void)addSubview:(UIView *)view { view.superview=self; [self.subviews addObject:view]; }
- (BOOL)isDescendantOfView:(UIView *)view { for (UIView *v=self;v;v=v.superview) if(v==view) return YES; return NO; }
- (CGAffineTransform)toRoot {
 CGAffineTransform t=CGAffineTransformIdentity;
 for (UIView *v=self;v;v=v.superview) {
  CGAffineTransform a=v.transform;
  CGFloat x=CGRectGetMidX(v.bounds),y=CGRectGetMidY(v.bounds);
  a.tx+=v.center.x-a.a*x-a.c*y; a.ty+=v.center.y-a.b*x-a.d*y;
  t=CGAffineTransformConcat(t,a);
 }
 return t;
}
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
 CGAffineTransform t=[self toRoot];
 if(view) t=CGAffineTransformConcat(t,CGAffineTransformInvert([view toRoot]));
 return CGRectApplyAffineTransform(rect,t);
}
- (void)setNeedsLayout { ADLayoutRequests++; }
- (void)layoutIfNeeded { ADLayoutPasses++; self.layoutCalls++; }
+ (void)performWithoutAnimation:(void (^)(void))block { block(); }
@end
@implementation UIScreen
+ (instancetype)mainScreen { static UIScreen *screen; if(!screen) { screen=[UIScreen new]; screen.bounds=CGRectMake(0,0,400,800); } return screen; }
@end
@implementation UIWindow @end
@implementation ADCard
- (void)layoutIfNeeded { [super layoutIfNeeded];
 for(UIView *v in self.subviews) v.frame=CGRectMake(0,0,self.bounds.size.width,self.bounds.size.height);
}
@end
@implementation UIGestureRecognizer @end
@implementation ADBridge
- (CGSize)hostedSourceSize { return self.sourceSize; }
@end
@implementation PXWindowMemoryStore
- (BOOL)isLoaded { return YES; }
- (void)diagnostic:(NSString *)event details:(NSDictionary *)details {
 [ADEvents addObject:event];[ADDetails addObject:details ?: @{}];
}
+ (instancetype)shared { static PXWindowMemoryStore *store; if(!store) store=[PXWindowMemoryStore new]; return store; }
- (void)savePosition:(PXWMGeometry)g bundle:(NSString *)bundle orientation:(unsigned)key observedEpoch:(uint64_t)epoch {
 (void)bundle;(void)key;(void)epoch; self.positionSaves++; self.lastSaved=g;
}
- (void)saveGeometry:(PXWMGeometry)g bundle:(NSString *)bundle orientation:(unsigned)key observedEpoch:(uint64_t)epoch {
 (void)bundle;(void)key;(void)epoch; self.geometrySaves++; self.lastSaved=g;
}
@end
