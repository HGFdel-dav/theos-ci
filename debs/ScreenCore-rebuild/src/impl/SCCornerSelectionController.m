#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface SCCornerSelectionController : PSListController
@end

@implementation SCCornerSelectionController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        NSArray *corners = @[@"Bottom Left", @"Bottom Right", @"Top Left", @"Top Right"];
        NSArray *keys = @[@"cornerBottomLeft", @"cornerBottomRight", @"cornerTopLeft", @"cornerTopRight"];
        
        for (NSInteger i = 0; i < corners.count; i++) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:corners[i]
                                                               target:self
                                                                  set:@selector(setValue:forKey:)
                                                                  get:@selector(valueForKey:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
            [spec setProperty:keys[i] forKey:@"key"];
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
