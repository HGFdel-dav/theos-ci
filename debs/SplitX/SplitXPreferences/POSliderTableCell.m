#import "POSliderTableCell.h"
#import "POSplitXLog.h"

@interface POSliderTableCell ()
- (UIViewController *)_viewControllerForAncestor;
@end

@implementation POSliderTableCell

- (UISlider *)slider {
    return (UISlider *)self.control;
}

@dynamic control;

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.userInteractionEnabled = YES;
        [_valueLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(editValue:)]];
        [self.contentView addSubview:_valueLabel];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        [self.contentView addSubview:self.control];
        [self.control addTarget:self action:@selector(sliderChanged:)
               forControlEvents:UIControlEventValueChanged];
    }
    return self;
}

- (UISlider *)newControl {
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
    slider.continuous = NO;
    return slider;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    NSNumber *minimum = [specifier propertyForKey:@"minimumValue"];
    NSNumber *maximum = [specifier propertyForKey:@"maximumValue"];
    UISlider *slider = self.control;
    if (!slider) {
        slider = [self newControl];
        [self setValue:slider forKey:@"control"];
    }
    if (!slider.superview) [self.contentView addSubview:slider];
    [slider removeTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    slider.minimumValue = minimum ? minimum.floatValue : 0;
    slider.maximumValue = maximum ? maximum.floatValue : 100;
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateLabel];
    [self setNeedsLayout];
}

- (void)setValue:(NSNumber *)value {
    [super setValue:value];
    self.slider.value = value.floatValue;
    [self updateLabel];
}

- (void)controlChanged:(UISlider *)slider {
    [super controlChanged:slider];
    [self updateLabel];
}

- (void)sliderChanged:(UISlider *)slider {
    // 自己写，不依赖父类那套 setter。
    NSString *key = [self.specifier propertyForKey:@"key"];
    NSString *suite = [self.specifier propertyForKey:@"defaults"];
    NSInteger step = [[self.specifier propertyForKey:@"stepValue"] integerValue];
    CGFloat value = slider.value;
    if (step > 1) value = round(value / step) * step;
    if (key.length && suite.length) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        id before = [defaults objectForKey:key];
        [defaults setObject:@((long)value) forKey:key];
        BOOL synced = [defaults synchronize];
        PXLogMessage(PXLogLevelInfo, @"prefs", @"slider %@ %@ -> %ld sync=%d range=%.0f..%.0f",
                     key, before ?: @"(空)", (long)value, synced,
                     slider.minimumValue, slider.maximumValue);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.niubiprass.splitx.settings-changed"),
                                             NULL, NULL, YES);
    } else {
        PXLogMessage(PXLogLevelWarn, @"prefs", @"slider 写入失败 key=%@ suite=%@", key ?: @"?", suite ?: @"?");
    }
    [self updateLabel];
}

- (void)updateLabel {
    NSInteger step = [[self.specifier propertyForKey:@"stepValue"] integerValue];
    CGFloat value = self.slider.value;
    if (step > 1) value = round(value / step) * step;
    self.valueLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    NSString *label = [self.specifier propertyForKey:@"label"];
    if (label.length) self.textLabel.text = label;
    self.valueLabel.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;   // contentView 只有 44 高，会把滑杆裁掉
    self.textLabel.frame = CGRectMake(16, 8, bounds.size.width - 120, 20);
    self.valueLabel.frame = CGRectMake(bounds.size.width - 88, 8, 72, 20);
    self.slider.frame = CGRectMake(16, 32, bounds.size.width - 32, 32);
}

/// 点数值直接输，省得拖着找。
- (void)editValue:(UITapGestureRecognizer *)recognizer {
    UIViewController *host = [self _viewControllerForAncestor];
    if (!host) return;
    NSNumber *minimum = [self.specifier propertyForKey:@"minimumValue"];
    NSNumber *maximum = [self.specifier propertyForKey:@"maximumValue"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.textLabel.text
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.text = [NSString stringWithFormat:@"%ld", (long)self.slider.value];
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        CGFloat value = [alert.textFields.firstObject.text floatValue];
        if (minimum) value = MAX(value, minimum.floatValue);
        if (maximum) value = MIN(value, maximum.floatValue);
        strongSelf.slider.value = value;
        [strongSelf controlChanged:strongSelf.slider];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end
