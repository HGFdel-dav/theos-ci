#import "TWLogController.h"
#import "TWSpecifiers.h"
#import <CoreFoundation/CoreFoundation.h>
static NSString *const kLogDomain = @"com.niubiprass.twin.log";
@implementation TWLogController {
    NSArray<NSString *> *_lines;
}
- (instancetype)init {
    if ((self = [super init])) self.title = @"运行日志";
    return self;
}
- (void)twReadLines {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLogDomain);
    CFPropertyListRef raw = CFPreferencesCopyAppValue(CFSTR("TWRuntimeLog"), (__bridge CFStringRef)kLogDomain);
    id value = raw ? CFBridgingRelease(raw) : nil;
    NSMutableArray *clean = [NSMutableArray array];
    if ([value isKindOfClass:NSArray.class]) for (id item in value) if ([item isKindOfClass:NSString.class]) [clean addObject:item];
    _lines = clean.reverseObjectEnumerator.allObjects;
}
- (NSArray *)specifiers {
    if (!_specifiers) {
        [self twReadLines];
        NSMutableArray *rows = [NSMutableArray arrayWithObject:TWGroupSpecifier(@"运行日志", @"最近 200 条，最新在上。下拉刷新，右上角复制。")];
        for (NSString *line in _lines) {
            PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:line target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:NULL];
            [rows addObject:sp];
        }
        if (!_lines.count) [rows addObject:[PSSpecifier preferenceSpecifierNamed:@"还没有日志" target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:NULL]];
        _specifiers = rows;
    }
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(twCopyAll)];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(twReload) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
}
- (void)twReload { _specifiers = nil; [self reloadSpecifiers]; [self.table.refreshControl endRefreshing]; }
- (void)twCopyAll {
    UIPasteboard.generalPasteboard.string = [_lines componentsJoinedByString:@"\n"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已复制" message:@"日志已复制到剪贴板。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *text = [self specifierAtIndexPath:indexPath].name ?: @"";
    CGRect box = [text boundingRectWithSize:CGSizeMake(MAX(80, tableView.bounds.size.width - 64), 1000) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]} context:nil];
    return MAX(44, ceil(box.size.height) + 24);
}
@end
