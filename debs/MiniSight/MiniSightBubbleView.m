#import "MiniSightBubbleView.h"
#import "MiniSightBubbleLayout.h"
#import <QuartzCore/QuartzCore.h>

@interface MiniSightBubbleView ()
@property (nonatomic, strong) UIScrollView *textScroll;
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIStackView *buttons;
@property (nonatomic, strong) CAShapeLayer *tail;
@property (nonatomic, copy) NSString *currentText;
@property (nonatomic) BOOL approval;
@property (nonatomic) BOOL decisionValid;
@property (nonatomic) CGFloat currentWidth;
@property (nonatomic) CGFloat currentHeight;
@end

@implementation MiniSightBubbleView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.opaque = NO;
    self.hidden = YES;
    self.layer.borderWidth = .5;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _textScroll = [[UIScrollView alloc] init];
    _textScroll.backgroundColor = UIColor.clearColor;
    _textScroll.alwaysBounceVertical = NO;
    _textScroll.showsHorizontalScrollIndicator = NO;
    _textScroll.showsVerticalScrollIndicator = YES;
    _textScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _textLabel = [[UILabel alloc] init];
    _textLabel.numberOfLines = 0;
    _textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    _textLabel.adjustsFontSizeToFitWidth = NO;
    _textLabel.userInteractionEnabled = NO;
    [_textScroll addSubview:_textLabel];
    [self addSubview:_textScroll];
    _buttons = [[UIStackView alloc] init];
    _buttons.axis = UILayoutConstraintAxisHorizontal;
    _buttons.distribution = UIStackViewDistributionFillEqually;
    _buttons.spacing = 8.;
    for (NSUInteger i = 0; i < 2; ++i) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)i;
        button.titleLabel.font = [UIFont systemFontOfSize:14. weight:UIFontWeightMedium];
        [button setTitle:i ? @"允许" : @"拒绝" forState:UIControlStateNormal];
        button.layer.cornerRadius = 10.;
        button.clipsToBounds = YES;
        [button addTarget:self action:@selector(decide:) forControlEvents:UIControlEventTouchUpInside];
        [_buttons addArrangedSubview:button];
    }
    [self addSubview:_buttons];
    // Fixed local path, translated by position only while following the pet.
    _tail = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0., 0.)];
    [path addQuadCurveToPoint:CGPointMake(6., 6.) controlPoint:CGPointMake(2.8, 4.4)];
    [path addQuadCurveToPoint:CGPointMake(12., 0.) controlPoint:CGPointMake(9.2, 4.4)];
    [path closePath];
    _tail.path = path.CGPath;
    _tail.bounds = CGRectMake(0., 0., 12., 6.);
    _tail.anchorPoint = CGPointZero;
    [self.layer insertSublayer:_tail atIndex:0];
    [self updateColors];
    return self;
}

- (void)updateColors {
    self.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.layer.borderColor = UIColor.separatorColor.CGColor;
    _tail.fillColor = self.backgroundColor.CGColor;
    _textLabel.textColor = UIColor.labelColor;
    for (UIButton *b in _buttons.arrangedSubviews) {
        b.backgroundColor = b.tag ? UIColor.systemBlueColor : UIColor.tertiarySystemFillColor;
        [b setTitleColor:b.tag ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) [self updateColors];
}
- (void)showText:(NSString *)text approval:(BOOL)approval maxWidth:(CGFloat)width maxHeight:(CGFloat)height {
    NSAssert(NSThread.isMainThread, @"bubble UI main-thread only");
    if (!text.length || !isfinite(width) || !isfinite(height)) return;
    BOOL same = [_currentText isEqualToString:text] && _approval == approval &&
        fabs(_currentWidth-width) < .25 && fabs(_currentHeight-height) < .25;
    self.hidden = NO;
    _decisionValid = approval;
    _buttons.userInteractionEnabled = approval;
    if (same) return;
    _currentText = [text copy]; _approval = approval;
    _currentWidth = width; _currentHeight = height;
    _textLabel.font = [UIFont systemFontOfSize:13.];
    CGFloat minimumHeight = _textLabel.font.lineHeight + (approval ? 68. : 16.);
    if (width < (approval ? 160. : 25.) || height < minimumHeight) {
        [self invalidateApproval];
        return;
    }
    _textLabel.text = text;
    CGFloat measureWidth = MSBubbleTextWidth(width - 24., width, approval);
    CGSize natural = [_textLabel sizeThatFits:CGSizeMake(measureWidth, CGFLOAT_MAX)];
    MSBubbleContent layout = MSBubbleContentMake(ceil(natural.width),
                                                  ceil(natural.height)+1., width, approval, 0);
    // Remeasure at the EXACT final label width. No subtracting padding twice.
    CGSize fitted = [_textLabel sizeThatFits:CGSizeMake(layout.text.w, CGFLOAT_MAX)];
    CGFloat fullHeight = ceil(fitted.height) + 1.;
    CGFloat chrome = approval ? 68. : 16.;
    CGFloat viewportHeight = MIN(fullHeight, MAX(1., floor(height - chrome)));
    layout = MSBubbleContentMake(layout.text.w, viewportHeight, width, approval, 0);
    _textLabel.textAlignment = (!approval && fullHeight <= ceil(_textLabel.font.lineHeight)+2.)
        ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.bounds = CGRectMake(0., 0., layout.size.w, layout.size.h);
    self.layer.cornerRadius = layout.radius;
    _textScroll.frame = CGRectMake(layout.text.x, layout.text.y, layout.text.w, viewportHeight);
    _textLabel.frame = CGRectMake(0., 0., layout.text.w, fullHeight);
    _textScroll.contentSize = CGSizeMake(layout.text.w, fullHeight);
    _textScroll.contentOffset = CGPointZero;
    _textScroll.scrollEnabled = fullHeight > viewportHeight + .5;
    _buttons.frame = CGRectMake(layout.buttons.x, layout.buttons.y, layout.buttons.w, layout.buttons.h);
    _buttons.hidden = !approval;
    [CATransaction commit];
    self.userInteractionEnabled = approval || _textScroll.scrollEnabled;
    if (_onSizeChanged) _onSizeChanged();
}
- (void)setTailX:(CGFloat)x {
    CGFloat radius = self.layer.cornerRadius;
    CGFloat cx = MSClamp(x, radius+6., MAX(radius+6., self.bounds.size.width-radius-6.));
    CGPoint position = CGPointMake(cx - 6., self.bounds.size.height);
    if (CGPointEqualToPoint(_tail.position, position)) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _tail.position = position;
    [CATransaction commit];
}
- (BOOL)approvalVisible {
    return _approval && _decisionValid && !self.hidden && self.alpha > .01 &&
        self.window && !self.window.hidden && self.window.alpha > .01 &&
        _textLabel.text.length && _textScroll.bounds.size.height >= _textLabel.font.lineHeight &&
        !_buttons.hidden && _buttons.bounds.size.height >= 44.;
}
- (void)invalidateApproval {
    _decisionValid = NO;
    _buttons.userInteractionEnabled = NO;
    _approval = NO;
    self.hidden = YES;
}
- (void)decide:(UIButton *)button {
    if (!self.approvalVisible) return;
    void (^decision)(BOOL) = _onDecision;
    if (!decision) return;
    _buttons.userInteractionEnabled = NO;
    // The host rechecks request authority while the presented flag is still
    // true, then synchronously dismisses this UI. A second tap is disabled.
    decision(button.tag == 1);
    _decisionValid = NO;
}
@end
