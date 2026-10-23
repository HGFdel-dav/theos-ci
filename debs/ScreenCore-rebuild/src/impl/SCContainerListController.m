#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SCContainerListController : PSListController
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation SCContainerListController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    PSSpecifier *spec = [self specifier];
    self.bundleID = [spec propertyForKey:@"bundleID"];
    self.title = [spec name];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        // 查询 Crane 容器
        NSArray<SCApplicationTarget *> *targets = [SCCraneIntegration targetsForApplication:self.bundleID];
        
        for (SCApplicationTarget *target in targets) {
            NSString *displayName = target.containerIdentifier ?: @"Default";
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:displayName
                                                               target:self
                                                                  set:@selector(setEnabled:forTarget:)
                                                                  get:@selector(isEnabledForTarget:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
            [spec setProperty:target forKey:@"target"];
            [specs addObject:spec];
        }
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)setEnabled:(id)value forTarget:(PSSpecifier *)spec {
    SCApplicationTarget *target = [spec propertyForKey:@"target"];
    BOOL enabled = [value boolValue];
    
    NSString *key = [NSString stringWithFormat:@"%@#%@", target.bundleID, target.containerIdentifier ?: @"DEFAULT"];
    [[SCPreferences sharedInstance] setValue:@(enabled) forKey:key];
    
    NSLog(@"[SC] setEnabled %@ for %@", enabled ? @"YES" : @"NO", target);
}

- (id)isEnabledForTarget:(PSSpecifier *)spec {
    SCApplicationTarget *target = [spec propertyForKey:@"target"];
    NSString *key = [NSString stringWithFormat:@"%@#%@", target.bundleID, target.containerIdentifier ?: @"DEFAULT"];
    return [[SCPreferences sharedInstance] valueForKey:key defaultValue:@YES];
}

@end
