#import "TWChoiceController.h"
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWStyle.h"
#import <Preferences/PSSpecifier.h>

@implementation TWChoiceController {
    NSString *_prefKey;
    NSArray<NSString *> *_titles;
    NSArray *_values;
}
// Use the working PSListController -init path for this parameterized page;
// the framework owns initForContentSize: and must not loop through overrides.
- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
    if ((self = [super init])) {
        self.title = title;
        _prefKey = [key copy]; _titles = [titles copy] ?: @[]; _values = [values copy] ?: @[];
        _specifiers = nil;
    }
    return self;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *rows = [NSMutableArray arrayWithObject:[PSSpecifier groupSpecifierWithName:@""]];
        for (NSUInteger i = 0; i < _titles.count; i++) {
            NSString *title = _titles[i];
            PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:title target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:NULL];
            [s setProperty:@(i) forKey:@"twChoiceIndex"];
            [s setButtonAction:@selector(twSelectChoice:)];
            [rows addObject:s];
        }
        _specifiers = rows;
    }
    return _specifiers;
}
- (NSInteger)currentIndex {
    id stored = self.readValue ? self.readValue() : [[TWPrefs shared] objectForKey:_prefKey];
    for (NSUInteger i = 0; i < _values.count; i++) {
        id value = _values[i];
        if ([value isEqual:stored]) return i;
        if ([value respondsToSelector:@selector(integerValue)] && [stored respondsToSelector:@selector(integerValue)] && [value integerValue] == [stored integerValue]) return i;
    }
    return 0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *sp = [self specifierAtIndexPath:indexPath];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.userInteractionEnabled = YES;
    cell.accessoryType = [[sp propertyForKey:@"twChoiceIndex"] integerValue] == [self currentIndex] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)twSelectChoice:(PSSpecifier *)sp {
    NSInteger row = [[sp propertyForKey:@"twChoiceIndex"] integerValue];
    if (row < 0 || row >= (NSInteger)_values.count) return;
    id value = _values[(NSUInteger)row];
    if (self.writeValue) self.writeValue(value);
    else { [[TWPrefs shared] setObject:value forKey:_prefKey]; [[TWPrefs shared] synchronize]; }
    [self.table reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self twSelectChoice:[self specifierAtIndexPath:indexPath]];
}
@end
