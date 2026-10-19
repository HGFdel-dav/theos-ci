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
