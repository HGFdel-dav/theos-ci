#import "PXCSettings.h"
#import "PXCSliderMath.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface PXCSliderParticleView : UIView
@property(nonatomic,strong) CAEmitterLayer *pxcEmitter;
@property(nonatomic,weak) UIView *pxcSlider;
@property(nonatomic) double pxcLastValue;
@property(nonatomic) BOOL pxcHasValue;
@property(nonatomic) NSUInteger pxcGeneration;
- (void)pxcObserve:(double)value;
- (void)pxcStop;
@end
static const void *PXCSliderAssociation = &PXCSliderAssociation;
static const void *PXCSliderTrackingKey = &PXCSliderTrackingKey;
static BOOL PXCBrightnessSlider(UIView *slider) {
    return slider && object_getClass(slider)==NSClassFromString(@"CCUIContinuousSliderView");
}
static NSHashTable<PXCSliderParticleView *> *PXCSliderEffects;
static CGImageRef PXCDotImage(void) {
    static CGImageRef dot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(12,12),NO,1);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx) {
            CGContextSetFillColorWithColor(ctx,UIColor.whiteColor.CGColor);
            CGContextFillEllipseInRect(ctx,CGRectMake(2,2,8,8));
            dot = CGImageRetain(UIGraphicsGetImageFromCurrentImageContext().CGImage);
        }
        UIGraphicsEndImageContext();
    });
    return dot;
}
@implementation PXCSliderParticleView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.userInteractionEnabled=NO;
        self.accessibilityElementsHidden=YES;
        self.backgroundColor=UIColor.clearColor;
        self.opaque=NO;
        self.clipsToBounds=YES;
        self.pxcEmitter=[CAEmitterLayer layer];
        self.pxcEmitter.birthRate=0;
        self.pxcEmitter.emitterShape=kCAEmitterLayerLine;
        self.pxcEmitter.emitterMode=kCAEmitterLayerSurface;
        self.pxcEmitter.renderMode=kCAEmitterLayerUnordered;
        NSMutableArray *cells=[NSMutableArray array];
        for (NSUInteger i=0;i<2;i++) {
            CAEmitterCell *c=[CAEmitterCell emitterCell];
            c.name=i ? @"coolDust" : @"whiteDust";
            c.contents=(__bridge id)PXCDotImage();
            c.birthRate=90;
            c.lifetime=0.65;
            c.lifetimeRange=0.2;
            c.velocity=18;
            c.velocityRange=16;
            c.emissionRange=M_PI*1.1;
            c.scale=0.13;
            c.scaleRange=0.07;
            c.scaleSpeed=-0.08;
            c.alphaSpeed=-1.15;
            c.color=(i ? [UIColor colorWithRed:0.7 green:0.85 blue:1 alpha:0.65] : [UIColor colorWithWhite:1 alpha:0.85]).CGColor;
            c.yAcceleration=-8;
            [cells addObject:c];
        }
        self.pxcEmitter.emitterCells=cells;
        [self.layer addSublayer:self.pxcEmitter];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.pxcEmitter.frame=self.bounds;
    self.layer.cornerRadius=MIN(self.bounds.size.width,self.bounds.size.height)*0.28;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self pxcStop];
    else if (PXCBrightnessSlider(self.pxcSlider) && PXCSliderIsTracking(self.pxcSlider) && self.pxcHasValue) [self pxcObserve:self.pxcLastValue];
}
- (void)pxcObserve:(double)value {
    if (!self.window || self.hidden || self.window.hidden || !isfinite(value)) return;
    double clamped=MAX(0,MIN(1,value));
    double delta=self.pxcHasValue ? clamped-self.pxcLastValue : 0.02;
    self.pxcLastValue=clamped;self.pxcHasValue=YES;
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    PXCSliderGeometry geometry;
    if (!PXCSliderGeometryMake(w,h,clamped,delta,(unsigned)PXCSettingsGet().density,&geometry)) return;
    if (PXCBrightnessSlider(self.pxcSlider)) {
        double inset=MIN(7.0,MIN(w,h)*0.22);
        geometry.x=MAX(inset,MIN(w-inset,geometry.x));
        geometry.y=MAX(inset,MIN(h-inset,geometry.y));
    }
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.pxcEmitter.frame=self.bounds;
    // Position at the native fill edge, emit into the whole native capsule.
    self.pxcEmitter.emitterPosition=CGPointMake(geometry.x,geometry.y);
    self.pxcEmitter.emitterSize=CGSizeMake(geometry.emitterWidth,geometry.emitterHeight);
    self.pxcEmitter.birthRate=(float)geometry.birthRate;
    [CATransaction commit];
    NSUInteger g=++self.pxcGeneration;
    __weak PXCSliderParticleView *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.13*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
        PXCSliderParticleView *s=weakSelf;
        if (s && s.pxcGeneration==g && !PXCSliderIsTracking(s.pxcSlider)) s.pxcEmitter.birthRate=0;
    });
}
- (void)pxcStop {
    self.pxcGeneration++;
    if (!PXCBrightnessSlider(self.pxcSlider)) self.pxcHasValue=NO;
    self.pxcEmitter.birthRate=0;
    // Replacing cells clears existing particles on disable/window removal.
    NSArray *cells=self.pxcEmitter.emitterCells;
    self.pxcEmitter.emitterCells=nil;
    self.pxcEmitter.emitterCells=cells;
}
@end

