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

        _halo = [UIView new];
        _halo.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        _halo.layer.cornerRadius = 15;
        _halo.userInteractionEnabled = NO;
        [self addSubview:_halo];

        _circle = [UIView new];
        _circle.layer.cornerRadius = 11;
        _circle.layer.borderWidth = 1.6;
        _circle.layer.borderColor = [UIColor colorWithWhite:0.62 alpha:1].CGColor;
        _circle.backgroundColor = [UIColor clearColor];
        _circle.userInteractionEnabled = NO;
        [self addSubview:_circle];

        _tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        _tick.tintColor = [UIColor whiteColor];
        _tick.contentMode = UIViewContentModeScaleAspectFit;
        _tick.userInteractionEnabled = NO;
        [self addSubview:_tick];

        _status = [UILabel new];
        _status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _status.textColor = [UIColor secondaryLabelColor];
        _status.textAlignment = NSTextAlignmentRight;
        _status.userInteractionEnabled = NO;
        [self addSubview:_status];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat midY = CGRectGetMidY(self.bounds);
    self.halo.frame = CGRectMake(6, midY - 15, 30, 30);
    self.circle.frame = CGRectMake(10, midY - 11, 22, 22);
    self.tick.frame = CGRectMake(12.5, midY - 8.5, 17, 17);
    self.status.frame = CGRectMake(self.bounds.size.width - 96, midY - 9, 86, 18);
}

- (void)setChosen:(BOOL)chosen
{
    _chosen = chosen;
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
