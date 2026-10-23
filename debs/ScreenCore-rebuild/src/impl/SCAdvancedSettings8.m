#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SCAdvancedSettings8 : PSListController
@end

@implementation SCAdvancedSettings8

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        for (int j = 0; j < 5; j++) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"Option %d-%d", 8, j]
                                                               target:self
                                                                  set:@selector(setValue:forKey:)
                                                                  get:@selector(valueForKey:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
            [spec setProperty:[NSString stringWithFormat:@"opt_%d_%d", 8, j] forKey:@"key"];
            [spec setProperty:@YES forKey:@"default"];
            [spec setProperty:@"com.susudear.screencoreprefs" forKey:@"defaults"];
            [specs addObject:spec];
        }
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    [[SCPreferences sharedInstance] setValue:value forKey:key];
}

- (id)valueForKey:(NSString *)key {
    return [[SCPreferences sharedInstance] valueForKey:key defaultValue:@YES];
}

@end
