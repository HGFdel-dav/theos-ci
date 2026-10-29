#import "PXCClearAppearance.h"
#import "PXCClearLayout.h"
#import "PXCSettings.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <string.h>

@interface PXCClearGlassButton ()
@property(nonatomic,strong) UIVisualEffectView *pxcGlass;
@property(nonatomic,strong) UIView *pxcWash;
@property(nonatomic,strong) UIView *pxcPress;
@property(nonatomic) NSUInteger pxcStyle;
@property(nonatomic) CGFloat pxcGlyphSize;
- (void)pxcRefreshMaterial;
@end
@implementation PXCClearGlassButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;
        self.opaque=NO;self.clipsToBounds=YES;
        self.tintColor=UIColor.whiteColor;
        self.pxcGlass=[[UIVisualEffectView alloc] initWithEffect:nil];
        self.pxcGlass.userInteractionEnabled=NO;
        self.pxcGlass.accessibilityElementsHidden=YES;
        [self insertSubview:self.pxcGlass atIndex:0];
        self.pxcWash=[UIView new];self.pxcWash.userInteractionEnabled=NO;
        [self.pxcGlass.contentView addSubview:self.pxcWash];
        self.pxcPress=[UIView new];self.pxcPress.userInteractionEnabled=NO;
        self.pxcPress.backgroundColor=[UIColor colorWithWhite:1 alpha:0.12];
        self.pxcPress.alpha=0;[self.pxcGlass.contentView addSubview:self.pxcPress];
        self.accessibilityLabel=@"一键清除通知";
        self.accessibilityHint=@"使用系统原生清除通知操作";
        self.isAccessibilityElement=YES;
        self.titleLabel.numberOfLines=1;
        self.titleLabel.adjustsFontSizeToFitWidth=YES;
        self.titleLabel.minimumScaleFactor=0.72;
        self.layer.borderWidth=0.5;
        self.pxcGlyphSize=-1;
        [self pxcApplyStyle:0 glyphSize:22];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pxcRefreshMaterial)
            name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)pxcRefreshMaterial {
    BOOL reduced=UIAccessibilityIsReduceTransparencyEnabled();
    // Keep opacity on the material only. Never fade the button's icon/text or
    // use private backgroundEffects from Apple's own buttons.
    self.pxcGlass.effect=reduced ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.pxcGlass.alpha=1;
    self.pxcWash.backgroundColor=reduced ? [UIColor colorWithWhite:0.18 alpha:0.92] : [UIColor colorWithWhite:1 alpha:0.035];
    self.layer.borderColor=[UIColor colorWithWhite:1 alpha:reduced?0.28:0.18].CGColor;
}
- (void)pxcApplyStyle:(NSUInteger)style glyphSize:(CGFloat)glyphSize {
    style=style==1?1:0;glyphSize=MAX(12,MIN(48,glyphSize));
    if (self.pxcGlyphSize==glyphSize && self.pxcStyle==style) return;
    self.pxcStyle=style;self.pxcGlyphSize=glyphSize;
    UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:glyphSize weight:UIImageSymbolWeightRegular];
    [self setImage:[UIImage systemImageNamed:@"trash" withConfiguration:config] forState:UIControlStateNormal];
    [self setTitle:style==0 ? @"一键清除" : nil forState:UIControlStateNormal];
    [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.titleLabel.font=[UIFont systemFontOfSize:MAX(13,MIN(18,glyphSize*0.64)) weight:UIFontWeightMedium];
    self.imageView.contentMode=UIViewContentModeScaleAspectFit;
    self.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
    self.semanticContentAttribute=UISemanticContentAttributeForceLeftToRight;
    [self pxcRefreshMaterial];[self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.pxcGlass.frame=self.bounds;
    self.pxcWash.frame=self.pxcGlass.contentView.bounds;
    self.pxcPress.frame=self.pxcGlass.contentView.bounds;
    [self sendSubviewToBack:self.pxcGlass];
    self.layer.cornerRadius=MIN(self.bounds.size.width,self.bounds.size.height)*0.5;
    if (self.pxcStyle==0) {
        CGFloat gap=7;
        CGSize imageSize=self.imageView.image.size;
        CGSize titleSize=[self.titleLabel sizeThatFits:CGSizeMake(MAX(0,self.bounds.size.width-imageSize.width-gap-16),self.bounds.size.height)];
        CGFloat groupWidth=imageSize.width+gap+titleSize.width;
        CGFloat x=(self.bounds.size.width-groupWidth)*0.5;
        self.imageView.frame=CGRectMake(x,(self.bounds.size.height-imageSize.height)*0.5,imageSize.width,imageSize.height);
        self.titleLabel.frame=CGRectMake(x+imageSize.width+gap,(self.bounds.size.height-titleSize.height)*0.5,titleSize.width,titleSize.height);
    }
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];self.pxcPress.alpha=highlighted?1:0;
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];self.imageView.alpha=enabled?1:0.45;self.titleLabel.alpha=enabled?1:0.45;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];[self pxcRefreshMaterial];
}
@end

