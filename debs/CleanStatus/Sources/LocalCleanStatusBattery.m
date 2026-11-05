#import "LocalCleanStatusRuntime.h"
#import "LocalCleanStatusConfig.h"

@interface LocalCleanStatusBatteryCanvas : UIView
@property(nonatomic) double fraction;
@property(nonatomic) BOOL charging;
@property(nonatomic) BOOL lowPower;
@property(nonatomic) BOOL hideBolt;
@property(nonatomic, strong) UIColor *foreground;
@end

@implementation LocalCleanStatusBatteryCanvas
- (void)drawRect:(CGRect)rect {
    (void)rect;
    int value = local_cleanstatus_batteryNumber(self.fraction);
    if (value < 0 || self.bounds.size.width < 10 || self.bounds.size.height < 5) return;
    CGRect body = CGRectInset(self.bounds,0.3,0.3);
    CGFloat pinWidth = MAX(1.0,body.size.width*0.065);
    body.size.width -= pinWidth+0.8;
    CGFloat radius = MIN(3.5,body.size.height*0.24);
    UIColor *foreground = self.foreground ?: UIColor.labelColor;
    UIColor *fill = self.lowPower ? UIColor.systemYellowColor :
        (self.charging ? UIColor.systemGreenColor :
         (value <= 20 ? UIColor.systemRedColor : [foreground colorWithAlphaComponent:0.4]));
    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:body cornerRadius:radius];
    shape.lineWidth=1.2; [foreground setStroke]; [shape stroke]; // outline only
    CGRect filled = body; filled.size.width *= MAX(0.0,MIN(1.0,self.fraction));
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    [shape addClip]; [fill setFill]; UIRectFill(filled);
    CGContextRestoreGState(context);
    CGRect pin = CGRectMake(CGRectGetMaxX(body)+0.8,CGRectGetMidY(body)-body.size.height*0.2,
        pinWidth,body.size.height*0.4);
    [(value >= 98 ? fill : [foreground colorWithAlphaComponent:0.4]) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:pin cornerRadius:pinWidth*0.45] fill];
    BOOL bolt = self.charging && !self.hideBolt && value < 100;
    NSString *text = [NSString stringWithFormat:@"%d",value];
    CGFloat size = MIN(10.0,body.size.height*0.76);
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:size weight:UIFontWeightBold];
    CGSize textSize = [text sizeWithAttributes:@{NSFontAttributeName:font}];
    CGFloat boltWidth = bolt ? body.size.height*0.26 : 0;
    CGFloat wholeWidth = textSize.width + (bolt ? boltWidth+0.7 : 0);
    CGRect textRect = CGRectMake(CGRectGetMidX(body)-wholeWidth*0.5,
        CGRectGetMidY(body)-textSize.height*0.5,textSize.width,textSize.height);
    [text drawInRect:textRect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:foreground}];
    if (bolt) {
        CGFloat x=CGRectGetMaxX(textRect)+0.7,y=CGRectGetMidY(body),h=body.size.height*0.68;
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(x+boltWidth*0.7,y-h*0.5)];
        [path addLineToPoint:CGPointMake(x,y+h*0.1)];
        [path addLineToPoint:CGPointMake(x+boltWidth*0.45,y+h*0.1)];
        [path addLineToPoint:CGPointMake(x+boltWidth*0.2,y+h*0.5)];
        [path addLineToPoint:CGPointMake(x+boltWidth,y-h*0.1)];
        [path addLineToPoint:CGPointMake(x+boltWidth*0.55,y-h*0.1)];
        [path closePath];
        [foreground setFill]; [path fill];
    }
}
@end

