// TWStyle.m
#import "TWStyle.h"

@implementation TWChipView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = frame.size.height * 0.32;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = TWStyle.accentSoft;
        self.clipsToBounds = YES;
        _glyphView = [[UIImageView alloc] initWithFrame:self.bounds];
        _glyphView.contentMode = UIViewContentModeCenter;
        _glyphView.tintColor = TWStyle.accent;
        _glyphView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_glyphView];
        _fallbackLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _fallbackLabel.textAlignment = NSTextAlignmentCenter;
        _fallbackLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _fallbackLabel.textColor = TWStyle.accent;
        _fallbackLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _fallbackLabel.hidden = YES;
        [self addSubview:_fallbackLabel];
    }
    return self;
}

- (void)setSymbolNamed:(NSString *)name fallbackText:(NSString *)text {
    UIImage *image = nil;
    if ([name isKindOfClass:NSString.class] && name.length) {
        image = [UIImage systemImageNamed:name];
        if (!image) image = [UIImage systemImageNamed:@"circle.fill"];
    }
    self.glyphView.image = image;
    self.glyphView.hidden = (image == nil);
    self.fallbackLabel.hidden = (image != nil);
    self.fallbackLabel.text = text.length ? [text substringToIndex:1] : @"·";
}

@end

static UIColor *TWAdaptive(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db) {
    UIColor *light = [UIColor colorWithRed:lr green:lg blue:lb alpha:1.0];
    UIColor *dark = [UIColor colorWithRed:dr green:dg blue:db alpha:1.0];
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
        }];
    }
    return light;
}

@implementation TWStyle

+ (UIColor *)accent {
    return TWAdaptive(0.424, 0.365, 0.906,  0.549, 0.494, 1.000); // #6C5CE7 / #8C7EFF
}

+ (UIColor *)accentAlt {
    return TWAdaptive(0.000, 0.647, 0.792,  0.208, 0.812, 0.945); // #00A5CA / #35CFF1
}

+ (UIColor *)accentSoft {
    return [self.accent colorWithAlphaComponent:0.14];
}

+ (UIColor *)danger {
    return [UIColor systemRedColor];
}

+ (NSArray<UIColor *> *)gradientColors {
    return @[[self accent], [self accentAlt]];
}

+ (UIFont *)rowTitleFont {
    return [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
}

+ (UIFont *)rowValueFont {
    UIFont *base = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *)) {
        return [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    }
    return base;
}

+ (UIFont *)heroTitleFont {
    return [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
}

+ (UIFont *)heroSubtitleFont {
    return [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
}

+ (TWChipView *)chipWithSymbol:(NSString *)symbol fallback:(NSString *)text {
    TWChipView *chip = [[TWChipView alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    [chip setSymbolNamed:symbol fallbackText:text];
    return chip;
}

+ (UIView *)heroHeaderWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                     statusText:(NSString *)statusText
                        enabled:(BOOL)enabled
                          width:(CGFloat)width {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 140)];
    container.backgroundColor = [UIColor clearColor];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 10, MAX(0.0, width - 32.0), 122)];
    card.layer.cornerRadius = 20;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = card.bounds;
    NSArray *colors = [self gradientColors];
    gradient.colors = @[(id)[colors[0] CGColor], (id)[colors[1] CGColor]];
    gradient.startPoint = CGPointMake(0.0, 0.0);
    gradient.endPoint = CGPointMake(1.0, 1.0);
    [card.layer addSublayer:gradient];

    // decorative soft blobs (own look, not a clone of any other panel)
    UIView *blobA = [[UIView alloc] initWithFrame:CGRectMake(card.bounds.size.width - 96, -34, 132, 132)];
    blobA.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    blobA.layer.cornerRadius = 66;
    blobA.userInteractionEnabled = NO;
    [card addSubview:blobA];
    UIView *blobB = [[UIView alloc] initWithFrame:CGRectMake(card.bounds.size.width - 58, 44, 84, 84)];
    blobB.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    blobB.layer.cornerRadius = 42;
    blobB.userInteractionEnabled = NO;
    [card addSubview:blobB];

    // Twin mark: two overlapping rounded squares
    UIView *mark = [[UIView alloc] initWithFrame:CGRectMake(18, 20, 48, 48)];
    mark.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    mark.layer.cornerRadius = 15;
    mark.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *tileA = [[UIView alloc] initWithFrame:CGRectMake(9, 9, 20, 20)];
    tileA.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
    tileA.layer.cornerRadius = 6;
    tileA.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *tileB = [[UIView alloc] initWithFrame:CGRectMake(19, 19, 20, 20)];
    tileB.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    tileB.layer.cornerRadius = 6;
    tileB.layer.cornerCurve = kCACornerCurveContinuous;
    [mark addSubview:tileA];
    [mark addSubview:tileB];
    [card addSubview:mark];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(78, 22, card.bounds.size.width - 190, 32)];
    titleLabel.text = title;
    titleLabel.font = [self heroTitleFont];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(78, 54, card.bounds.size.width - 110, 18)];
    subtitleLabel.text = subtitle;
    subtitleLabel.font = [self heroSubtitleFont];
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.80];
    subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:subtitleLabel];

    // feature pills
    NSArray *features = @[@"Arc 弧形唤醒", @"Crane 分身", @"窗口记忆"];
    CGFloat x = 18.0;
    for (NSString *feature in features) {
        CGFloat textWidth = [feature sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold]}].width;
        CGFloat pillWidth = textWidth + 18.0;
        if (x + pillWidth > card.bounds.size.width - 18.0) break;
        UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(x, 84, pillWidth, 22)];
        pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        pill.layer.cornerRadius = 11;
        UILabel *pillLabel = [[UILabel alloc] initWithFrame:pill.bounds];
        pillLabel.text = feature;
        pillLabel.textAlignment = NSTextAlignmentCenter;
        pillLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
        pillLabel.textColor = [UIColor whiteColor];
        [pill addSubview:pillLabel];
        [card addSubview:pill];
        x += pillWidth + 6.0;
    }

    // status badge (top-right)
    NSString *badgeText = statusText.length ? statusText : (enabled ? @"已启用" : @"已停用");
    UIFont *badgeFont = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    CGFloat badgeTextWidth = [badgeText sizeWithAttributes:@{NSFontAttributeName: badgeFont}].width;
    CGFloat badgeWidth = badgeTextWidth + 20.0;
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(card.bounds.size.width - badgeWidth - 16.0, 20.0, badgeWidth, 24.0)
                    ];
    badge.backgroundColor = enabled ? [UIColor colorWithWhite:1.0 alpha:0.30] : [UIColor colorWithWhite:0.0 alpha:0.18];
    badge.layer.cornerRadius = 12;
    badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UILabel *badgeLabel = [[UILabel alloc] initWithFrame:badge.bounds];
    badgeLabel.text = badgeText;
    badgeLabel.textAlignment = NSTextAlignmentCenter;
    badgeLabel.font = badgeFont;
    badgeLabel.textColor = [UIColor whiteColor];
    [badge addSubview:badgeLabel];
    [card addSubview:badge];

    [container addSubview:card];
    return container;
}

@end