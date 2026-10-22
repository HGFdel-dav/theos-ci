// CXContainerPicker.m
//
// 单个应用的分身选择页（多选）：勾选的「应用+容器」会作为独立图标
// 出现在 ParallelX 的分屏菜单里。行模式照 Twin 的 TWChoiceController。
#import "CXContainerPicker.h"
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

@implementation CXContainerPicker {
    NSString *_bundleID;
}

- (instancetype)initForBundleID:(NSString *)bundleID {
    if ((self = [super init])) {
        _bundleID = [bundleID copy];
        self.title = @"菜单里的分身";
        _specifiers = nil;
    }
    return self;
}

- (NSArray<PSSpecifier *> *)specifiers {
    _specifiers = nil;
    NSMutableArray<PSSpecifier *> *rows = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@""];
    [group setProperty:@"勾选的分身会作为独立图标出现在分屏菜单里；点击该图标先切到对应容器，再按原样开分屏窗口。"
               forKey:@"footerText"];
    [rows addObject:group];

    NSArray<NSDictionary *> *containers = [CXCraneBridge containersForBundleID:_bundleID];
    if (!containers.count) {
        [rows addObject:[PSSpecifier preferenceSpecifierNamed:@"读取不到容器列表"
                                                       target:self set:NULL get:NULL detail:nil
                                                         cell:PSStaticTextCell edit:nil]];
    }
    for (NSDictionary *entry in containers) {
        NSString *containerID = entry[@"containerID"];
        BOOL isDefault = [entry[@"isDefault"] boolValue];
        NSString *title = isDefault ? @"默认容器" : (entry[@"name"] ?: containerID);
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
                                                          target:self set:NULL get:NULL detail:nil
                                                            cell:PSLinkCell edit:nil];
        [row setProperty:containerID forKey:@"cxContainerID"];
        [rows addObject:row];
    }
    _specifiers = rows;
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *containerID = [spec propertyForKey:@"cxContainerID"];
    if (containerID.length) {
        BOOL on = [[CXPrefs shared] isContainer:containerID shownForBundleID:_bundleID];
        cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.textLabel.textColor = UIColor.labelColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *containerID = [spec propertyForKey:@"cxContainerID"];
    if (!containerID.length) { [super tableView:tableView didSelectRowAtIndexPath:indexPath]; return; }
    [[CXPrefs shared] toggleContainer:containerID bundleID:_bundleID];
    CXLog(@"[prefs] toggle %@ / %@", _bundleID, containerID);
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end