@interface LocalCleanStatusBatteryState : NSObject
@property(nonatomic, weak) UIView *battery;
@property(nonatomic, strong) LocalCleanStatusBatteryCanvas *canvas;
@property(nonatomic, strong) NSMapTable<CALayer *,NSNumber *> *opacities;
@property(nonatomic, strong) UITapGestureRecognizer *tap;
@property(nonatomic) BOOL ownsInteraction;
@property(nonatomic) BOOL oldInteraction;
@property(nonatomic) double lastTap;
- (void)local_cleanstatus_tapped:(UITapGestureRecognizer *)gesture;
@end
@implementation LocalCleanStatusBatteryState
- (instancetype)init {
    if ((self=[super init])) { _opacities=[NSMapTable weakToStrongObjectsMapTable]; _lastTap=-1; }
    return self;
}
- (void)local_cleanstatus_tapped:(UITapGestureRecognizer *)gesture {
    UIView *battery=self.battery;
    double now=NSProcessInfo.processInfo.systemUptime;
    if (gesture.state != UIGestureRecognizerStateRecognized || !local_cleanstatus_inStatusBar(battery) ||
        !local_cleanstatus_tapAllowed(local_cleanstatus_currentFlags(),battery.window != nil,NO,now,self.lastTap)) return;
    self.lastTap=now;
    local_cleanstatus_requestLowPowerToggle(); // SpringBoard independently checks the actual lock state.
}
@end

static char lcsBatteryStateKey;
static NSHashTable<UIView *> *lcsBatteries;
static void local_cleanstatus_restoreNative(LocalCleanStatusBatteryState *state) {
    for (CALayer *layer in state.opacities.keyEnumerator) layer.opacity=[state.opacities objectForKey:layer].floatValue;
    [state.opacities removeAllObjects];
}
static void local_cleanstatus_hideLayer(LocalCleanStatusBatteryState *state,id candidate) {
    if (![candidate isKindOfClass:CALayer.class] || candidate == state.canvas.layer) return;
    CALayer *layer=candidate;
    if (![state.opacities objectForKey:layer]) [state.opacities setObject:@(layer.opacity) forKey:layer];
    layer.opacity=0;
}
static void local_cleanstatus_applyBattery(UIView *view);

