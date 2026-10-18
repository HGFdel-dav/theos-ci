// TWCells.m
#import "TWCells.h"

static const CGFloat kChipSize = 34.0;
static const CGFloat kMarginLeft = 16.0;
static const CGFloat kMarginRight = 16.0;
static const CGFloat kTitleGap = 14.0;

@implementation TWBaseCell {
    TWChipView *_chip;
    UILabel *_twTitle;
    UIView *_controlHost;
    CGFloat _controlWidth;
}

#pragma mark - setup

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self twBuild];
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}

- (void)twBuild {
    if (_twTitle) return;
    _chip = [TWStyle chipWithSymbol:nil fallback:nil];
    [self.contentView addSubview:_chip];

    _twTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _twTitle.font = [TWStyle rowTitleFont];
    _twTitle.textColor = [UIColor labelColor];
    _twTitle.numberOfLines = 2;
    [self.contentView addSubview:_twTitle];

    _controlHost = [[UIView alloc] initWithFrame:CGRectZero];
    _controlHost.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:_controlHost];

    self.titleLabel.hidden = YES;
}

#pragma mark - appearance

- (NSString *)twKey { return [self.specifier propertyForKey:@"key"]; }

- (void)twApplyAppearance {
    if (!_twTitle) [self twBuild];
    NSString *title = self.specifier.name ?: @"";
    _twTitle.text = title;

    NSString *symbol = [self.specifier propertyForKey:@"twSymbol"];
    NSString *subtitle = [self.specifier propertyForKey:@"twSubtitle"];
    if ([subtitle isKindOfClass:NSString.class] && subtitle.length) _twTitle.text = subtitle;

    [_chip setSymbolNamed:symbol fallbackText:title];

    // Everything except the master switch dims while Twin is off.
    NSString *key = [self twKey];
    BOOL master = [key isEqualToString:TWKeyEnabled];
    BOOL off = master ? NO : ![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO];
    _chip.alpha = off ? 0.35 : 1.0;
    _twTitle.textColor = off ? [UIColor tertiaryLabelColor] : [UIColor labelColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_twTitle) [self twBuild];

    CGFloat height = self.contentView.bounds.size.height;
    CGFloat width = self.contentView.bounds.size.width;

    _chip.frame = CGRectMake(kMarginLeft, (height - kChipSize) / 2.0, kChipSize, kChipSize);
    _controlWidth = [self twLayoutControlInHeight:height width:width];

    CGFloat titleX = kMarginLeft + kChipSize + kTitleGap;
    CGFloat titleMaxX = width - kMarginRight - (_controlWidth > 0 ? _controlWidth + 12.0 : 0.0);
    CGFloat titleWidth = MAX(60.0, titleMaxX - titleX);
    CGSize titleSize = [_twTitle sizeThatFits:CGSizeMake(titleWidth, height)];
    _twTitle.frame = CGRectMake(titleX, (height - titleSize.height) / 2.0, titleWidth, titleSize.height);
}

- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width { return 0; }

#pragma mark - values

- (void)twSaveObject:(id)value forKey:(NSString *)key {
    if (!key.length) return;
    [[TWPrefs shared] setObject:value forKey:key];
    [[TWPrefs shared] synchronize];
}

- (void)twNotifyHostReload {
    id target = self.specifier.target;
    if ([target respondsToSelector:@selector(reloadSpecifiers)]) [(PSListController *)target reloadSpecifiers];
}

@end

#pragma mark - switch

@implementation TWSwitchCell {
    UISwitch *_toggle;
}

- (void)twBuild {
    [super twBuild];
    if (_toggle) return;
    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.onTintColor = [TWStyle accent];
    [_toggle addTarget:self action:@selector(twToggleChanged) forControlEvents:UIControlEventValueChanged];
    [_controlHost addSubview:_toggle];
}

- (void)twToggleChanged {
    [self twSaveObject:@(_toggle.isOn) forKey:[self twKey]];
    [self twNotifyHostReload];
}

- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width {
    CGSize size = _toggle.intrinsicContentSize;
    _controlHost.frame = CGRectMake(width - kMarginRight - size.width, (height - size.height) / 2.0, size.width, size.height);
    _toggle.frame = _controlHost.bounds;
    return size.width;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_toggle) [self twBuild];
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    _toggle.on = [[TWPrefs shared] boolForKey:key defaultValue:[fallback respondsToSelector:@selector(boolValue)] ? [fallback boolValue] : NO];
    self.titleLabel.hidden = YES;
    [self twApplyAppearance];
    [self setNeedsLayout];
}

