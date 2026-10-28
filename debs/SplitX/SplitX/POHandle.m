//
//  MHHandle.m
//  MessageHub
//
//  Created by Will Smillie on 1/18/19.
//

#import "POHandle.h"
#import <QuartzCore/QuartzCore.h>
#import "SplitViewController.h"

#import "POApplicationHelper.h"

#define PO_HANDLE_DEFAULT_SIZE 30.0
#define PO_HANDLE_MINIMUM_SIZE 34.0
#define PO_HANDLE_MAXIMUM_SIZE 50.0
#define PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE 67.0
#define PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE 80.0
#define PO_HANDLE_MINIMUM_TOUCH_SIZE 52.0

@interface POHandle () <UIGestureRecognizerDelegate> {
    UILabel *messageLabel;
    UIVisualEffectView *blurView;
    UITapGestureRecognizer *_tapGestureRecognizer;
    UILongPressGestureRecognizer *quickSwitchLongPress;
    UIPanGestureRecognizer *_panelPanGestureRecognizer;
    CGPoint tapTouchStartPoint;
    BOOL hasTapTouchStartPoint;
}

-(void)applyCurrentPresentationAnimated:(BOOL)animated;

@end

@implementation POHandle

-(CGFloat)handleSize{
    id configuredValue = [POApplicationHelper settings][@"handleSize"];
    CGFloat size = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_SIZE;
    if (size <= 0) {
        size = PO_HANDLE_DEFAULT_SIZE;
    }
    return MIN(MAX(size, PO_HANDLE_MINIMUM_SIZE), PO_HANDLE_MAXIMUM_SIZE);
}

-(CGFloat)nubHiddenPercentage{
    id configuredValue = [POApplicationHelper settings][@"nubHiddenPercentage"];
    CGFloat percentage = configuredValue ? [configuredValue doubleValue] : PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    if (percentage < 0) {
        percentage = PO_HANDLE_DEFAULT_NUB_HIDDEN_PERCENTAGE;
    }
    return MIN(MAX(percentage, 0), PO_HANDLE_MAXIMUM_NUB_HIDDEN_PERCENTAGE);
}

-(CGFloat)fullCornerRadius{
    return CGRectGetHeight(self.bounds) / 2.0;
}

-(CGFloat)nubbedCornerRadius{
    return CGRectGetHeight(self.bounds) / 2.0;
}

-(BOOL)usesNubbedPresentation{
    return self.layoutMode == POHandleLayoutModeVerticalRail && self.isNubbed;
}

-(CGFloat)nubbedOriginX{
    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        containerWidth = 50.0;
    }
    CGFloat visibleWidth = CGRectGetWidth(self.bounds) * (1.0 - [self nubHiddenPercentage] / 100.0);
    return containerWidth - visibleWidth;
}

-(void)applyNubbedPosition{
    CGRect frame = self.frame;
    frame.origin.x = [self nubbedOriginX];
    self.frame = frame;
}

-(void)applyHandleSize{
    CGFloat size = [self handleSize];
    // PX 形态：贴边的半圆把，宽度是高度的一半，外侧两角整圆。
    CGRect frame = self.frame;
    frame.size = CGSizeMake(size * 0.52, size * 1.55);
    self.frame = frame;
    self.layer.cornerRadius = CGRectGetWidth(self.bounds) / 2.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    self.clipsToBounds = NO;

    CGFloat iconSize = MAX(0, size - 10.0);
    self.imageView.frame = CGRectMake((CGRectGetWidth(self.bounds) - iconSize) / 2.0,
                                      (CGRectGetHeight(self.bounds) - iconSize) / 2.0,
                                      iconSize,
                                      iconSize);
    blurView.frame = self.bounds;
    blurView.layer.cornerRadius = CGRectGetWidth(self.bounds) / 2.0;
    blurView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
}

-(instancetype)initWithController:(id)hubController{
    if (self = [super initWithFrame:CGRectMake(0, 0, PO_HANDLE_DEFAULT_SIZE, PO_HANDLE_DEFAULT_SIZE)]) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        // PX 风格三点握把
        UIStackView *grip = [[UIStackView alloc] init];
        grip.axis = UILayoutConstraintAxisVertical;
        grip.spacing = 3.0;
        grip.userInteractionEnabled = NO;
        grip.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:grip];
        for (int i = 0; i < 3; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3.0, 3.0)];
            dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
            dot.layer.cornerRadius = 1.5;
            [grip addArrangedSubview:dot];
        }
        [NSLayoutConstraint activateConstraints:@[
            [grip.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [grip.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        self.layer.cornerRadius = 8;
        [self.layer setShadowColor:[UIColor blackColor].CGColor];
        [self.layer setShadowOpacity:0.32];
        [self.layer setShadowRadius:3.5];
        [self.layer setShadowOffset:CGSizeMake(0, 0)];

        _tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
        _tapGestureRecognizer.delegate = self;
        [self addGestureRecognizer:_tapGestureRecognizer];

        quickSwitchLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
        quickSwitchLongPress.minimumPressDuration = 0.05f;
        quickSwitchLongPress.allowableMovement = 200.0f;
        quickSwitchLongPress.delegate = self;
        quickSwitchLongPress.cancelsTouchesInView = NO;
        [self addGestureRecognizer:quickSwitchLongPress];
        [_tapGestureRecognizer requireGestureRecognizerToFail:quickSwitchLongPress];
        _panelPanGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(panelPan:)];
        _panelPanGestureRecognizer.delegate = self;
        _panelPanGestureRecognizer.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:_panelPanGestureRecognizer];
        [_panelPanGestureRecognizer requireGestureRecognizerToFail:quickSwitchLongPress];
        [_tapGestureRecognizer requireGestureRecognizerToFail:_panelPanGestureRecognizer];
        
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = self.bounds;
        blurView.userInteractionEnabled = NO;
        blurView.layer.cornerRadius = 8;
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        blurView.clipsToBounds = YES;
        [self addSubview:blurView];
        

        self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self.imageView setBackgroundColor:[UIColor clearColor]];
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.clipsToBounds = YES;
        self.imageView.tintColor = [UIColor lightGrayColor];
        [self addSubview:self.imageView];
        self.layoutMode = POHandleLayoutModeVerticalRail;
        [self applyHandleSize];
        
        [self setIsNubbed:[[NSUserDefaults standardUserDefaults] boolForKey:@"isNubbed"]];
    }
    return self;
}

