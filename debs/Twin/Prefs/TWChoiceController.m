// TWChoiceController.m
// 「多选一」子页的原生实现。
//
// 为什么不用系统自带的 PSListItemsController：
// 它必须由 Preferences 带着 specifier 上下文来创建（会读取 specifier 的
// values / titles / cellType）。我们自己 alloc 出来的实例拿不到 specifier，
// 结果是一页「只有导航栏、内容全黑」的空表（实机多张截图实证）。
// 交给 Preferences 建（0.9.18）又会让整页变黑。所以这里自己写一个
// 最小可用的列表页：读 key / titles / values，点一行就写偏好并返回。
#import "TWChoiceController.h"
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWStyle.h"

@implementation TWChoiceController {
    NSString *_prefKey;
    NSArray<NSString *> *_titles;
    NSArray *_values;
}

- (instancetype)initWithTitle:(NSString *)title
                          key:(NSString *)key
                       titles:(NSArray<NSString *> *)titles
                       values:(NSArray *)values {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = title;
        _prefKey = [key copy];
        _titles = [titles copy] ?: @[];
        _values = [values copy] ?: @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"TWChoiceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[TWIconCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.textLabel.text = _titles[(NSUInteger)indexPath.row];
    cell.textLabel.textColor = UIColor.labelColor;

    NSInteger current = [self currentIndex];
    cell.accessoryType = (indexPath.row == current) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (NSInteger)currentIndex {
    if (!_prefKey.length) return -1;
    id stored = [[TWPrefs shared] objectForKey:_prefKey];
    if (!stored) return 0;
    for (NSUInteger i = 0; i < _values.count; i++) {
        id candidate = _values[i];
        if ([candidate respondsToSelector:@selector(isEqual:)] && [candidate isEqual:stored]) return (NSInteger)i;
        if ([candidate respondsToSelector:@selector(integerValue)] &&
            [stored respondsToSelector:@selector(integerValue)] &&
            [candidate integerValue] == [stored integerValue]) return (NSInteger)i;
    }
    return 0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (_prefKey.length && row < _values.count) {
        [[TWPrefs shared] setObject:_values[row] forKey:_prefKey];
        [[TWPrefs shared] synchronize];
        // 通知 SpringBoard 侧重新读偏好（与其它面板行共用同一条链路）。
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.niubiprass.twin.prefs-changed"),
                                             NULL, NULL, YES);
    }
    [tableView reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