@end

#pragma mark - slider (two-line: title + value on top, track below)

@implementation TWSliderCell {
    UISlider *_slider;
    UILabel *_valueLabel;
}

- (void)twBuild {
    [super twBuild];
    if (_slider) return;
    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumTrackTintColor = [TWStyle accent];
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:0.5 alpha:0.20];
    _slider.thumbTintColor = [TWStyle accent];
    _slider.continuous = YES;
    [_slider addTarget:self action:@selector(twSliderMoved) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(twSliderCommitted) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [_controlHost addSubview:_slider];

    _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _valueLabel.font = [TWStyle rowValueFont];
    _valueLabel.textColor = [TWStyle accent];
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [_controlHost addSubview:_valueLabel];
}

- (CGFloat)twCurrentValue {
    id stored = [[TWPrefs shared] objectForKey:[self twKey]];
    id fallback = [self.specifier propertyForKey:@"default"];
    if ([stored respondsToSelector:@selector(doubleValue)]) return [stored doubleValue];
    if ([fallback respondsToSelector:@selector(doubleValue)]) return [fallback doubleValue];
    return _slider.minimumValue;
}

- (NSString *)twValueText:(CGFloat)value {
    NSString *unit = [self.specifier propertyForKey:@"twUnit"];
    return [NSString stringWithFormat:@"%.0f%@", value, [unit isKindOfClass:NSString.class] ? unit : @""];
}

- (void)twSliderMoved {
    CGFloat value = _slider.value;
    NSNumber *step = [self.specifier propertyForKey:@"twStep"];
    if ([step respondsToSelector:@selector(doubleValue)] && [step doubleValue] > 0) {
        double s = [step doubleValue];
        value = (CGFloat)(round(value / s) * s);
    }
    _valueLabel.text = [self twValueText:value];
}

- (void)twSliderCommitted {
    [self twSliderMoved];
    [self twSaveObject:@(_slider.value) forKey:[self twKey]];
    [self twNotifyHostReload];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_slider) [self twBuild];

    CGFloat height = self.contentView.bounds.size.height;
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat titleX = kMarginLeft + kChipSize + kTitleGap;

    _chip.frame = CGRectMake(kMarginLeft, 14.0, kChipSize, kChipSize);

    CGFloat valueWidth = 72.0;
    _valueLabel.frame = CGRectMake(width - kMarginRight - valueWidth, 16.0, valueWidth, 20.0);

    CGSize titleSize = [_twTitle sizeThatFits:CGSizeMake(width - titleX - valueWidth - kMarginRight - 8.0, 40.0)];
    _twTitle.frame = CGRectMake(titleX, 16.0, width - titleX - valueWidth - kMarginRight - 8.0, titleSize.height);

    CGFloat trackY = height - 26.0;
    _slider.frame = CGRectMake(titleX, trackY, width - titleX - kMarginRight, 22.0);
    _controlHost.frame = self.contentView.bounds;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_slider) [self twBuild];
    id min = [specifier propertyForKey:@"twMin"];
    id max = [specifier propertyForKey:@"twMax"];
    _slider.minimumValue = [min respondsToSelector:@selector(floatValue)] ? [min floatValue] : 0.0f;
    _slider.maximumValue = [max respondsToSelector:@selector(floatValue)] ? [max floatValue] : 1.0f;
    _slider.value = [self twCurrentValue];
    _valueLabel.text = [self twValueText:_slider.value];
    self.titleLabel.hidden = YES;
    [self twApplyAppearance];
    [self setNeedsLayout];
}

@end

#pragma mark - segmented

@implementation TWSegmentCell {
    UISegmentedControl *_segment;
}

- (void)twBuild {
    [super twBuild];
    if (_segment) return;
    _segment = [[UISegmentedControl alloc] initWithItems:@[]];
    if (@available(iOS 13.0, *)) _segment.selectedSegmentTintColor = [TWStyle accent];
    [_segment addTarget:self action:@selector(twSegmentChanged) forControlEvents:UIControlEventValueChanged];
    [_controlHost addSubview:_segment];
}