static void local_cleanstatus_applyBattery(UIView *view) {
    if (!NSThread.isMainThread) return;
    uint32_t flags=local_cleanstatus_currentFlags();
    BOOL inStatus=local_cleanstatus_inStatusBar(view);
    BOOL modern=inStatus && local_cleanstatus_hasFeature(flags,LocalCleanStatusModernBattery);
    BOOL hideBolt=inStatus && local_cleanstatus_hasFeature(flags,LocalCleanStatusHideBolt);
    BOOL tap=inStatus && local_cleanstatus_hasFeature(flags,LocalCleanStatusTapLowPower);
    LocalCleanStatusBatteryState *state=objc_getAssociatedObject(view,&lcsBatteryStateKey);
    if (!state && !modern && !hideBolt && !tap) return;
    if (!state) {
        state=[[LocalCleanStatusBatteryState alloc] init]; state.battery=view;
        objc_setAssociatedObject(view,&lcsBatteryStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    local_cleanstatus_restoreNative(state);
    double fraction=local_cleanstatus_double(view,"chargePercent",-1);
    id body=local_cleanstatus_object(view,"bodyLayer") ?: local_cleanstatus_object(view,"bodyShapeLayer");
    id fill=local_cleanstatus_object(view,"fillLayer");
    // Never overlay an unknown native battery implementation.
    modern=modern && local_cleanstatus_batteryNumber(fraction)>=0 &&
        [body isKindOfClass:CALayer.class] && [fill isKindOfClass:CALayer.class];
    if (modern) {
        if (!state.canvas) {
            state.canvas=[[LocalCleanStatusBatteryCanvas alloc] initWithFrame:view.bounds];
            state.canvas.backgroundColor=UIColor.clearColor;
            state.canvas.opaque=NO; state.canvas.userInteractionEnabled=NO;
            state.canvas.isAccessibilityElement=NO; state.canvas.clipsToBounds=YES;
            [view addSubview:state.canvas];
        }
        state.canvas.frame=view.bounds; state.canvas.hidden=NO;
        state.canvas.fraction=fraction;
        state.canvas.charging=local_cleanstatus_integer(view,"chargingState",0)==1;
        state.canvas.lowPower=local_cleanstatus_boolValue(view,"saverModeActive",NSProcessInfo.processInfo.isLowPowerModeEnabled);
        state.canvas.hideBolt=hideBolt;
        state.canvas.foreground=UIColor.labelColor; // bodyColor is gray; Genesis uses labelColor.
        local_cleanstatus_hideLayer(state,body); local_cleanstatus_hideLayer(state,fill);
        local_cleanstatus_hideLayer(state,local_cleanstatus_object(view,"pinLayer"));
        local_cleanstatus_hideLayer(state,local_cleanstatus_object(view,"boltLayer"));
        local_cleanstatus_hideLayer(state,local_cleanstatus_object(view,"boltMaskLayer"));
        id label=local_cleanstatus_object(view,"percentageLabel");
        if ([label isKindOfClass:UIView.class]) local_cleanstatus_hideLayer(state,((UIView *)label).layer);
        [view bringSubviewToFront:state.canvas]; [state.canvas setNeedsDisplay];
    } else {
        state.canvas.hidden=YES;
        if (hideBolt) local_cleanstatus_hideLayer(state,local_cleanstatus_object(view,"boltLayer"));
    }
    [CATransaction commit];
    if (tap) {
        if (!state.tap) {
            state.tap=[[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(local_cleanstatus_tapped:)];
            state.tap.cancelsTouchesInView=NO;
            [view addGestureRecognizer:state.tap];
        }
        state.tap.enabled=YES;
        if (!state.ownsInteraction) {
            state.oldInteraction=view.userInteractionEnabled; state.ownsInteraction=YES;
        }
        view.userInteractionEnabled=YES;
    } else {
        state.tap.enabled=NO;
        if (state.ownsInteraction) { view.userInteractionEnabled=state.oldInteraction; state.ownsInteraction=NO; }
    }
}

static NSUInteger lcsBatteryLayoutDepth;
static void (*lcsOriginalBatteryLayout)(id,SEL);
static void local_cleanstatus_batteryLayout(UIView *self,SEL command) {
    if (!NSThread.isMainThread) { lcsOriginalBatteryLayout(self,command); return; }
    LocalCleanStatusBatteryState *state=objc_getAssociatedObject(self,&lcsBatteryStateKey);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (state) local_cleanstatus_restoreNative(state);
    [CATransaction commit];
    lcsBatteryLayoutDepth++;
    lcsOriginalBatteryLayout(self,command);
    lcsBatteryLayoutDepth--;
    [lcsBatteries addObject:self];
    local_cleanstatus_applyBattery(self);
}
static void local_cleanstatus_installBatteryUpdateHooks(void);
void local_cleanstatus_installBatteryHooks(void) {
    local_cleanstatus_installBatteryUpdateHooks();
    Class cls=NSClassFromString(@"_UIBatteryView");
    SEL selector=@selector(layoutSubviews);
    if (!local_cleanstatus_methodMatches(cls,selector,@encode(void),0,NULL)) return;
    lcsBatteries=[NSHashTable weakObjectsHashTable];
    MSHookMessageEx(cls,selector,(IMP)local_cleanstatus_batteryLayout,(IMP *)&lcsOriginalBatteryLayout);
}
void local_cleanstatus_refreshBatteries(void) {
    if (!NSThread.isMainThread) return;
    for (UIView *view in lcsBatteries.allObjects) {
        [view setNeedsLayout]; [view layoutIfNeeded];
    }
}

// Gate only the battery item's own display identifiers; other status bar items
// and the native charge/saver state are untouched. A force data refresh restores it.
static BOOL (*lcsOriginalCanEnable)(id,SEL,id,id);
static BOOL local_cleanstatus_canEnableBatteryDisplay(id self, SEL command, id display, id data) {
    BOOL original = lcsOriginalCanEnable(self,command,display,data);
    if (!original) return NO;
    uint32_t flags=local_cleanstatus_currentFlags();
    id identifier=local_cleanstatus_object(display,"identifier");
    Class cls=NSClassFromString(@"_UIStatusBarBatteryItem");
    id charging=local_cleanstatus_object(cls,"chargingDisplayIdentifier");
    id percent=local_cleanstatus_object(cls,"percentDisplayIdentifier");
    if ((local_cleanstatus_hasFeature(flags,LocalCleanStatusHideBolt) || local_cleanstatus_hasFeature(flags,LocalCleanStatusModernBattery)) &&
        identifier && charging && [identifier isEqual:charging]) return NO;
    if (local_cleanstatus_hasFeature(flags,LocalCleanStatusModernBattery) && identifier && percent && [identifier isEqual:percent]) return NO;
    return original;
}
static void (*lcsOriginalCharge)(id,SEL,double);
static void (*lcsOriginalCharging)(id,SEL,NSInteger);
static void (*lcsOriginalSaver)(id,SEL,BOOL);
static void (*lcsOriginalBodyColor)(id,SEL,id);
static void local_cleanstatus_markBattery(UIView *view) {
    if (NSThread.isMainThread && !lcsBatteryLayoutDepth && local_cleanstatus_inStatusBar(view) && local_cleanstatus_currentFlags()) [view setNeedsLayout];
}
static void local_cleanstatus_setCharge(UIView *self,SEL cmd,double value) { lcsOriginalCharge(self,cmd,value); local_cleanstatus_markBattery(self); }
static void local_cleanstatus_setCharging(UIView *self,SEL cmd,NSInteger value) { lcsOriginalCharging(self,cmd,value); local_cleanstatus_markBattery(self); }
static void local_cleanstatus_setSaver(UIView *self,SEL cmd,BOOL value) { lcsOriginalSaver(self,cmd,value); local_cleanstatus_markBattery(self); }
static void local_cleanstatus_setBodyColor(UIView *self,SEL cmd,id value) { lcsOriginalBodyColor(self,cmd,value); local_cleanstatus_markBattery(self); }
static BOOL (*lcsOriginalShouldShowBolt)(id,SEL);
static BOOL local_cleanstatus_shouldShowBolt(UIView *self,SEL command) {
    uint32_t flags=local_cleanstatus_currentFlags();
    if (local_cleanstatus_inStatusBar(self) &&
        (local_cleanstatus_hasFeature(flags,LocalCleanStatusHideBolt) || local_cleanstatus_hasFeature(flags,LocalCleanStatusModernBattery))) return NO;
    return lcsOriginalShouldShowBolt(self,command);
}
static void local_cleanstatus_installBatteryUpdateHooks(void) {
    Class cls=NSClassFromString(@"_UIBatteryView");
    SEL shouldBolt=sel_registerName("_shouldShowBolt");
    if (local_cleanstatus_methodMatches(cls,shouldBolt,@encode(BOOL),0,NULL))
        MSHookMessageEx(cls,shouldBolt,(IMP)local_cleanstatus_shouldShowBolt,(IMP *)&lcsOriginalShouldShowBolt);
    const char *charge[]={@encode(double)}, *charging[]={@encode(NSInteger)};
    const char *saver[]={@encode(BOOL)}, *color[]={@encode(id)};
    if (local_cleanstatus_methodMatches(cls,sel_registerName("setChargePercent:"),@encode(void),1,charge))
        MSHookMessageEx(cls,sel_registerName("setChargePercent:"),(IMP)local_cleanstatus_setCharge,(IMP *)&lcsOriginalCharge);
    if (local_cleanstatus_methodMatches(cls,sel_registerName("setChargingState:"),@encode(void),1,charging))
        MSHookMessageEx(cls,sel_registerName("setChargingState:"),(IMP)local_cleanstatus_setCharging,(IMP *)&lcsOriginalCharging);
    if (local_cleanstatus_methodMatches(cls,sel_registerName("setSaverModeActive:"),@encode(void),1,saver))
        MSHookMessageEx(cls,sel_registerName("setSaverModeActive:"),(IMP)local_cleanstatus_setSaver,(IMP *)&lcsOriginalSaver);
    if (local_cleanstatus_methodMatches(cls,sel_registerName("setBodyColor:"),@encode(void),1,color))
        MSHookMessageEx(cls,sel_registerName("setBodyColor:"),(IMP)local_cleanstatus_setBodyColor,(IMP *)&lcsOriginalBodyColor);
    Class item=NSClassFromString(@"_UIStatusBarBatteryItem");
    SEL selector=sel_registerName("canEnableDisplayItem:fromData:");
    const char *args[]={@encode(id),@encode(id)};
    if (local_cleanstatus_methodMatches(item,selector,@encode(BOOL),2,args))
        MSHookMessageEx(item,selector,(IMP)local_cleanstatus_canEnableBatteryDisplay,(IMP *)&lcsOriginalCanEnable);
}