-(void)setIsNubbed:(BOOL)isNubbed{
    _isNubbed = isNubbed;
    [[NSUserDefaults standardUserDefaults] setBool:isNubbed forKey:@"isNubbed"];
    [self applyCurrentPresentationAnimated:YES];
}

-(void)setLayoutMode:(POHandleLayoutMode)layoutMode{
    if (_layoutMode == layoutMode) {
        return;
    }
    _layoutMode = layoutMode;
    [self applyCurrentPresentationAnimated:NO];
}

-(void)applyCurrentPresentationAnimated:(BOOL)animated{
    void (^changes)(void) = ^{
        if ([self usesNubbedPresentation]) {
            [self applyNubbedPosition];
            self->blurView.layer.cornerRadius = [self nubbedCornerRadius];
        } else {
            CGRect frame = self.frame;
            frame.origin.x = self.restingOriginX;
            self.frame = frame;
            self->blurView.layer.cornerRadius = [self fullCornerRadius];
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.3 animations:changes];
    } else {
        changes();
    }
}

-(void)refreshHandleSizeAnimated:(BOOL)animated{
    void (^changes)(void) = ^{
        [self applyHandleSize];
    };
    if (animated) {
        [UIView animateWithDuration:0.2 animations:changes];
    } else {
        changes();
    }
}

-(void)refreshNubbedPositionAnimated:(BOOL)animated{
    [self applyCurrentPresentationAnimated:animated];
}

-(void)layoutSubviews{
    [super layoutSubviews];
    blurView.frame = self.bounds;
}

-(BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event{
    if (self.layoutMode == POHandleLayoutModeLandscapeFixedBottomLeft) {
        CGFloat horizontalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetWidth(self.bounds)) / 2.0);
        CGFloat verticalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetHeight(self.bounds)) / 2.0);
        CGRect hitRect = CGRectInset(self.bounds, -horizontalInset, -verticalInset);
        return CGRectContainsPoint(hitRect, point);
    }

    CGFloat containerWidth = CGRectGetWidth(self.superview.bounds);
    if (containerWidth <= 0) {
        containerWidth = 50.0;
    }

    CGFloat desiredHitLeftInContainer = containerWidth - PO_HANDLE_MINIMUM_TOUCH_SIZE;
    CGFloat leadingInset = MAX(5.0, CGRectGetMinX(self.frame) - desiredHitLeftInContainer);
    CGFloat verticalInset = MAX(5.0, (PO_HANDLE_MINIMUM_TOUCH_SIZE - CGRectGetHeight(self.bounds)) / 2.0);
    CGRect hitRect = CGRectMake(-leadingInset,
                                -verticalInset,
                                CGRectGetWidth(self.bounds) + leadingInset + 5.0,
                                CGRectGetHeight(self.bounds) + verticalInset * 2.0);
    return CGRectContainsPoint(hitRect, point);
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if ([self.superview isKindOfClass:[UIScrollView class]]) {
        UIPanGestureRecognizer *railPan = ((UIScrollView *)self.superview).panGestureRecognizer;
        [railPan requireGestureRecognizerToFail:quickSwitchLongPress];
        [railPan requireGestureRecognizerToFail:_panelPanGestureRecognizer];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == _tapGestureRecognizer && hasTapTouchStartPoint) {
        hasTapTouchStartPoint = NO;
        CGPoint endPoint = [gestureRecognizer locationInView:self];
        return hypot(endPoint.x - tapTouchStartPoint.x, endPoint.y - tapTouchStartPoint.y) <= 5.0;
    }
    if (gestureRecognizer == _panelPanGestureRecognizer) {
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self];
        CGFloat absX = fabs(velocity.x);
        CGFloat absY = fabs(velocity.y);
        if (self.layoutMode == POHandleLayoutModeLandscapeFixedBottomLeft) {
            return MAX(absX, absY) > 0.0 && fabs(absX - absY) > 0.01;
        }
        return absX > absY;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _tapGestureRecognizer) {
        tapTouchStartPoint = [touch locationInView:self];
        hasTapTouchStartPoint = YES;
    }
    return YES;
}


-(void)tap:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didReceiveTap:recognizer];
}

-(void)longPress:(UIGestureRecognizer *)recognizer{
    [self.delegate handle:self didLongPress:recognizer];
}

-(void)panelPan:(UIPanGestureRecognizer *)recognizer{
    [self.delegate handle:self didPanPanel:recognizer];
}


@end
