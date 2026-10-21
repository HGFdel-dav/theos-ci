// TWLogController.m
// 运行日志：读 com.niubiprass.twin.log 域里的环形缓冲（最近 200 条），
// 设置里直接看，点右上角「复制」可以整段发给开发者。
#import "TWLogController.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kLogDomain = @"com.niubiprass.twin.log";

@implementation TWLogController {
    NSArray<NSString *> *_lines;
}

- (instancetype)init { return [self initForContentSize:UIScreen.mainScreen.bounds.size]; }
- (instancetype)initForContentSize:(CGSize)size {
    if ((self = [super initForContentSize:size])) self.title = @"运行日志";
    return self;
}
- (UITableView *)tableView { return self.table; }
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [NSMutableArray array];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(twCopyAll)];
    // 不占用左上角（那是系统返回键），刷新改成下拉。
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(twReload) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;
    [self twReload];
}

- (void)twReload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kLogDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("TWRuntimeLog"),
                                                    (__bridge CFStringRef)kLogDomain);
    NSArray *lines = nil;
    if (v && CFGetTypeID(v) == CFArrayGetTypeID()) {
        lines = (__bridge_transfer NSArray *)v;
    } else if (v) {
        CFRelease(v);
    }
    _lines = [lines isKindOfClass:NSArray.class] ? [lines reverseObjectEnumerator].allObjects : @[];
    [self.tableView.refreshControl endRefreshing];
    [self.tableView reloadData];
}

- (void)twCopyAll {
    NSString *all = [_lines componentsJoinedByString:@"\n"];
    if (!all.length) all = @"(还没有日志)";
    UIPasteboard.generalPasteboard.string = all;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制"
                                                                  message:@"日志已复制到剪贴板，直接粘贴发给我就行。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)_lines.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"最近 200 条。反序显示（最新的在最上面）。设置项改动、手势命中、菜单弹出、图标取图结果都会记在这里。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"log"];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!_lines.count) {
        cell.textLabel.text = @"(还没有日志)";
        cell.textLabel.font = [UIFont systemFontOfSize:15];
    } else {
        cell.textLabel.text = _lines[(NSUInteger)indexPath.row];
    }
    return cell;
}
@end
