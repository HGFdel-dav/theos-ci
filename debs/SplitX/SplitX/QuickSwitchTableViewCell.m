//
//  QuickSwitchTableViewCell.m
//  SplitX
//
//  外观照 ParallelX：大圆角图标格子、图标下方名称、右上角账号角标、玻璃底。
//

#import "QuickSwitchTableViewCell.h"
#import "POQuickSwitchMetrics.h"
#import "POSplitTarget.h"

@interface QuickSwitchTableViewCell ()
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIVisualEffectView *badgeBackground;
@end

@implementation QuickSwitchTableViewCell

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        UIBlurEffect *tileBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight];
        UIVisualEffectView *tile = [[UIVisualEffectView alloc] initWithEffect:tileBlur];
        tile.translatesAutoresizingMaskIntoConstraints = NO;
        tile.layer.cornerRadius = POQuickSwitchTileCornerRadius;
        tile.layer.cornerCurve = kCACornerCurveContinuous;
        tile.clipsToBounds = YES;
        tile.userInteractionEnabled = NO;
        tile.alpha = 0;
        self.tileView = tile;
        [self.contentView addSubview:self.tileView];

        self.imgView = [[UIImageView alloc] initWithFrame:CGRectZero];
        self.imgView.translatesAutoresizingMaskIntoConstraints = NO;
        self.imgView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:self.imgView];

        self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.nameLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        self.nameLabel.textColor = UIColor.whiteColor;
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.nameLabel.adjustsFontSizeToFitWidth = YES;
        self.nameLabel.minimumScaleFactor = 0.7;
        self.nameLabel.layer.shadowColor = UIColor.blackColor.CGColor;
        self.nameLabel.layer.shadowOpacity = 0.5;
        self.nameLabel.layer.shadowRadius = 2;
        self.nameLabel.layer.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:self.nameLabel];

        // 账号角标：默 / 分，与 ParallelX 的分身标识一致
        self.badgeBackground = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        self.badgeBackground.translatesAutoresizingMaskIntoConstraints = NO;
        self.badgeBackground.layer.cornerRadius = 8;
        self.badgeBackground.layer.cornerCurve = kCACornerCurveContinuous;
        self.badgeBackground.clipsToBounds = YES;
        self.badgeBackground.userInteractionEnabled = NO;
        [self.contentView addSubview:self.badgeBackground];

        self.badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.badgeLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        self.badgeLabel.textColor = UIColor.whiteColor;
        self.badgeLabel.textAlignment = NSTextAlignmentCenter;
        [self.badgeBackground.contentView addSubview:self.badgeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [tile.widthAnchor constraintEqualToConstant:POQuickSwitchSelectionTileSize],
            [tile.heightAnchor constraintEqualToConstant:POQuickSwitchSelectionTileSize],
            [tile.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [tile.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:2],

            [self.imgView.widthAnchor constraintEqualToConstant:POQuickSwitchIconSize],
            [self.imgView.heightAnchor constraintEqualToConstant:POQuickSwitchIconSize],
            [self.imgView.centerXAnchor constraintEqualToAnchor:self.imgView.superview.centerXAnchor],
            [self.imgView.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],

            [self.badgeBackground.widthAnchor constraintEqualToConstant:18],
            [self.badgeBackground.heightAnchor constraintEqualToConstant:16],
            [self.badgeBackground.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:1],
            [self.badgeBackground.topAnchor constraintEqualToAnchor:tile.topAnchor constant:1],

            [self.badgeLabel.centerXAnchor constraintEqualToAnchor:self.badgeBackground.contentView.centerXAnchor],
            [self.badgeLabel.centerYAnchor constraintEqualToAnchor:self.badgeBackground.contentView.centerYAnchor],

            [self.nameLabel.topAnchor constraintEqualToAnchor:tile.bottomAnchor constant:2],
            [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:2],
            [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-2],
        ]];

        self.backgroundColor = [UIColor clearColor];
        self.layoutMargins = UIEdgeInsetsZero;
        self.preservesSuperviewLayoutMargins = NO;
        self.contentView.layoutMargins = UIEdgeInsetsZero;
        self.contentView.preservesSuperviewLayoutMargins = NO;
        self.contentView.insetsLayoutMarginsFromSafeArea = NO;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;
    }
    return self;
}

-(void)setTarget:(POSplitTarget *)target{
    _target = target;
    self.nameLabel.text = target.isDefaultContainer ? @"默认" : target.containerDisplayName;
    BOOL showsBadge = target.containerIdentifier.length > 0;
    self.badgeBackground.hidden = !showsBadge;
    self.badgeLabel.text = target.isDefaultContainer ? @"默" : @"分";
}

-(void)setNameLabelHidden:(BOOL)hidden{
    _nameLabelHidden = hidden;
    self.nameLabel.hidden = hidden;
    self.badgeBackground.hidden = hidden || !self.target;
}

-(void)layoutSubviews{
    [super layoutSubviews];
    self.contentView.frame = self.bounds;
    [self.contentView layoutIfNeeded];
}

@end
