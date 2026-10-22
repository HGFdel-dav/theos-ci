// CXRootListController.m
//
// CloneX 设置根页。
// 列表 = 有分身的应用；行副标题显示「菜单里已启用 N 个分身」。
// 点行进入多选页。遵守 SplitX/LESSONS.md：不覆写 initForContentSize:，
// specifiers 每次重建（数量随配置变化）。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <string.h>
#import "CXContainerPicker.h"
#import "CXCraneBridge.h"
#import "CXPrefs.h"
#import "CXLog.h"

static NSString *CXAppName(NSString *bundleID) {
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyCls, proxySel, bundleID);
        if (proxy) {
            id name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
            if ([name isKindOfClass:NSString.class] && [name length]) return name;
        }
    }
    return bundleID;
}

@interface CXRootListController : PSListController
@end

@implementation CXRootListController

- (instancetype)init {
    if ((self = [super init])) self.title = @"CloneX";
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (NSArray<PSSpecifier *> *)specifiers {
    _specifiers = nil;
    NSMutableArray<PSSpecifier *> *specs = [NSMutableArray array];

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@""];
    [intro setProperty:@"勾选的应用分身会作为独立图标出现在分屏菜单里（应用图标 + 分身名）。\n改动后请重新打开菜单；若菜单没刷新，重启一次桌面即可。"
               forKey:@"footerText"];
    [specs addObject:intro];

    if (![CXCraneBridge isCraneAvailable]) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"未检测到分身组件"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
        _specifiers = specs;
        return _specifiers;
    }

    NSArray<NSDictionary *> *menuItems = [CXPrefs shared].menuItems;
    NSArray<NSString *> *craneApps = [CXCraneBridge applicationsWithNonDefaultContainers];
    NSMutableArray<NSString *> *bundleIDs = [NSMutableArray array];
    for (NSString *bundle in craneApps)
        if ([bundle isKindOfClass:NSString.class] && bundle.length && ![bundleIDs containsObject:bundle])
            [bundleIDs addObject:bundle];
    for (NSDictionary *item in menuItems) {
        NSString *bundle = item[@"bundleID"];
        if (bundle.length && ![bundleIDs containsObject:bundle]) [bundleIDs addObject:bundle];
    }
    [bundleIDs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [CXAppName(a) localizedStandardCompare:CXAppName(b)];
    }];

    if (!bundleIDs.count) {
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"暂无可用分身"
                                                        target:self set:NULL get:NULL detail:nil
                                                          cell:PSStaticTextCell edit:nil]];
    } else {
        for (NSString *bundle in bundleIDs) {
            NSUInteger count = 0;
            for (NSDictionary *item in menuItems)
                if ([item[@"bundleID"] isEqual:bundle]) count++;
            NSString *title = count
                ? [NSString stringWithFormat:@"%@ · 菜单显示 %lu 个分身", CXAppName(bundle), (unsigned long)count]
                : [NSString stringWithFormat:@"%@ · 未加入菜单", CXAppName(bundle)];
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title
                                                              target:self set:NULL get:NULL detail:nil
                                                                cell:PSLinkCell edit:nil];
            [row setProperty:bundle forKey:@"cxBundleID"];
            [specs addObject:row];
        }
    }

    PSSpecifier *note = [PSSpecifier groupSpecifierWithName:@"说明"];
    [note setProperty:@"切换容器时目标应用会短暂重启，这是分身机制的固有行为。\n如果菜单里看不到分身图标，先重启一次桌面；仍看不到就把 /var/mobile/Library/Application Support/CloneX/runtime.log 发我。"
               forKey:@"footerText"];
    [specs addObject:note];

    _specifiers = specs;
    return _specifiers;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bundleID = [spec propertyForKey:@"cxBundleID"];
    if ([bundleID isKindOfClass:NSString.class] && bundleID.length) {
        CXContainerPicker *picker = [[CXContainerPicker alloc] initForBundleID:bundleID];
        [self.navigationController pushViewController:picker animated:YES];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end