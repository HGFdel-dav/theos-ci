#import "ReynardDefaultCC.h"

@implementation ReynardDefaultCC {
    BOOL _selected;
}

- (BOOL)isSelected {
    _selected = RDReadBoolPref(kSystemLinksKey, YES);
    return _selected;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [prefs setBool:selected forKey:kSystemLinksKey];
    [prefs synchronize];
    [super refreshState];
}

- (UIImage *)iconGlyph {
    return [UIImage imageNamed:@"icon" inBundle:[NSBundle bundleForClass:[self class]] compatibleWithTraitCollection:nil];
}

- (UIColor *)selectedColor {
    return [UIColor systemOrangeColor];
}

@end