- (void)twSegmentChanged {
    [self twSaveObject:@(_segment.selectedSegmentIndex) forKey:[self twKey]];
    [self twNotifyHostReload];
}

- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width {
    NSArray *titles = [self.specifier propertyForKey:@"twTitles"];
    NSInteger count = [titles isKindOfClass:NSArray.class] ? (NSInteger)titles.count : 2;
    CGFloat segmentWidth = MAX(120.0, 62.0 * (CGFloat)count);
    CGFloat limit = MAX(120.0, width - (kMarginLeft + kChipSize + kTitleGap) - kMarginRight - 110.0);
    segmentWidth = MIN(segmentWidth, limit);
    CGSize size = CGSizeMake(segmentWidth, 32.0);
    _controlHost.frame = CGRectMake(width - kMarginRight - size.width, (height - size.height) / 2.0, size.width, size.height);
    _segment.frame = _controlHost.bounds;
    return size.width;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_segment) [self twBuild];
    NSArray *titles = [specifier propertyForKey:@"twTitles"];
    [_segment removeAllSegments];
    if ([titles isKindOfClass:NSArray.class]) {
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            [_segment insertSegmentWithTitle:titles[i] atIndex:(NSUInteger)i animated:NO];
        }
    }
    NSString *key = [specifier propertyForKey:@"key"];
    id fallback = [specifier propertyForKey:@"default"];
    NSInteger value = [[TWPrefs shared] integerForKey:key defaultValue:[fallback respondsToSelector:@selector(integerValue)] ? [fallback integerValue] : 0];
    if (value < 0 || value >= _segment.numberOfSegments) value = 0;
    _segment.selectedSegmentIndex = value;
    self.titleLabel.hidden = YES;
    [self twApplyAppearance];
    [self setNeedsLayout];
}

@end

#pragma mark - action / link

@implementation TWActionCell {
    UILabel *_detailLabel;
}

- (void)twBuild {
    [super twBuild];
    if (_detailLabel) return;
    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textAlignment = NSTextAlignmentRight;
    [_controlHost addSubview:_detailLabel];
}

- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width {
    BOOL destructive = [[self.specifier propertyForKey:@"twDestructive"] boolValue];
    CGFloat chevronWidth = destructive ? 0.0 : 18.0;
    CGFloat available = MAX(80.0, width * 0.45);
    _detailLabel.frame = CGRectMake(width - kMarginRight - chevronWidth - available, (height - 20.0) / 2.0, available, 20.0);
    _controlHost.frame = self.contentView.bounds;
    return (destructive ? available : available + chevronWidth);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_detailLabel) [self twBuild];
    self.titleLabel.hidden = YES;

    BOOL destructive = [[specifier propertyForKey:@"twDestructive"] boolValue];
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    _detailLabel.text = [specifier propertyForKey:@"twDetail"];
    _detailLabel.textColor = destructive ? [TWStyle danger] : [UIColor secondaryLabelColor];

    [self twApplyAppearance];
    if (destructive) {
        _twTitle.textColor = [TWStyle danger];
        self.accessoryType = UITableViewCellAccessoryNone;
    } else {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    [self setNeedsLayout];
}

@end

#pragma mark - status readout

@implementation TWStatusCell {
    UILabel *_statusLabel;
}

- (void)twBuild {
    [super twBuild];
    if (_statusLabel) return;
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.font = [TWStyle rowValueFont];
    _statusLabel.textAlignment = NSTextAlignmentRight;
    [_controlHost addSubview:_statusLabel];
}

- (CGFloat)twLayoutControlInHeight:(CGFloat)height width:(CGFloat)width {
    CGFloat available = MAX(90.0, width * 0.42);
    _statusLabel.frame = CGRectMake(width - kMarginRight - available, (height - 20.0) / 2.0, available, 20.0);
    _controlHost.frame = self.contentView.bounds;
    return available;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    if (!_statusLabel) [self twBuild];
    self.titleLabel.hidden = YES;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.accessoryType = UITableViewCellAccessoryNone;

    NSString *value = [specifier propertyForKey:@"twDetail"];
    BOOL positive = [[specifier propertyForKey:@"twPositive"] boolValue];
    _statusLabel.text = value;
    _statusLabel.textColor = positive ? [TWStyle accent] : [UIColor secondaryLabelColor];
    [self twApplyAppearance];
    [self setNeedsLayout];
}

@end