static NSHashTable<UIView *> *PXCClearQuickViews;
static BOOL PXCClearUpdateQueued;
static const char *PXCClearType(const char *t) { while (t && *t && strchr("rnNoORV",*t)) t++;return t; }
static id PXCClearObject(id o,const char *name) {
    SEL sel=sel_registerName(name);Method m=o ? class_getInstanceMethod(object_getClass(o),sel) : NULL;
    char type[64];
    if (!m || method_getNumberOfArguments(m)!=2) return nil;
    method_getReturnType(m,type,sizeof(type));if (*PXCClearType(type)!='@') return nil;
    return ((id(*)(id,SEL))objc_msgSend)(o,sel);
}
static BOOL PXCClearVisible(UIView *view) {
    if (![view isKindOfClass:UIView.class] || !view.window || view.window.hidden) return NO;
    for (UIView *v=view;v;v=v.superview) if (v.hidden || v.alpha<0.02) return NO;
    return !CGRectIsEmpty(CGRectIntersection([view convertRect:view.bounds toView:view.window],view.window.bounds));
}
static UIView *PXCClearNativeSurface(UIView *button) {
    // Header evidence: UICoverSheetButton's visual circle is the effect view;
    // outer bounds can include edgeInsets/touch outsets. Read, never mutate it.
    Ivar ivar=class_getInstanceVariable(object_getClass(button),"_backgroundEffectView");
    const char *type=ivar ? PXCClearType(ivar_getTypeEncoding(ivar)) : NULL;
    id surface=type && *type=='@' ? object_getIvar(button,ivar) : nil;
    if ([surface isKindOfClass:UIView.class] && [surface isDescendantOfView:button] &&
        PXCClearVisible(surface) && [surface bounds].size.width>=20 && [surface bounds].size.height>=20) return surface;
    return button;
}
static CGRect PXCClearConvert(UIView *v,UIView *host) {
    if (v.window==host.window) return [v convertRect:v.bounds toView:host];
    CGRect r=[v convertRect:v.bounds toView:v.window];
    r=[v.window convertRect:r toWindow:host.window];
    return [host convertRect:r fromView:host.window];
}
static PXCClearRect PXCClearMathRect(CGRect r) { return (PXCClearRect){r.origin.x,r.origin.y,r.size.width,r.size.height}; }
static void PXCClearRemember(UIView *quick) {
    if (!PXCClearQuickViews) PXCClearQuickViews=[NSHashTable weakObjectsHashTable];
    [PXCClearQuickViews addObject:quick];
}
static void PXCClearDiscover(UIView *host) {
    Class quickClass=NSClassFromString(@"CSQuickActionsView");
    if (!quickClass || !host.window) return;
    // Cold-start fallback; later native layout hooks keep the weak cache fresh.
    NSMutableArray *queue=[NSMutableArray arrayWithObject:host.window];
    for (NSUInteger i=0;i<queue.count && i<3000;i++) {
        UIView *v=queue[i];
        if ([v isKindOfClass:quickClass]) { PXCClearRemember(v);continue; }
        if (queue.count<3000) [queue addObjectsFromArray:v.subviews];
    }
}
static BOOL PXCClearNativeMetrics(UIView *host,CGRect *flashRect,CGRect *cameraRect,CGFloat *glyph) {
    if (!host.window) return NO;
    if (!PXCClearQuickViews.count) PXCClearDiscover(host);
    for (UIView *quick in PXCClearQuickViews.allObjects) {
        if (!PXCClearVisible(quick) || quick.window.screen!=host.window.screen) continue;
        UIWindowScene *qs=quick.window.windowScene,*hs=host.window.windowScene;
        if (qs && hs && qs!=hs) continue;
        NSArray *buttons=@[PXCClearObject(quick,"flashlightButton") ?: NSNull.null,PXCClearObject(quick,"cameraButton") ?: NSNull.null];
        CGRect found[2]={CGRectZero,CGRectZero};CGFloat glyphSize=0;
        for (NSUInteger i=0;i<2;i++) {
            id native=buttons[i];if (![native isKindOfClass:UIView.class] || !PXCClearVisible(native)) continue;
            UIView *surface=PXCClearNativeSurface(native);
            CGRect rect=PXCClearConvert(surface,host);
            if (!PXCClearReferenceValid(PXCClearMathRect(rect),PXCClearMathRect(host.bounds))) continue;
            found[i]=rect;
            UIImage *image=PXCClearObject(native,"image");
            if ([image isKindOfClass:UIImage.class] && image.size.width>=10 && image.size.height>=10)
                glyphSize=MAX(glyphSize,MIN(image.size.width,image.size.height));
        }
        if (!CGRectIsEmpty(found[0]) || !CGRectIsEmpty(found[1])) {
            *flashRect=found[0];*cameraRect=found[1];*glyph=glyphSize;return YES;
        }
    }
    return NO;
}
void PXCClearAppearancePlace(PXCClearGlassButton *button,UIView *host) {
    if (!NSThread.isMainThread || !button || !host.window) return;
    CGRect a=CGRectZero,b=CGRectZero;CGFloat glyph=0;
    BOOL matched=PXCClearNativeMetrics(host,&a,&b,&glyph);
    NSUInteger style=PXCSettingsGet().clearButtonStyle==1 ? 1 : 0;
    CGFloat nominalHeight=matched ? MIN((!CGRectIsEmpty(a)?a:b).size.width,(!CGRectIsEmpty(a)?a:b).size.height) : 50;
    if (glyph<10) glyph=nominalHeight*0.45;
    glyph=MIN(glyph,nominalHeight*0.56);
    [button pxcApplyStyle:style glyphSize:glyph];
    CGSize text=[@"一键清除" sizeWithAttributes:@{NSFontAttributeName:button.titleLabel.font}];
    CGFloat desired=text.width+button.imageView.image.size.width+7+30;
    CGRect safe=UIEdgeInsetsInsetRect(host.bounds,host.safeAreaInsets);
    PXCClearPlacement p;
    if (!PXCClearLayoutMake(PXCClearMathRect(host.bounds),PXCClearMathRect(safe),PXCClearMathRect(a),PXCClearMathRect(b),(unsigned)style,desired,&p)) {
        button.hidden=YES;return;
    }
    CGRect frame=CGRectMake(p.frame.x,p.frame.y,p.frame.w,p.frame.h);
    if (!CGRectEqualToRect(button.frame,frame)) button.frame=frame;
    // No opacity applied to label/glyph. Material provides the translucency.
    button.hidden=NO;
}
static void PXCClearScheduleUpdate(void) {
    if (PXCClearUpdateQueued) return;PXCClearUpdateQueued=YES;
    dispatch_async(dispatch_get_main_queue(), ^{ PXCClearUpdateQueued=NO;PXCNotificationSettingsChanged(); });
}
static void (*PXCClearOrigQuickLayout)(id,SEL);
static void PXCClearQuickLayout(id self,SEL cmd) {
    PXCClearOrigQuickLayout(self,cmd);
    if (NSThread.isMainThread && [self isKindOfClass:UIView.class]) { PXCClearRemember(self);PXCClearScheduleUpdate(); }
}
static void (*PXCClearOrigQuickWindow)(id,SEL);
static void PXCClearQuickWindow(id self,SEL cmd) {
    PXCClearOrigQuickWindow(self,cmd);
    if (NSThread.isMainThread && [self isKindOfClass:UIView.class]) { PXCClearRemember(self);PXCClearScheduleUpdate(); }
}
void PXCClearAppearanceInstallHooks(void) {
    Class cls=objc_getClass("CSQuickActionsView");if (!cls) return;
    struct { const char *name;IMP hook;IMP *original; } defs[]={
        {"layoutSubviews",(IMP)PXCClearQuickLayout,(IMP *)&PXCClearOrigQuickLayout},
        {"didMoveToWindow",(IMP)PXCClearQuickWindow,(IMP *)&PXCClearOrigQuickWindow}
    };
    for (unsigned i=0;i<sizeof(defs)/sizeof(defs[0]);i++) {
        if (*defs[i].original) continue;
        SEL sel=sel_registerName(defs[i].name);Method m=class_getInstanceMethod(cls,sel);char t[64];
        if (!m || method_getNumberOfArguments(m)!=2) continue;
        method_getReturnType(m,t,sizeof(t));if (*PXCClearType(t)!='v') continue;
        MSHookMessageEx(cls,sel,defs[i].hook,defs[i].original);
        PXCLog([NSString stringWithFormat:@"clear appearance hook CSQuickActionsView %s",defs[i].name]);
    }
}