void PXCSliderObserve(UIView *slider,double value) {
    if (!NSThread.isMainThread || !slider.window || !isfinite(value) || UIAccessibilityIsReduceMotionEnabled()) return;
    PXCSettings settings=PXCSettingsGet();
    if (!settings.enabled || !settings.controlCenter) { PXCSliderStop(slider);return; }
    PXCSliderParticleView *effect=objc_getAssociatedObject(slider,PXCSliderAssociation);
    if (!effect) {
        effect=[[PXCSliderParticleView alloc] initWithFrame:slider.bounds];
        effect.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        effect.pxcSlider=slider;
        objc_setAssociatedObject(slider,PXCSliderAssociation,effect,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!PXCSliderEffects) PXCSliderEffects=[NSHashTable weakObjectsHashTable];
        [PXCSliderEffects addObject:effect];
        [slider addSubview:effect];
        PXCLog([NSString stringWithFormat:@"cc particle layer attached %@",NSStringFromClass(slider.class)]);
    }
    effect.frame=slider.bounds;
    if (effect.superview!=slider) [slider addSubview:effect];
    [slider bringSubviewToFront:effect];
    [effect pxcObserve:value];
}
void PXCSliderStop(UIView *slider) {
    if (!NSThread.isMainThread || !slider) return;
    objc_setAssociatedObject(slider,PXCSliderTrackingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PXCSliderParticleView *effect=objc_getAssociatedObject(slider,PXCSliderAssociation);
    [effect pxcStop];
    [effect removeFromSuperview];
    objc_setAssociatedObject(slider,PXCSliderAssociation,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void PXCSlidersRemoveAll(void) {
    for (PXCSliderParticleView *effect in PXCSliderEffects.allObjects) {
        [effect pxcStop];
        [effect removeFromSuperview];
        UIView *slider=effect.pxcSlider;
        if (slider) {
            objc_setAssociatedObject(slider,PXCSliderAssociation,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(slider,PXCSliderTrackingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    [PXCSliderEffects removeAllObjects];
}

BOOL PXCSliderIsTracking(UIView *slider) {
    if (!PXCBrightnessSlider(slider) || !slider.window || ![objc_getAssociatedObject(slider,PXCSliderTrackingKey) boolValue]) return NO;
    for (UIView *v=slider;v;v=v.superview) if (v.hidden || v.alpha<0.01) return NO;
    // Only observe the native gesture; never alter its state or targets.
    for (UIGestureRecognizer *gesture in slider.gestureRecognizers)
        if ([gesture isKindOfClass:UIPanGestureRecognizer.class] &&
            (gesture.state==UIGestureRecognizerStateBegan || gesture.state==UIGestureRecognizerStateChanged)) return YES;
    return NO;
}
void PXCSliderSetTracking(UIView *slider,BOOL tracking) {
    if (!NSThread.isMainThread || !PXCBrightnessSlider(slider)) return;
    BOOL was=PXCSliderIsTracking(slider);
    PXCSettings settings=PXCSettingsGet();
    tracking=tracking && settings.enabled && settings.controlCenter && !UIAccessibilityIsReduceMotionEnabled();
    objc_setAssociatedObject(slider,PXCSliderTrackingKey,tracking ? @YES : nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (was!=tracking) PXCLog([NSString stringWithFormat:@"cc brightness tracking=%d size=%.1fx%.1f",tracking,slider.bounds.size.width,slider.bounds.size.height]);
    if (!tracking) {
        PXCSliderParticleView *effect=objc_getAssociatedObject(slider,PXCSliderAssociation);
        if (effect.pxcHasValue) [effect pxcObserve:effect.pxcLastValue];
    }
}
void PXCSliderLayout(UIView *slider) {
    if (!NSThread.isMainThread || !PXCBrightnessSlider(slider)) return;
    PXCSliderParticleView *effect=objc_getAssociatedObject(slider,PXCSliderAssociation);
    if (!effect || !slider.window) return;
    effect.frame=slider.bounds;
    if (effect.superview!=slider) [slider addSubview:effect];
    if (slider.subviews.lastObject!=effect) [slider bringSubviewToFront:effect];
    if (PXCSliderIsTracking(slider) && effect.pxcHasValue) [effect pxcObserve:effect.pxcLastValue];
}
