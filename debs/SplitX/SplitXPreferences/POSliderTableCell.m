#import "POSliderTableCell.h"

@implementation POSliderTableCell

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
    self.control.minimumValue = minimum ? minimum.floatValue : 0;
    self.control.maximumValue = maximum ? maximum.floatValue : 100;
    [super refreshCellContentsWithSpecifier:specifier];
    [self updateLabel];
    [self setNeedsLayout];
}

- (void)setValue:(NSNumber *)value {
    [super setValue:value];
    self.control.value = value.floatValue;
    [self updateLabel];
}

- (void)controlChanged:(UISlider *)slider {
    [super controlChanged:slider];
    [self updateLabel];
}

- (void)updateLabel {
    NSInteger step = [[self.specifier propertyForKey:@"stepValue"] integerValue];
    CGFloat value = self.control.value;
    if (step > 1) value = round(value / step) * step;
    self.valueLabel.text = [NSString stringWithFormat:@"%ld", (long)value];
    self.textLabel.text = [self.specifier propertyForKey:@"label"];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.textLabel.frame = CGRectMake(16, 8, bounds.size.width - 120, 20);
    self.valueLabel.frame = CGRectMake(bounds.size.width - 88, 8, 72, 20);
    self.control.frame = CGRectMake(16, 32, bounds.size.width - 32, 32);
}

/// 点数值直接输，省得拖着找。
- (void)editValue:(UITapGestureRecognizer *)recognizer {
    UIViewController *host = self._viewControllerForAncestor;
    if (!host) return;
    NSNumber *minimum = [self.specifier propertyForKey:@"minimumValue"];
    NSNumber *maximum = [self.specifier propertyForKey:@"maximumValue"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.textLabel.text
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.text = [NSString stringWithFormat:@"%ld", (long)self.control.value];
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        CGFloat value = [alert.textFields.firstObject.text floatValue];
        if (minimum) value = MAX(value, minimum.floatValue);
        if (maximum) value = MIN(value, maximum.floatValue);
        strongSelf.control.value = value;
        [strongSelf controlChanged:strongSelf.control];
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

@end
