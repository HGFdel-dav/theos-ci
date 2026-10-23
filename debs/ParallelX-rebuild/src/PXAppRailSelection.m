#import "../headers/PXAppRailSelection.h"

@implementation PXAppRailSelection

- (instancetype)initWithIdentifier:(NSString *)identifier {
    if (self = [super init]) {
        _identifier = identifier;
        _iconImage = nil;
        _displayName = nil;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<PXAppRailSelection %@ '%@'>",
            _identifier, _displayName ?: @"?"];
}

@end
