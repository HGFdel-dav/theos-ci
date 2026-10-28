#import "POSplitTarget.h"

NSString *const POSplitDefaultContainerIdentifier = @"DEFAULT";

@interface POSplitTarget ()
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, copy) NSString *containerDisplayName;
@end

@implementation POSplitTarget

+ (instancetype)targetWithBundleIdentifier:(NSString *)bundleIdentifier
                                  container:(NSString *)containerIdentifier
                                displayName:(NSString *)displayName {
    if (bundleIdentifier.length == 0) {
        return nil;
    }
    POSplitTarget *target = [self new];
    target.bundleIdentifier = bundleIdentifier;
    target.containerIdentifier = containerIdentifier.length ? containerIdentifier : POSplitDefaultContainerIdentifier;
    target.containerDisplayName = displayName.length ? displayName : target.containerIdentifier;
    return target;
}

+ (instancetype)targetWithBundleIdentifier:(NSString *)bundleIdentifier {
    return [self targetWithBundleIdentifier:bundleIdentifier container:nil displayName:nil];
}

- (BOOL)isDefaultContainer {
    return [self.containerIdentifier isEqualToString:POSplitDefaultContainerIdentifier];
}

- (NSString *)identityKey {
    return [NSString stringWithFormat:@"%@#%@", self.bundleIdentifier, self.containerIdentifier];
}

- (NSString *)displayTitle {
    return self.isDefaultContainer ? @"默认" : self.containerDisplayName;
}

- (BOOL)isEqualToTarget:(POSplitTarget *)other {
    return other && [other.bundleIdentifier isEqualToString:self.bundleIdentifier] &&
        [other.containerIdentifier isEqualToString:self.containerIdentifier];
}

- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:POSplitTarget.class] && [self isEqualToTarget:object];
}

- (NSUInteger)hash {
    return self.identityKey.hash;
}

- (id)copyWithZone:(NSZone *)zone {
    return [POSplitTarget targetWithBundleIdentifier:self.bundleIdentifier
                                           container:self.containerIdentifier
                                         displayName:self.containerDisplayName];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@>", NSStringFromClass(self.class), self.identityKey];
}

@end
