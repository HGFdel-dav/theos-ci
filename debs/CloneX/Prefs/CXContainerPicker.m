// CXContainerPicker.m
//
// 单个应用的容器选择页：默认容器 + 该应用的全部 Crane 容器（单选）。
// 行模式照 Twin 的 TWChoiceController（PSButtonCell + buttonAction），
// 已在真机设置进程里跑过，不用 detail 自动实例化。
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
        self.title = @"选择容器";
        _specifiers = nil;
    }
    return self;
}

- (NSString *)currentContainerID {
    return [[CXPrefs shared] containerForBundleID:_bundleID] ?: @"DEFAULT";
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray<PSSpecifier *> *rows = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@""];
    [group setProperty:@"选中项 = 从分屏菜单打开这个应用时使用的容器。"
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
        cell.textLabel.textColor = UIColor.labelColor;
        cell.accessoryType = [containerID isEqualToString:self.currentContainerID]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)selectContainer:(PSSpecifier *)spec {
    NSString *containerID = [spec propertyForKey:@"cxContainerID"];
    if (!containerID.length) return;
    if ([containerID isEqualToString:@"DEFAULT"]) {
        [[CXPrefs shared] removeContainerForBundleID:_bundleID];
    } else {
        [[CXPrefs shared] setContainer:containerID forBundleID:_bundleID];
    }
    CXLog(@"[prefs] %@ -> %@", _bundleID, containerID);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if ([spec propertyForKey:@"cxContainerID"]) [self selectContainer:spec];
    else [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end
