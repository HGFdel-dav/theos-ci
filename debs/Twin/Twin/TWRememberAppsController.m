// TWRememberAppsController.m — list remembered window frames per app, with
// per-row deletion and a "clear all" toolbar action. Pure UIKit (no Preferences
// link), safe to compile into the shared dylib.
#import "TWRememberAppsController.h"
#import "TWPath.h"
#import "TWPrefs.h"

@interface TWRememberAppsController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *bundleIDs;
@end

@implementation TWRememberAppsController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"记忆的窗口";
        self.toolbarItems = @[
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
            [[UIBarButtonItem alloc] initWithTitle:@"清除全部" style:UIBarButtonItemStylePlain target:self action:@selector(clearAllTapped)],
        ];
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.toolbarHidden = NO;
    [self reloadFrames];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

- (void)reloadFrames {
    NSDictionary *frames = [[TWPrefs shared] objectForKey:TWKeyRememberFrames];
    NSArray *keys = [frames isKindOfClass:[NSDictionary class]] ? [frames allKeys] : @[];
    self.bundleIDs = [[keys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [self.tableView reloadData];
}

- (void)clearAllTapped {
    [[TWPrefs shared] clearRememberedFrames];
    [self reloadFrames];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.bundleIDs.count ?: 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"拖动窗口边缘调整大小后自动记忆；再次打开该应用的分屏时恢复。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    if (!self.bundleIDs.count) {
        cell.textLabel.text = @"暂无记忆";
        cell.detailTextLabel.text = @"打开分屏并调整窗口大小后会自动记下。";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    NSString *bundleID = self.bundleIDs[indexPath.row];
    cell.textLabel.text = bundleID;
    cell.accessoryType = UITableViewCellAccessoryNone;
    CGRect frame = [[TWPrefs shared] rememberedFrameForBundleID:bundleID];
    if (!CGRectIsNull(frame)) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"x%.0f y%.0f · %.0f×%.0f",
                                     frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
    } else {
        cell.detailTextLabel.text = @"(无效)";
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.bundleIDs.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.row >= self.bundleIDs.count) return;
    NSString *bundleID = self.bundleIDs[indexPath.row];
    NSMutableDictionary *frames = [[[TWPrefs shared] objectForKey:TWKeyRememberFrames] mutableCopy] ?: [NSMutableDictionary dictionary];
    [frames removeObjectForKey:bundleID];
    [[TWPrefs shared] setObject:frames forKey:TWKeyRememberFrames];
    [[TWPrefs shared] synchronize];
    [self reloadFrames];
}

@end