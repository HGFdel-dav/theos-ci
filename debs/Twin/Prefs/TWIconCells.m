// TWIconCells.m — Twin 0.9.0 图标行
//
// 做法：运行时给系统 cell 类生成子类（TWIcon_PSSwitchCell 等），只覆盖
// layoutSubviews —— 先调 super 让系统把开关/滑块/文本摆好，再插一个 27pt
// 彩色圆角图标并把文本右移。父类的全部私有方法（值链 setValue:、开关回调、
// 滑块拖拽）原样继承，所以 0.4.0~0.4.2 那种"自绘 cell 不响应私有消息 → 崩"
// 的根因在这里不存在。
//
// 颜色/符号由 specifier 的 twSymbol + twColor 决定（TWSpecifiers.m 写入）。
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "TWStyle.h"

// 只声明签名：PSSpecifier 的 propertyForKey:、PSTableCell 的 specifier。
// 不继承、不替换任何系统类，纯粹给编译器看。
@interface NSObject (TWIconSpec)
- (id)propertyForKey:(NSString *)key;
- (id)specifier;
@end

#define TWICON_TAG 0x77494E4F  // 'wINO'
static const CGFloat kTWIconSize = 27.0;
static const CGFloat kTWIconLeft = 13.0;
static const CGFloat kTWIconGap  = 11.0;

// ---------------------------------------------------------------- 图标渲染
static NSMutableDictionary<NSString *, UIImage *> *gTWIconCache = nil;

static UIImage *TWIconImage(NSString *symbol, NSInteger colorIdx) {
    if (!symbol.length) return nil;
    if (!gTWIconCache) gTWIconCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@#%ld", symbol, (long)colorIdx];
    UIImage *cached = gTWIconCache[key];
    if (cached) return cached;

    UIColor *bg = TWIconTintColor(colorIdx) ?: [UIColor systemGrayColor];
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(kTWIconSize, kTWIconSize) format:fmt];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bg setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, kTWIconSize, kTWIconSize)
                                        cornerRadius:7] fill];
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:14
                                                            weight:UIImageSymbolWeightSemibold
                                                             scale:UIImageSymbolScaleMedium];
        UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        if (!glyph) return;
        glyph = [glyph imageWithTintColor:UIColor.whiteColor
                            renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize s = glyph.size;
        [glyph drawInRect:CGRectMake((kTWIconSize - s.width) / 2,
                                     (kTWIconSize - s.height) / 2,
                                     s.width, s.height)];
    }];
    if (img) gTWIconCache[key] = img;
    return img;
}

// ---------------------------------------------------------------- 布局
static void TWIconLayoutSubviews(id self, SEL _cmd) {
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);

    id spec = nil;
    @try { spec = [(id)self specifier]; } @catch (NSException *e) { (void)e; spec = nil; }
    if (!spec) return;

    id symObj = nil, colObj = nil;
    @try {
        symObj = [spec propertyForKey:@"twSymbol"];
        colObj = [spec propertyForKey:@"twColor"];
    } @catch (NSException *e) { (void)e; return; }
    if (![symObj isKindOfClass:NSString.class] || ![symObj length]) return;
    NSString *symbol = symObj;
    NSNumber *colorNum = [colObj isKindOfClass:NSNumber.class] ? colObj : nil;

    UIImage *icon = TWIconImage(symbol, colorNum ? colorNum.integerValue : 0);
    if (!icon) return;

    UIView *host = (UIView *)self;
    UIImageView *iconView = (UIImageView *)[host viewWithTag:TWICON_TAG];
    if (!iconView) {
        iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        iconView.tag = TWICON_TAG;
        iconView.userInteractionEnabled = NO;
        [host addSubview:iconView];
    }
    iconView.image = icon;
    CGRect b = host.bounds;
    iconView.frame = CGRectMake(kTWIconLeft, (CGRectGetHeight(b) - kTWIconSize) / 2,
                                kTWIconSize, kTWIconSize);

    // 文本右移，给图标让位；右侧留出开关/箭头的空间
    CGFloat textX = kTWIconLeft + kTWIconSize + kTWIconGap;
    CGFloat textW = MAX(CGRectGetWidth(b) - textX - 64.0, 40.0);
    UILabel *title = [(UITableViewCell *)self textLabel];
    UILabel *detail = [(UITableViewCell *)self detailTextLabel];

    if ([title isKindOfClass:UILabel.class]) {
        CGRect f = title.frame;
        f.origin.x = textX;
        if (f.size.width > 0) f.size.width = MIN(f.size.width, textW);
        title.frame = f;
        title.font = [UIFont systemFontOfSize:15.0];
    }
    if ([detail isKindOfClass:UILabel.class]) {
        CGRect f = detail.frame;
        f.origin.x = textX;
        detail.frame = f;
        detail.font = [UIFont systemFontOfSize:12.0];
    }
}

// ---------------------------------------------------------------- 工厂
Class TWIconCellClass(NSString *baseClassName) {
    if (!baseClassName.length) return Nil;
    NSString *subName = [@"TWIcon_" stringByAppendingString:baseClassName];
    Class existing = NSClassFromString(subName);
    if (existing) return existing;

    Class base = NSClassFromString(baseClassName);
    if (!base) return Nil;

    Class sub = objc_allocateClassPair(base, subName.UTF8String, 0);
    if (!sub) return Nil;
    class_addMethod(sub, @selector(layoutSubviews), (IMP)TWIconLayoutSubviews, "v@:");
    objc_registerClassPair(sub);
    return sub;
}

// ---------------------------------------------------------------- 滑块行（0.9.4）
//
// 本机 Preferences 的 PSSliderCell 不显示标题（实测：整行只剩滑杆）。
// 这里给 PSSliderCell 加一层子类，只补一个标题 UILabel + 数值，滑杆下移，
// 父类全部私有值链（setValue:/取值回调）原样继承，避免 0.4.x 的崩溃复现。
#define TWSLIDER_TAG 0x774C4452  // 'wLDR'
#define TWSLIDERVAL_TAG 0x774C4456

static void TWSliderLayoutSubviews(id self, SEL _cmd) {
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);

    // 只负责"每次布局都把滑杆按到下半区"。
    // 标题/数值由 TWStyleSliderCellIfNeeded 统一添加，这里绝不能再加一遍，
    // 否则同一个 cell 上会有两套标签叠在一起（0.9.20 实机就是这样）。
    UIView *host = (UIView *)self;
    CGRect b = host.bounds;
    CGFloat w = CGRectGetWidth(b);
    if (w <= 0) return;
    for (UIView *sub in host.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            CGFloat h = CGRectGetHeight(sub.bounds);
            if (h <= 0 || h > 40) h = 31;
            // 78pt 行：标题 8~26，滑杆 42~73；31pt 圆钮顶部 27，不压字。
            CGFloat y = CGRectGetHeight(b) - h - 5;
            if (y < 26) y = 26;
            if (sub.frame.origin.y < y - 1 || fabs(sub.frame.size.width - (w - 32)) > 1) {
                sub.frame = CGRectMake(16, y, w - 32, h);
            }
            break;
        }
    }
}

Class TWSliderCellClass(void) {
    static Class cls = Nil;
    if (cls) return cls;
    Class base = NSClassFromString(@"PSSliderCell");
    if (!base) return Nil;
    cls = objc_allocateClassPair(base, "TWSlider_PSSliderCell", 0);
    if (!cls) return Nil;
    class_addMethod(cls, @selector(layoutSubviews), (IMP)TWSliderLayoutSubviews, "v@:");
    objc_registerClassPair(cls);
    return cls;
}
