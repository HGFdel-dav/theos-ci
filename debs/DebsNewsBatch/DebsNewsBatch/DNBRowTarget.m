//
//  DNBRowTarget.m
//  DebsNewsBatch
//

#import "DNBRowTarget.h"

@interface DNBRowTarget ()
@property (nonatomic, strong) UIView *halo;
@property (nonatomic, strong) UIView *circle;
@property (nonatomic, strong) UIImageView *tick;
@property (nonatomic, strong) UILabel *status;
@end

@implementation DNBRowTarget

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 10;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _halo = [UIView new];
        _halo.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        _halo.layer.cornerRadius = 14;
        _halo.userInteractionEnabled = NO;
        [self addSubview:_halo];

        _circle = [UIView new];
        _circle.layer.cornerRadius = 10;
        _circle.layer.borderWidth = 1.4;
        _circle.layer.borderColor = [UIColor colorWithWhite:0.62 alpha:1].CGColor;
        _circle.backgroundColor = [UIColor clearColor];
        _circle.userInteractionEnabled = NO;
        [self addSubview:_circle];

        _tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        _tick.tintColor = [UIColor whiteColor];
        _tick.contentMode = UIViewContentModeScaleAspectFit;
        _tick.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightBold]];
        _tick.userInteractionEnabled = NO;
        [self addSubview:_tick];

        _status = [UILabel new];
        _status.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        _status.textColor = [UIColor secondaryLabelColor];
        _status.textAlignment = NSTextAlignmentRight;
        _status.userInteractionEnabled = NO;
        [self addSubview:_status];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
        [self addTarget:self action:@selector(handleDown) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(handleUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat midY = CGRectGetMidY(self.bounds);
    self.halo.frame = CGRectMake(4, midY - 14, 28, 28);
    self.circle.frame = CGRectMake(8, midY - 10, 20, 20);
    self.tick.frame = CGRectMake(10.5, midY - 7.5, 15, 15);
    self.status.frame = CGRectMake(self.bounds.size.width - 92, midY - 9, 82, 18);
}

- (void)handleDown
{
    self.transform = CGAffineTransformMakeScale(0.985, 0.985);
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
}

- (void)handleUp
{
    self.transform = CGAffineTransformIdentity;
    self.backgroundColor = self.chosen ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.12] : [UIColor clearColor];
}

- (void)setChosen:(BOOL)chosen
{
    _chosen = chosen;
    self.backgroundColor = chosen ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.12] : [UIColor clearColor];
    self.circle.backgroundColor = chosen ? [UIColor systemBlueColor] : [UIColor colorWithWhite:1 alpha:0.55];
    self.circle.layer.borderColor = (chosen ? [UIColor systemBlueColor] : [UIColor colorWithWhite:0.62 alpha:1]).CGColor;
    self.tick.hidden = !chosen;
}

- (void)setStatusText:(NSString *)text
{
    _statusText = [text copy];
    self.status.text = text;
    if (text.length) {
        if ([text isEqualToString:@"完成"]) {
            self.status.textColor = [UIColor systemGreenColor];
        } else if ([text isEqualToString:@"失败"] || [text isEqualToString:@"已存在"]) {
            self.status.textColor = [UIColor systemOrangeColor];
        } else {
            self.status.textColor = [UIColor systemBlueColor];
        }
    }
}

- (void)handleTap
{
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@end
