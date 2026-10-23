#import "../headers/SCApplicationTarget.h"

@implementation SCApplicationTarget

+ (instancetype)targetWithBundleID:(NSString *)bundleID {
    SCApplicationTarget *t = [[self alloc] init];
    t.bundleID = bundleID;
    t.containerIdentifier = nil; // 默认容器
    return t;
}

+ (instancetype)targetWithBundleID:(NSString *)bundleID containerIdentifier:(NSString *)containerID {
    SCApplicationTarget *t = [[self alloc] init];
    t.bundleID = bundleID;
    t.containerIdentifier = containerID;
    return t;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SCApplicationTarget %@#%@>", 
            self.bundleID, self.containerIdentifier ?: @"DEFAULT"];
}

@end
